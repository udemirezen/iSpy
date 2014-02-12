/*
    iSpy - Bishop Fox iOS hooking framework.

     objc_msgSend() logging.

     This will hook objc_msgSend and objc_msgSend_stret and replace them with functions
     that log every single method called during execution of the target app.

     * Logs to "/tmp/iSpy.log"
     * Generates a lot of data and incurs significant overhead
     * Will make your app slow as shit
     * Will generate a large log file pretty fast

     How to use:

     * Call bf_init_msgSend_logging() exactly ONCE.
     * This will install the objc_msgSend* hooks in preparation for logging.
     * When you want to switch on logging, call bf_enable_msgSend_logging().
     * When you want to switch off logging, call bf_disable_msgSend_logging().
     * Repeat the enable/disable cycle as necessary.

     NOTE:    All of this functionality is already built into iSpy. For more info,
     search for the iSpy constructor (called "%ctor") later in the code.

     - Enable/Disable in Settings app.
 */
#include <substrate.h>
#include <sys/types.h>
#include <dirent.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <string.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFStream.h>
#import <CFNetwork/CFNetwork.h>
#include <pthread.h>
#include <CFNetwork/CFProxySupport.h>
#import <Security/Security.h>
#include <Security/SecCertificate.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <objc/objc.h>
#include "iSpy.common.h"
#include <stack>
#include <pthread.h>

namespace bf_msgSend {  

    id (*orig_objc_msgSend)(id theReceiver, SEL theSelector, ...);
    static id *appClassWhiteList = NULL;
    static bool appClassWhiteListIsReady = false;    
    static pthread_once_t key_once = PTHREAD_ONCE_INIT;
    static pthread_key_t thr_key;
    static pthread_mutex_t mutex_objc_msgSend = PTHREAD_MUTEX_INITIALIZER;
    USED static long rx_reserve[6] __asm__("_rx_reserve");
    USED static long enabled __asm__("_enabled") = 0;
    USED static void *original_objc_msgSend __asm__("_original_objc_msgSend");
    __attribute__((used)) __attribute((weakref("replaced_objc_msgSend"))) static void replaced_objc_msgSend() __asm__("_replaced_objc_msgSend");

    extern "C" int is_object_from_app_bundle(id Cls, SEL selector) {
        int j = 0; 
        
        // don't do shit if we ain't ready
        if( ! appClassWhiteListIsReady )
            return false;
        if( ! appClassWhiteList)
            return false;
        if(!Cls || !selector)
            return false;

        while(appClassWhiteList[j]) {
            id theClass = nil;

            if(appClassWhiteList[j] == Cls->isa) { // Class method?
                theClass = Cls->isa;
                if(class_getClassMethod(theClass, selector))
                    return true;
                else
                    return false;
            } else if(appClassWhiteList[j] == Cls->isa->isa) { // Instance method?
                theClass = Cls->isa->isa;
                if(class_getInstanceMethod(theClass, selector))
                    return true;
                else
                    return false;
            }
            j++;
        }
        return false;
    }

    static void lr_list_destructor(void* value) {
        delete reinterpret_cast<std::stack<lr_node>*>(value);
    }
    
    pthread_rwlock_t stackLock;

    static void make_key() {
        // setup pthreads
        pthread_key_create(&thr_key, lr_list_destructor);
        pthread_rwlock_init(&stackLock, NULL);
    }

    extern "C" USED void show_retval (const char* addr) {
    }

    extern "C" USED void do_objc_msgSend_mutex_lock() {
        pthread_mutex_lock(&mutex_objc_msgSend);

    }

    extern "C" USED void do_objc_msgSend_mutex_unlock() {
        pthread_mutex_unlock(&mutex_objc_msgSend);
    }

    static std::stack<lr_node>& get_lr_list() {
        std::stack<lr_node>* stack = reinterpret_cast<std::stack<lr_node>*>(pthread_getspecific(thr_key));
        if (stack == NULL) {
            stack = new std::stack<lr_node>;
            int err = pthread_setspecific(thr_key, stack);
            if (err) {
                bf_logwrite(LOG_MSGSEND, "[msgSend] Error: pthread_setspecific() Committing suicide.\n");
                delete stack;
                stack = NULL;
            }
        }
        return *stack;
    }

    extern "C" USED void print_args(id self, SEL _cmd, ...) {
        if(self && _cmd) {
            char *selectorName = (char *)sel_getName(_cmd);
            char *className = (char *)object_getClassName(self);
            static unsigned int counter = 0;
            char buf[1027];

            // We need to determine if "self" is a meta class or an instance of a class.
            // We can't use Apple's class_isMetaClass() here because it seems to randomly crash just
            // a little too often. Always class_isMetaClass() and always in this piece of code. 
            // Maybe it's shit, maybe it's me. Whatever.
            // Instead we fudge the same functionality, which is nice and stable.
            // 1. Get the name of the object being passed as "self"
            // 2. Get the metaclass of "self" based on its name
            // 3. Compare the metaclass of "self" to "self". If they're the same, it's a metaclass.
            bool meta = (objc_getMetaClass(className) == object_getClass(self));
            
            // write the captured information to the iSpy web socket. If a client is connected it'll receive this event.
            snprintf(buf, 1024, "[\"%d\",\"%s\",\"%s\",\"%s\",\"%p\",\"\"],", ++counter, (meta)?"+":"-", className, selectorName, self);
            bf_websocket_write(buf);
            
            // keep a local copy of the log in /tmp/bf_msgsend
            strcat(buf, "\n");
            bf_logwrite_msgSend(LOG_MSGSEND, buf);
        }
        
        return;
    }

    extern "C" USED void push_lr (intptr_t lr) {
        lr_node node;
        node.lr = lr;
        memcpy(node.regs, rx_reserve, 6); // save our thread's registers into a thread-specific array
        node.should_filter = true;
        get_lr_list().push(node);
    }

    extern "C" USED  intptr_t pop_lr () { 
        std::stack<lr_node>& lr_list = get_lr_list();
        int retval = lr_list.top().lr;
        lr_list.pop();
        return retval;
    }

    EXPORT void bf_enable_msgSend() {
        enabled=1;
    }

    EXPORT void bf_disable_msgSend() {
        enabled=0;
    }

    EXPORT int bf_get_msgSend_state() {
        return enabled;
    }

    // This is called in the main iSpy constructor.
    EXPORT void bf_hook_msgSend() {
        bf_disable_msgSend();
        pthread_once(&key_once, make_key);
        pthread_key_create(&thr_key, lr_list_destructor);
        MSHookFunction((void *)objc_msgSend, (void *)replaced_objc_msgSend, (void **)&original_objc_msgSend);
        orig_objc_msgSend = (id (*)(id, SEL, ...))original_objc_msgSend;
    }

    // This is a callback function designed to toggle the "ready-to-rock-n-roll" flag.
    // We can also use it to update the whitelist/blacklist of methods we want to monitor. 
    EXPORT void update_msgSend_checklists(id *whiteListPtr, id *blackListPtr) {
        bf_logwrite(LOG_MSGSEND, "[update_msgSend_checklists] Whistlist @ %p", whiteListPtr);
        appClassWhiteListIsReady = false;
        appClassWhiteList = whiteListPtr;   // We can update our whitelist as often as we want, just by flipping this pointer.
        appClassWhiteListIsReady = true;    
    }

    EXPORT bool bf_has_msgSend_initialized_yet() {
        return appClassWhiteListIsReady;
    }

// This is ripped from Subjective-C and bastardized like a mofo.
#pragma mark _replaced_objc_msgSend (ARM)
    __asm__ (".arm\n"
        ".text\n"
                "_replaced_objc_msgSend:\n"
                
                // Check if the hook is enabled. If not, quit now.
                "ldr r12, (LEna0)\n"
    "LoadEna0:"    "ldr r12, [pc, r12]\n"
                "teq r12, #0\n"
                "ldreq r12, (LOrig0)\n"
    "LoadOrig0:""ldreq pc, [pc, r12]\n"

                // is this method on the whitelist?
                "push {r0-r11,lr}\n"
                "bl _is_object_from_app_bundle\n"
                "mov r12, r0\n" 
                "pop {r0-r11,lr}\n"
                "teq r12, #0\n"
                "ldreq r12, (LO2)\n"
    "LoadO2:"   "ldreq pc, [pc, r12]\n"

                // Save regs, set pthread mutex, restore regs
                // TBD: find a more elegant way to do this in a thread-safe way.
                "push {r0-r11,lr}\n"
                "bl _do_objc_msgSend_mutex_lock\n"
                "pop {r0-r11,lr}\n"

                // Save the registers
                "ldr r12, (LSR1)\n"
    "LoadSR1:"    "add r12, pc, r12\n"
                "stmia r12, {r0-r3}\n"
        
                // Push lr onto our custom stack.
                "mov r0, lr\n"
                "bl _push_lr\n"
                            
                // Log this call to objc_msgSend
                "ldr r2, (LSR3)\n"
    "LoadSR3:"    "add r12, pc, r2\n"
                "ldmia r12, {r0-r3}\n"

                "push {r0-r11,lr}\n"
                "bl _do_objc_msgSend_mutex_unlock\n"
                "pop {r0-r11,lr}\n"

                "bl _print_args\n"
                
                "push {r0-r11,lr}\n"
                "bl _do_objc_msgSend_mutex_lock\n"
                "pop {r0-r11,lr}\n"

                // Restore the registers.
                "ldr r1, (LSR4)\n"
    "LoadSR4:"    "add r2, pc, r1\n"
                "ldmia r2, {r0-r3}\n"
                    
                // Unlock the pthread mutex
                "push {r0-r11,lr}\n"
                "bl _do_objc_msgSend_mutex_unlock\n"
                "pop {r0-r11,lr}\n"

                // Call original objc_msgSend
                "ldr r12, (LOrig1)\n"
    "LoadOrig1:""ldr r12, [pc, r12]\n"
                "blx r12\n"

                // Print return value.
                "push {r0-r3}\n"    // assume no intrinsic type takes >128 bits...
                "mov r0, sp\n"
                "bl _show_retval\n"
                "bl _pop_lr\n"
                "mov lr, r0\n"
                "pop {r0-r3}\n"
                "bx lr\n"
                    
    "LEna0:         .long _enabled - 8 - (LoadEna0)\n"
    "LOrig0:    .long _original_objc_msgSend - 8 - (LoadOrig0)\n"
    "LSR1:        .long _rx_reserve - 8 - (LoadSR1)\n"
    "LSR3:        .long _rx_reserve - 8 - (LoadSR3)\n"
    "LSR4:        .long _rx_reserve - 8 - (LoadSR4)\n"
    "LOrig1:    .long _original_objc_msgSend - 8 - (LoadOrig1)\n"
    "LO2:       .long _original_objc_msgSend - 8 - (LoadO2)\n"
    );
} // namespace msgSend
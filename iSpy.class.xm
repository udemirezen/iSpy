/*
 * iSpy - Bishop Fox iOS hacking/hooking/sandboxing framework.
 */

#include <stack>
#include <fcntl.h>
#include <stdio.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <unistd.h>
#include <string.h>
#include <dirent.h>
#include <stdbool.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <objc/objc.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#import  <Security/Security.h>
#import  <Security/SecCertificate.h>
#include <CFNetwork/CFNetwork.h>
#include <CFNetwork/CFProxySupport.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFStream.h>
#import  <Foundation/NSJSONSerialization.h>
#include "iSpy.common.h"
#include "iSpy.instance.h"
#include "iSpy.class.h"
#include "hooks_C_system_calls.h"
#include "hooks_CoreFoundation.h"
#include "HTTPKit/HTTP.h"
#import  "GRMustache/include/GRMustache.h"
#include <dlfcn.h>
#include <mach-o/nlist.h>
#include <semaphore.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <QuartzCore/QuartzCore.h>


static NSString *changeDateToDateString(NSDate *date);
static char *bf_get_type_from_signature(char *typeStr);
static char *bf_get_friendly_method_return_type(Method method);
static char *bf_get_attrs_from_signature(char *attributeCString);

id *appClassWhiteList = NULL;

/*************************************************************************************************
    This is the "iSpy" class implementation. It does cool stuff.  We use it quite a lot inside 
    the iSpy .dylib. It's used as a singleton. For example, consider the following code:

        %hook myTargetAppCoolClass
        -(void) someInterestingMethod {
            // get access to the iSpy singleton
            mySpy *mySpy = [iSpy sharedInstance];
            
            // turn on the strace logger
            [mySpy strace_enableLogging];
            
            // perform the original interesting method
            %orig;

            // turn off the strace logger
            [mySpy strace_disableLogging];

            // do analysis of the data or whatever.
            return;
        }
        %end
    
    This class is also exposed to Cycript, which makes it possible to interact with iSpy at runtime:

        ssh root@your.idevice
        cycript -p <PID>
        mySpy = [iSpy sharedInstance]
        [mySpy instance_enableTracking]
        ...
        [mySpy instance_dumpAppInstancesWithPointers];

    The method names are kinda weird (often beginning with instance_, or msgSend_, or strace_, etc.)
    This is to make Cycript's tab-completion a joy to use by grouping methods together in an
    intuitive manner inside the Cycript REPL. For example, let's say you're using cycript and want
    to do something with iSpy's instance tracking support:

        cy# x = [iSpy sharedInstance ]
        "<iSpy: 0x1cd74cd0>"
        cy# [x instance_<<press tab twice>>
        instance_disableTracking                    instance_dumpAppInstancesWithPointers       instance_enableTracking                     instance_searchInstances:
        instance_dumpAllInstancesWithPointers       instance_dumpAppInstancesWithPointersArray  instance_numberOfTrackedInstances

    Voila! All the instance support functions appear. Same for msgSend, strace, etc.
**************************************************************************************************/
@implementation iSpy

// Returns the singleton
+ (id)sharedInstance {
    static iSpy *sharedInstance;
    static dispatch_once_t once;
    
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
        [sharedInstance setWebServer:[[iSpyServer alloc] init]];
        [sharedInstance setGlobalStatusStr:@""];
        [sharedInstance setBundleId:[[[NSBundle mainBundle] bundleIdentifier] copy]];
        [sharedInstance setIsInstanceTrackingEnabled: NO];
        [sharedInstance setIsMsgSendTrackingEnabled: NO];
        [sharedInstance setIsStraceTrackingEnabled: NO];
        sharedInstance->_trackedInstances = [[NSMutableDictionary alloc] init];
    });
    
    return sharedInstance;
}

// Given the name of a class, this returns true if the class is declared in the target app, false if not.
// It's waaaaaay faster than checking bundleForClass shit from the Apple runtime.
+(BOOL)isClassFromApp:(NSString *)className {
    char *imageName = (char *)class_getImageName(objc_getClass([className UTF8String]));
    char *p = NULL;

    if(!imageName)
        return false;

    if(!(p = strrchr(imageName, '/')))
        return false;

    if(strncmp(imageName, [[[NSProcessInfo processInfo] arguments][0] UTF8String], p-imageName-1) == 0)
        return true;

    return false;
}

// A lot of methods are just wrapping pure C calls, which has the effect of exposing core iSpy features
// to Cycript for advanced use.
-(void) instance_enableTracking {
    bf_enable_instance_tracker();
}

-(void) instance_disableTracking {
    bf_disable_instance_tracker();
}

// Dumps a list of all the instances in the runtime, including all Apple's classes like NSString, etc. 
// Generates a ton of output.
// Human-readable text.
-(NSString *) instance_dumpAllInstancesWithPointers {
    struct bf_instance *p = bf_get_instance_list_ptr();
    NSString *instances = @"";

    while(p) {
        instances = [NSString stringWithFormat:@"%@\n%p => %s", instances, p->instance, p->name];
        p=p->next;
    }
    return instances;
}

// Returns a human-readable list of runtime class instances, restricted to application-defined classes.
// Dumps the corresponding pointers, too.
// You can then grab handles to instances in Cycript by using "x = new Instance(0xwhatever)" syntax.
-(NSString *) instance_dumpAppInstancesWithPointers {
    NSString *result = @"";
    for(NSArray *arr in [self instance_dumpAppInstancesWithPointersArray]) {
        result = [NSString stringWithFormat:@"%@%.10s => %s\n", result, [[arr objectAtIndex:1] UTF8String], [[arr objectAtIndex:0] UTF8String]];
    }
    return result;
}

// Returns a computer parsable array of runtime class instances, restricted to application-defined classes.
// [ {class_description, class_name}, {class_description, class_name}, ... ]
-(NSArray *) instance_dumpAppInstancesWithPointersArray {
    NSMutableArray *instances = [[NSMutableArray alloc] init];
    struct bf_instance *p = bf_get_instance_list_ptr();

    while(p) {
        if( p->name && p->instance && [iSpy isClassFromApp:[NSString stringWithUTF8String:p->name]] ) {
            [instances addObject:[NSArray arrayWithObjects:[NSString stringWithCString:p->name encoding:NSUTF8StringEncoding], [NSString stringWithFormat:@"%p", p->instance], nil]];
        }
        p=p->next;
    }

    return [instances copy];
}

// Does a brute-force search of the linked list of currently tracked instances.
// Returns the number of tracked instances.
-(int) instance_numberOfTrackedInstances {
    int i = 0;
    struct bf_instance *p = bf_get_instance_list_ptr();
    
    while(p) {
        p=p->next;
        i++;
    }
    return i;
}

-(void) instance_searchInstances:(NSString *)forName {
    return;
}

-(BOOL) instance_getTrackingState {
    return bf_get_instance_tracking_state();
}

// Turn on objc_msgSend logging
-(void) msgSend_enableLogging {
    bf_enable_msgSend_logging();
}

// Turn off objc_msgSend logging
-(void) msgSend_disableLogging {
    bf_disable_msgSend_logging();
}

// Return true/false depending on whether or not objc_msgSend logging is on or off
-(BOOL) msgSend_getLoggingState {
    return bf_get_msgSend_state();
}

// is the msgSend logging system ready to roll?
-(BOOL) msgSend_isInitialized {
    return bf_has_msgSend_initialized_yet();
}

-(void) strace_enableLogging {
    bf_set_log_state(true, LOG_STRACE);
}

-(void) strace_disableLogging {
    bf_set_log_state(false, LOG_STRACE);
}

-(BOOL) strace_getLoggingState {
    return bf_get_log_state(LOG_STRACE);
}

-(void) http_enableLogging {
    bf_set_log_state(true, LOG_HTTP);
}

-(void) http_disableLogging {
    bf_set_log_state(false, LOG_HTTP);
}

-(void) tcpip_enableLogging {
    bf_set_log_state(true, LOG_TCPIP);
}

-(void) tcpip_disableLogging {
    bf_set_log_state(false, LOG_TCPIP);
}

-(void) log_setGeneralLogState:(BOOL)state {
    bf_set_log_state(state, LOG_GENERAL);
}

-(void) log_setStraceLogState:(BOOL)state {
    bf_set_log_state(state, LOG_STRACE);
}

-(void) log_setHTTPLogState:(BOOL)state {
    bf_set_log_state(state, LOG_HTTP);
}

-(void) log_setTCPIPLogState:(BOOL)state {
    bf_set_log_state(state, LOG_TCPIP);
}

-(void) log_setMsgSendLogState:(BOOL)state {
    bf_set_log_state(state, LOG_MSGSEND);
}

-(void) log_setLogState:(BOOL)state forLog:(int)facility {
    bf_set_log_state(state, facility);   
}

-(NSDictionary *) getSymbolTable {
    return nil;
}
    /*
    int result;
    NSUInteger numSymbols;
    sqlite3_stmt *stmt;
    iSpy *mySpy = [iSpy sharedInstance];

    // Get the number of symbols in the app
    sqlite3_prepare_v2([[mySpy db] handle], "SELECT count(id) FROM symbols", -1, &stmt, NULL);
    if((result = sqlite3_step(stmt)) != SQLITE_ROW)
        return NULL;
    numSymbols = (NSUInteger)sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    bf_logwrite(LOG_GENERAL, "getSymbolTable: counted %u symbols", (unsigned int)numSymbols);

    // Allocate a dictionary of the correct size to hold all the symbols plus nil and a bit
    NSMutableDictionary *symtab = [[NSMutableDictionary alloc] initWithCapacity:numSymbols+2];
    
    // Populate the dict
    sqlite3_prepare_v2([[mySpy db] handle], "SELECT name, offset, n_stab, n_pext, n_ext, n_pbud, n_indr, n_arm, type FROM symbols", -1, &stmt, NULL);
    while((result = sqlite3_step(stmt)) == SQLITE_ROW) {
        NSMutableDictionary *symbol = [[NSMutableDictionary alloc] initWithCapacity:9]; 
        [symbol setObject:[NSNumber numberWithUnsignedInt: sqlite3_column_int(stmt, 1)] forKey:@"offset"];
        [symbol setObject:[NSNumber numberWithUnsignedInt: sqlite3_column_int(stmt, 2)] forKey:@"n_stab"];
        [symbol setObject:[NSNumber numberWithUnsignedInt: sqlite3_column_int(stmt, 3)] forKey:@"n_pext"];
        [symbol setObject:[NSNumber numberWithUnsignedInt: sqlite3_column_int(stmt, 4)] forKey:@"n_ext"];
        [symbol setObject:[NSNumber numberWithUnsignedInt: sqlite3_column_int(stmt, 5)] forKey:@"n_pbud"];
        [symbol setObject:[NSNumber numberWithUnsignedInt: sqlite3_column_int(stmt, 6)] forKey:@"n_indr"];
        [symbol setObject:[NSNumber numberWithUnsignedInt: sqlite3_column_int(stmt, 7)] forKey:@"n_arm"];
        [symbol setObject:[NSNumber numberWithUnsignedInt: sqlite3_column_int(stmt, 8)] forKey:@"type"];
        [symtab setObject:[symbol copy] forKey:[NSString stringWithUTF8String: (const char *)sqlite3_column_text(stmt, 0)]]; // main dict is keyed by symbol name
    }
    sqlite3_finalize(stmt);
    sqlite3_close([[mySpy db] handle]);
    NSDictionary *returnDict = [symtab copy];
    bf_logwrite(LOG_GENERAL, "getSymbolTable: done!");
    return returnDict;
} 
*/

-(unsigned int) getMachFlags {
    return 0;
    /*
    sqlite3_stmt *stmt;
    iSpy *mySpy = [iSpy sharedInstance];
    unsigned int flags;

    sqlite3_prepare_v2([[mySpy db] handle], "SELECT flags FROM machFlags", -1, &stmt, NULL);
    if(sqlite3_step(stmt) == SQLITE_ROW)
        flags = (unsigned int)sqlite3_column_int(stmt, 0);
    else
        flags = 0xffffffff;
    sqlite3_finalize(stmt);
    return flags;
    */
}


-(NSDictionary *)keyChainItems {
    NSMutableDictionary *genericQuery = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *keychainDict = [[NSMutableDictionary alloc] init];
    // genp, inet, idnt, cert, keys
    NSArray *items = [NSArray arrayWithObjects:(id)kSecClassGenericPassword, kSecClassInternetPassword, kSecClassIdentity, kSecClassCertificate, kSecClassKey, nil];
    int i = 0, j, count;

    count = [items count];
    do {
        NSMutableArray *keychainItems = nil;
        NSLog(@"Area: %@", [items objectAtIndex:i]);
        [genericQuery setObject:(id)[items objectAtIndex:i] forKey:(id)kSecClass];
        [genericQuery setObject:(id)kSecMatchLimitAll forKey:(id)kSecMatchLimit];
        [genericQuery setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnAttributes];
        [genericQuery setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnRef];
        [genericQuery setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnData];

        if (SecItemCopyMatching((CFDictionaryRef)genericQuery, (CFTypeRef *)&keychainItems) != noErr)
            continue;
        
        // NSJSONSerializer won't parse NSDate or NSData, so we convert any of those into NSString for later JSON-ification.
        for(j = 0; j < [keychainItems count]; j++) {
            NSLog(@"Data: %@", [keychainItems objectAtIndex:j]);
            for(NSString *key in [[keychainItems objectAtIndex:j] allKeys]) {
                // We don't need the v_Ref attribute; it's just an obkect representation of a cert, which we already have.
                if([key isEqual:@"v_Ref"])
                   [[keychainItems objectAtIndex:j] removeObjectForKey:key];

                // Is this some kind of NSData/__NSFSData/etc?
                else if([[[keychainItems objectAtIndex:j] objectForKey:key] respondsToSelector:@selector(bytes)]) {
                    NSString *str = [[NSString alloc] initWithData:[[keychainItems objectAtIndex:j] objectForKey:key] encoding:NSUTF8StringEncoding];
                    if(str == nil)
                        str = @"";
                    [[keychainItems objectAtIndex:j] setObject:str forKey:key];
                } 

                // how about NSDate?
                else if([[[keychainItems objectAtIndex:j] objectForKey:key] respondsToSelector:@selector(isEqualToDate:)]) {
                    [[keychainItems objectAtIndex:j] setObject:changeDateToDateString([[keychainItems objectAtIndex:j] objectForKey:key]) forKey:key];
                }

                NSLog(@"Data: %@ (class: %@) = %@", key, [[[keychainItems objectAtIndex:j] objectForKey:key] class], [[keychainItems objectAtIndex:j] objectForKey:key]);
            }
        }
        [keychainDict setObject:keychainItems forKey:[items objectAtIndex:i]];
    } while(++i < count);
    
    return [keychainDict copy];
}

-(unsigned int)ASLR {
    return (unsigned int)_dyld_get_image_vmaddr_slide(0);
}




/*
Returns a NSDictionary like this:
{
    "name" = "doSomething:forString:withChars:",

    "parameters" = { 
        // name = type
        "arg1" = "id",
        "arg2" = "NSString *",
        "arg3" = "char *"        
    },

    "returnType" = "void";
}
*/

-(id)testMethodThing {
    return [self iVarsForClass:@"NSString"];
}

-(NSDictionary *)infoForMethod:(SEL)selector inClass:(Class)cls {
    return [self infoForMethod:selector inClass:cls isInstanceMethod:1];
}

-(NSDictionary *)infoForMethod:(SEL)selector inClass:(Class)cls isInstanceMethod:(BOOL)isInstance {    
    Method method = nil;
    BOOL isInstanceMethod = true;
    NSMutableArray *parameters = [[NSMutableArray alloc] init];
    NSMutableDictionary *methodInfo = [[NSMutableDictionary alloc] init];
    int numArgs, k;
    NSString *returnType;
    char *freeMethodName, *methodName, *tmp; 

    if(cls == NULL || selector == NULL || cls == nil || selector == nil)
        return nil;

    if([cls instancesRespondToSelector:selector] == YES) {
        method = class_getInstanceMethod(cls, selector);
    } else if([object_getClass(cls) respondsToSelector:selector] == YES) {
        method = class_getClassMethod(object_getClass(cls), selector);
        isInstanceMethod = false;
    } else {
        return nil;
    }

    if(method == nil)
        return nil;    

    numArgs = method_getNumberOfArguments(method);

    // get the method's name as a (char *)
    freeMethodName = methodName = (char *)strdup(sel_getName(method_getName(method)));
    
    // cycle through the paramter list for this method.
    // start at k=2 so that we omit Cls and SEL, the first 2 args of every function/method
    for(k=2; k < numArgs; k++) {
        char tmpBuf[256]; // safe and reasonable limit on var name length
        char *type;
        char *name;
        NSMutableDictionary *param = [[NSMutableDictionary alloc] init];

        name = strsep(&methodName, ":");
        if(!name) {
            bf_logwrite(LOG_GENERAL, "um, so p=NULL in arg printer for class methods... weird.");
            continue;
        }

        method_getArgumentType(method, k, tmpBuf, 255);
    
        if((type = (char *)bf_get_type_from_signature(tmpBuf))==NULL) {
            bf_logwrite(LOG_GENERAL, "Out of mem");
            break;
        }

        [param setObject:[NSString stringWithUTF8String:type] forKey:@"type"];
        [param setObject:[NSString stringWithUTF8String:name] forKey:@"name"];
        [parameters addObject:param];
        free(type);
    } // args   
    
    tmp = (char *)bf_get_friendly_method_return_type(method);

    if(!tmp)
        returnType = @"XXX_unknown_type_XXX";
    else {
        returnType = [NSString stringWithUTF8String:tmp];
        free(tmp);
    }
    
    [methodInfo setObject:parameters forKey:@"parameters"];
    [methodInfo setObject:returnType forKey:@"returnType"];
    [methodInfo setObject:[NSString stringWithUTF8String:freeMethodName] forKey:@"name"];
    [methodInfo setObject:[NSNumber numberWithInt:isInstanceMethod] forKey:@"isInstanceMethod"];
    free(freeMethodName);
    
    return [methodInfo copy];
}

-(id)iVarsForClass:(NSString *)className {
    unsigned int iVarCount = 0, j;
    Ivar *ivarList = class_copyIvarList(objc_getClass([className UTF8String]), &iVarCount);
    NSMutableArray *iVars = [[NSMutableArray alloc] init];

    if(!ivarList)
        return nil;

    for(j = 0; j < iVarCount; j++) {
        NSMutableDictionary *iVar = [[NSMutableDictionary alloc] init];

        char *name = (char *)ivar_getName(ivarList[j]);
        char *type = bf_get_type_from_signature((char *)ivar_getTypeEncoding(ivarList[j]));
        [iVar setObject:[NSString stringWithUTF8String:type] forKey:[NSString stringWithUTF8String:name]];
        [iVars addObject:iVar];
        free(type);
    }
    return [iVars copy];
}

-(id)propertiesForClass:(NSString *)className {
    unsigned int propertyCount = 0, j;
    objc_property_t *propertyList = class_copyPropertyList(objc_getClass([className UTF8String]), &propertyCount);
    NSMutableArray *properties = [[NSMutableArray alloc] init];

    if(!propertyList)
        return nil;

    for(j = 0; j < propertyCount; j++) {
        NSMutableDictionary *property = [[NSMutableDictionary alloc] init];

        char *name = (char *)property_getName(propertyList[j]);
        char *attr = bf_get_attrs_from_signature((char *)property_getAttributes(propertyList[j])); 
        [property setObject:[NSString stringWithUTF8String:attr] forKey:[NSString stringWithUTF8String:name]];
        [properties addObject:property];
        free(attr);
    }
    return [properties copy];
}

-(id)methodsForClass:(NSString *)className {
    unsigned int numClassMethods = 0;
    unsigned int numInstanceMethods = 0;
    unsigned int i;
    NSMutableArray *methods = [[NSMutableArray alloc] init];
    Class c;
    char *classNameUTF8;
    Method *classMethodList = NULL;
    Method *instanceMethodList = NULL;
    
    if(!className)
        return nil;

    if((classNameUTF8 = (char *)[className UTF8String]) == NULL)
        return nil;

    Class cls = objc_getClass(classNameUTF8);
    if(cls == nil)
        return nil;
    
    c = object_getClass(cls);
    if(c)
        classMethodList = class_copyMethodList(c, &numClassMethods);
    else
        numClassMethods = 0;
    instanceMethodList  = class_copyMethodList(cls, &numInstanceMethods);
    
    if(classMethodList != NULL) {
        for(i = 0; i < numClassMethods; i++) {
            SEL sel = method_getName(classMethodList[i]);
            if(!sel)
                continue;
            NSDictionary *methodInfo = [self infoForMethod:sel inClass:cls];
            if(methodInfo != nil)
                [methods addObject:methodInfo];    
        }
        free(classMethodList);
    }

    if(instanceMethodList != NULL) {
        for(i = 0; i < numInstanceMethods; i++) {
            SEL sel = method_getName(instanceMethodList[i]);
            if(!sel)
                continue;
            NSDictionary *methodInfo = [self infoForMethod:sel inClass:cls];
            if(methodInfo != nil)
                [methods addObject:methodInfo];    
        }
        free(instanceMethodList);
    }
    return [methods copy];
}

-(id)classes {
    Class * classes = NULL;
    NSMutableArray *classArray = [[NSMutableArray alloc] init];
    int numClasses;

    numClasses = objc_getClassList(NULL, 0);
    if(numClasses <= 0)
        return nil; 
    
    if((classes = (Class *)malloc(sizeof(Class) * numClasses)) == NULL)
        return nil;
    
    objc_getClassList(classes, numClasses);
    
    int i=0;
    while(i < numClasses) {
        NSString *className = [NSString stringWithUTF8String:class_getName(classes[i])];
        if([iSpy isClassFromApp:className])
            [classArray addObject:className];
        i++;
    }
    return [classArray copy];  
}

-(id)instance_atAddress:(NSString *)addr {
    // Given a string in the format @"0xdeadbeef", this first converts the string to an address, then
    // returns an opaque Objective-C instance at that address.
    // The runtime can treat this return value just like any other object.
    // BEWARE: give this an incorrect/invalid address and you'll return a duff pointer. Caveat emptor.
    return (id)strtoul([addr UTF8String], (char **)NULL, 16);
}

// Given a hex address (eg. 0xdeafbeef) dumps the class data from the object at that address.
// Returns an object as discussed in instance_dumpInstance, below.
// This is exposed to /api/instance/0xdeadbeef << replace deadbeef with an actual address.
-(id)instance_dumpInstanceAtAddress:(NSString *)addr {
    return [self instance_dumpInstance:[self instance_atAddress:addr]];
}

// Make sure to pass a valid pointer (instance) to this method!
// In return it'll give you an array. Each element in the array represents an iVar and comprises a dictionary.
// Each element in the dictionary represents the name, type, and value of the iVar.
-(id)instance_dumpInstance:(id)instance {
    void *ptr;
    NSArray *iVars = [self iVarsForClass:[NSString stringWithUTF8String:object_getClassName(instance)]];
    int i;
    NSMutableArray *iVarData = [[NSMutableArray alloc] init];

    for(i=0; i< [iVars count]; i++) {
        NSDictionary *iVar = [iVars objectAtIndex:i];
        NSEnumerator *e = [iVar keyEnumerator];
        id key;

        while((key = [e nextObject])) {
            NSMutableDictionary *iVarInfo = [[NSMutableDictionary alloc] init];
            [iVarInfo setObject:key forKey:@"name"];
            
            object_getInstanceVariable(instance, [key UTF8String], &ptr );
            
            // Retarded check alert!
            // The logic goes like this. All parameter types have a style guide. 
            // e.g. If the type of argument we're examining is an Objective-C class, the first letter of its name
            // will be a capital letter. We can dump these with ease using the Objective-C runtime.
            // Similarly, anything from the C world should have a lower case first letter.
            // Now, we can easily leverage the Objective-C runtime to dump class data. but....
            // The C environment ain't so easy. Easy stuff is booleans (just a "char") or ints. 
            // Of course we could dump strings (char*) too, but we need to write code to handle that.
            // As iSpy matures we'll do just that. Meantime, you'll get (a) the type of the var you're looking at,
            // (b) a pointer to that var. Do as you please with it. BOOLs (really just chars) are already taken care of as an example
            // of how to deal with this shit. 
            char *type = (char *)[[iVar objectForKey:key] UTF8String];
            
            if(islower(*type)) {
                char *boolVal = (char *)ptr;
                if(strcmp(type, "char") == 0) {
                    [iVarInfo setObject:@"BOOL" forKey:@"type"];
                    [iVarInfo setObject:[NSString stringWithFormat:@"%d", (int)boolVal&0xff] forKey:@"value"];
                } else {
                    [iVarInfo setObject:[iVar objectForKey:key] forKey:@"type"];
                    [iVarInfo setObject:[NSString stringWithFormat:@"[%s] pointer @ %p", type, ptr] forKey:@"value"];
                }
            } else {
                // This is likely to be an Objective-C class. Hey, what's the worst that could happen if it's not?
                // That would be a segfault. Signal 11. Do not pass go, do not collect a stack trace.
                // This is a shady janky-ass mofo of a function. 
                [iVarInfo setObject:[iVar objectForKey:key] forKey:@"type"];
                [iVarInfo setObject:[NSString stringWithFormat:@"%@", ptr] forKey:@"value"];
            }
            [iVarData addObject:iVarInfo];
            [iVarInfo release];
        }
    }

    return [iVarData copy];
}



@end


/***********************************************************************************************
 * These are private functions that aren't intended to be exposed to iSpy class and/or Cycript *
 ***********************************************************************************************/

static NSString *changeDateToDateString(NSDate *date) {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *dateString = [dateFormatter stringFromDate:date];
    if(dateString == nil)
        return @"Bad date.";
    return dateString;
}


// The caller is responsible for calling free() on the pointer returned by this function.
static char *bf_get_type_from_signature(char *typeStr) {
    char *type;
    bool isPointer=false;
    char *newType;
    char *closeQuote;
    char tmp[1024];
    int index = 0;

    if(!typeStr) {
        if((newType = (char *)malloc(7)) == NULL)
            return NULL;
        // I always advise people not to to this, but...
        strcpy(newType, "(null)");
        return newType;
    }
    //bf_logwrite(LOG_GENERAL,"type: %s", typeStr);

    if (typeStr[0] == '^') {
        index++;
        isPointer=true;
    }

    if(typeStr[index]) {
        switch (typeStr[index]) {
            case 'd': type = (char *)"double"; break;
            case 'i': type = (char *)"int"; break;
            case 'f': type = (char *)"float"; break;
            case 'c': type = (char *)"char"; break;
            case 's': type = (char *)"short"; break;
            case 'I': type = (char *)"unsigned int"; break;
            case 'l': type = (char *)"long"; break;
            case 'q': type = (char *)"long long"; break;
            case 'L': type = (char *)"unsigned long"; break;
            case 'C': type = (char *)"unsigned char"; break;
            case 'S': type = (char *)"unsigned short"; break;
            case 'Q': type = (char *)"unsigned long long"; break;
            case 'B': type = (char *)"BOOL"; break;
            case 'v': type = (char *)"void"; break;
            case '*': type = (char *)"char *"; break;
            case ':': type = (char *)"SEL"; break;
            case '#': type = (char *)"Class"; break;
            case '@': 
                type = (char *)"id"; 
                if(typeStr[index+1] == 0)
                    break;
                if(typeStr[index+1] == 0x22 && strlen(typeStr) > 2) {
                    strncpy(tmp, &typeStr[index + 2], 1023);
                    type = closeQuote = tmp;
                    while (*closeQuote && *closeQuote != 0x22)
                        closeQuote++;
                    *closeQuote = 0;
                    isPointer = true; // is there ever a case where this is false? 
                } 

                else if (typeStr[index+1] == '?') {
                    type = (char *)"^(__bf_unknown_args__)";
                }
                if(type[0] == 0)
                    type = (char *)"id";
                break;
            case 'V': type = (char *)"void"; break;
            case 'r': type = (char *)"const void *"; break;
            case '{': // struct
                //bf_logwrite(LOG_GENERAL, "struct %s", &typeStr[index + 1]);
                snprintf(tmp, 1023, "struct %s", &typeStr[index + 1]);
                type = closeQuote = tmp;
                while(*closeQuote && *closeQuote != '=')
                    closeQuote++;
                *closeQuote = 0;
                //bf_logwrite(LOG_GENERAL, "  now: %s", tmp);
                break;
            case '?': 
                type = (char *)"^(__bf_unknown_args__)";
                break;
            default: 
                //bf_logwrite(LOG_GENERAL, "Unknown data type: %s", typeStr);
                type = (char *)"__bf_unknown_type__"; 
                break;
        }
    } else {
        type = (char *)"__bf_null_type_data__";
    }
    if((newType = (char *)malloc(strlen(type)+3)) == NULL) // +3 is to allow room for " *"
        return NULL;
    // strcpy() takes me to a happy place
    strcpy(newType, type);
    if(isPointer)
        strcat(newType, " *");
        
    return newType;
}

/*
    Returns the human-friendly return type for the method specified.
    Eg. "void" or "char *" or "id", etc.
    The caller must free() the buffer returned by this func.
*/
static char *bf_get_friendly_method_return_type(Method method) {
    // Here's, I'll paste from the Apple docs:
    //      "The method's return type string is copied to dst. dst is filled as if strncpy(dst, parameter_type, dst_len) were called."
    // Um, ok... but how big does my destination buffer need to be?
    char tmpBuf[1024];
    
    // Does it pad with a NULL? Jeez. *shakes fist in Apple's general direction*
    method_getReturnType(method, tmpBuf, 1023);
    return bf_get_type_from_signature(tmpBuf);
}

// based on code from https://gist.github.com/markd2/5961219
// You must free the resulting pointer
static char *bf_get_attrs_from_signature(char *attributeCString) {
    NSString *attributeString = @( attributeCString );
    NSArray *chunks = [attributeString componentsSeparatedByString: @","];
    NSMutableArray *translatedChunks = [NSMutableArray arrayWithCapacity: chunks.count];
    char *subChunk, *type;

    NSString *string;

    for (NSString *chunk in chunks) {
        unichar first = [chunk characterAtIndex: 0];

        switch (first) {
            case 'T': // encode type. @ has class name after it
                subChunk = (char *)[[chunk substringFromIndex: 1] UTF8String];
                type = bf_get_type_from_signature(subChunk);
                break;
            case 'V': // backing ivar name
                //string = [NSString stringWithFormat: @"ivar: %@", [chunk substringFromIndex: 1]];
                //[translatedChunks addObject: string];
                break;
            case 'R': // read-only
                [translatedChunks addObject: @"readonly"];
                break;
            case 'C': // copy
                [translatedChunks addObject: @"copy"];
                break;
            case '&': // retain
                [translatedChunks addObject: @"retain"];
                break;
            case 'N': // non-atomic
                [translatedChunks addObject: @"non-atomic"];
                break;
            case 'G': // custom getter
                string = [NSString stringWithFormat: @"getter: %@",[chunk substringFromIndex: 1]];
                [translatedChunks addObject: string];
                break;
            case 'S': // custom setter
                string = [NSString stringWithFormat: @"setter: %@", [chunk substringFromIndex: 1]];
                [translatedChunks addObject: string];
                break;
            case 'D': // dynamic
                [translatedChunks addObject: @"dynamic"];
                break;
            case 'W': // weak
                [translatedChunks addObject: @"weak"];
                break;
            case 'P': // eligible for GC
                [translatedChunks addObject: @"GC"];
                break;
            case 't': // old-style encoding
                [translatedChunks addObject: chunk];
                break;
            default:
                [translatedChunks addObject: chunk];
                break;
        }
    }
    NSString *result = [NSString stringWithFormat:@"(%@) %s", [translatedChunks componentsJoinedByString: @", "], type];

    return strdup([result UTF8String]);
}

/*
    This incorporates code originally from http://doxygen.asterisk.org/asterisk1.0/dlfcn_8c.html
    It's been tweaked to fit this purpose.
*/
/*
static void bf_enumerate_symbol_table() {
    unsigned long i;
    unsigned long j;
    struct mach_header *mh = 0;
    struct load_command *lc = 0;
    unsigned long table_off = (unsigned long)0;
    unsigned int vmAddrSlide;
    unsigned int flags;
    char* errorMessage;
    iSpy *mySpy = [iSpy sharedInstance];
    sqlite3 *dbHandle = [[mySpy db] handle];
    sqlite3_stmt *stmt;

    // prep for speed
    sqlite3_exec(dbHandle, "PRAGMA synchronous=OFF", NULL, NULL, &errorMessage);
    sqlite3_exec(dbHandle, "PRAGMA count_changes=OFF", NULL, NULL, &errorMessage);
    sqlite3_exec(dbHandle, "PRAGMA journal_mode=MEMORY", NULL, NULL, &errorMessage);
    sqlite3_exec(dbHandle, "PRAGMA temp_store=MEMORY", NULL, NULL, &errorMessage);
    sqlite3_exec(dbHandle, "BEGIN TRANSACTION", NULL, NULL, &errorMessage);
    sqlite3_prepare_v2(dbHandle, "INSERT INTO symbols (name, offset, n_stab, n_pext, n_ext, n_pbud, n_indr, n_arm, type) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)", -1, &stmt, NULL);

    // Grab the ASLR slide info
    vmAddrSlide = (unsigned int)_dyld_get_image_vmaddr_slide(0);
    bf_logwrite(LOG_GENERAL, "ASLR slide = 0x%x", vmAddrSlide);

    // Find the __LINKEDIT segment of the Mach-O header in memory
    mh = (struct mach_header *)_dyld_get_image_header(0);
    
    // cache a copy of the Mach-O header flags for later
    flags = mh->flags;
    
    // find the relevant load command and segment name
    lc = (struct load_command *)((char *)mh + sizeof(struct mach_header));
    for (j = 0; j < mh->ncmds; j++, lc = (struct load_command *)((char *)lc + lc->cmdsize)) {
        if (LC_SEGMENT == lc->cmd) {
            if (!strcmp(((struct segment_command *)lc)->segname, "__LINKEDIT"))
                break;
        }
    }
    
    if(strcmp(((struct segment_command *)lc)->segname, "__LINKEDIT"))
        return;

    bf_logwrite(LOG_GENERAL, "Found __LINKEDIT");

    // Calculate the offset to the Load Commands
    table_off =
        ((unsigned long)((struct segment_command *)lc)->vmaddr) -
        ((unsigned long)((struct segment_command *)lc)->fileoff) + vmAddrSlide;

    bf_logwrite(LOG_GENERAL, "Table offset = 0x%x", table_off);

    // Find the Load Command(s) for the symbol table(s)
    lc = (struct load_command *)((char *)mh + sizeof(struct mach_header));
    for (j = 0; j < mh->ncmds; j++, lc = (struct load_command *)((char *)lc + lc->cmdsize)) {
        
        // Is this a symbol table?
        if(LC_SYMTAB == lc->cmd) {
            struct nlist *symtable = (struct nlist *)(((struct symtab_command *)lc)->symoff + table_off);
            unsigned long numsyms = ((struct symtab_command *)lc)->nsyms;
            unsigned long strtable = (unsigned long)(((struct symtab_command *)lc)->stroff + table_off);
            
            // Loop through each entry in the symbol table, dumping all the things
            for (i = 0; i < numsyms; i++) {
                if(symtable) {
                    if(strlen((char *)(strtable + symtable->n_un.n_strx))) {                        
                        unsigned int type = (unsigned int)symtable->n_type;
                        sqlite3_bind_text(stmt, 1, (char *)(strtable + symtable->n_un.n_strx), strlen((char *)(strtable + symtable->n_un.n_strx)), SQLITE_STATIC);
                        sqlite3_bind_int(stmt, 2, (int)symtable->n_value);
                        sqlite3_bind_int(stmt, 3, (int)(type & N_STAB) ? 1 : 0);
                        sqlite3_bind_int(stmt, 4, (int)(type & N_PEXT) ? 1 : 0);
                        sqlite3_bind_int(stmt, 5, (int)(type & N_EXT) ? 1 : 0);
                        sqlite3_bind_int(stmt, 6, (int)(type & N_PBUD) ? 1 : 0);
                        sqlite3_bind_int(stmt, 7, (int)(type & N_INDR) ? 1 : 0);
                        sqlite3_bind_int(stmt, 8, (int)(type & N_ARM_THUMB_DEF) ? 1 : 0);
                        sqlite3_bind_int(stmt, 9, (int)type);
                        sqlite3_step(stmt);
                        sqlite3_reset(stmt);
                    }
                }
                symtable++;
            }
        }
    }
    sqlite3_exec(dbHandle, "COMMIT TRANSACTION", NULL, NULL, &errorMessage);
    sqlite3_finalize(stmt);
    sqlite3_prepare_v2(dbHandle, "INSERT INTO machFlags (flags) VALUES(?1)", -1, &stmt, NULL);
    sqlite3_bind_int(stmt, 1, (int)flags);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return;
}
*/

EXPORT NSString *base64forData(NSData *theData) {
    const uint8_t* input = (const uint8_t*)[theData bytes];
    NSInteger length = [theData length];

    static char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";

    NSMutableData* data = [NSMutableData dataWithLength:((length + 2) / 3) * 4];
    uint8_t* output = (uint8_t*)data.mutableBytes;

    NSInteger i;
    for (i=0; i < length; i += 3) {
        NSInteger value = 0;
        NSInteger j;
        for (j = i; j < (i + 3); j++) {
            value <<= 8;

            if (j < length) {
                value |= (0xFF & input[j]);
            }
        }

        NSInteger theIndex = (i / 3) * 4;
        output[theIndex + 0] =                    table[(value >> 18) & 0x3F];
        output[theIndex + 1] =                    table[(value >> 12) & 0x3F];
        output[theIndex + 2] = (i + 1) < length ? table[(value >> 6)  & 0x3F] : '=';
        output[theIndex + 3] = (i + 2) < length ? table[(value >> 0)  & 0x3F] : '=';
    }

    return [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] autorelease];
}


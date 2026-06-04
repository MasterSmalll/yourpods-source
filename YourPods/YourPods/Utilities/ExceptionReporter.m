#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// This file installs a diagnostic hook that logs the actual NSException
// before AppKit's _crashOnException: terminates the app.
// It swizzles -[NSApplication reportException:] at load time.

#if TARGET_OS_OSX

static void (*original_reportException)(id self, SEL _cmd, NSException *exception);

static void swizzled_reportException(id self, SEL _cmd, NSException *exception) {
    NSString *message = [NSString stringWithFormat:
        @"\n\n⚠️ CAUGHT EXCEPTION:\n"
        @"Name: %@\n"
        @"Reason: %@\n"
        @"UserInfo: %@\n"
        @"CallStack:\n%@\n\n",
        exception.name,
        exception.reason ?: @"(none)",
        exception.userInfo ?: @{},
        [exception.callStackSymbols componentsJoinedByString:@"\n"]
    ];
    
    // Print to stderr (shows in Xcode console)
    fprintf(stderr, "%s", message.UTF8String);
    
    // Write to file
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"yourpods_crash.log"];
    [message writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    
    // Call original implementation
    if (original_reportException) {
        original_reportException(self, _cmd, exception);
    }
}

__attribute__((constructor))
static void installExceptionReporter(void) {
    Class appClass = NSClassFromString(@"NSApplication");
    if (!appClass) return;
    
    Method method = class_getInstanceMethod(appClass, @selector(reportException:));
    if (!method) return;
    
    original_reportException = (void (*)(id, SEL, NSException *))method_getImplementation(method);
    method_setImplementation(method, (IMP)swizzled_reportException);
    
    fprintf(stderr, "[ExceptionReporter] Installed exception reporter hook\n");
}

#endif

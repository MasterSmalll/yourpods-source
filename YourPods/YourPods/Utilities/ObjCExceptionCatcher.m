#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable NSError *)catchWithBlock:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
    }
    @catch (NSException *exception) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
        if (exception.userInfo) {
            userInfo[@"ExceptionUserInfo"] = exception.userInfo;
        }
        userInfo[@"ExceptionName"] = exception.name;
        return [NSError errorWithDomain:@"com.yourpods.ObjCException"
                                   code:1
                               userInfo:userInfo];
    }
    return nil;
}

@end

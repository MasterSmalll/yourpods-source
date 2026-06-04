#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches Objective-C exceptions (NSException) and converts them to NSError.
/// Swift's do/catch cannot intercept ObjC exceptions — this bridge is required
/// for safety when calling APIs like NSAttributedString(data:options:.html)
/// that internally use WebKit and can throw assertion failures.
@interface ObjCExceptionCatcher : NSObject

/// Execute `block`. If it raises an NSException, catch it and return an NSError
/// describing the exception. Returns nil if no exception was raised.
+ (nullable NSError *)catchWithBlock:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END

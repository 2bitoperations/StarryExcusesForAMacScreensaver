#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Execute tryBlock inside an Objective-C @try/@catch and call catchBlock if an NSException occurs.
void ExceptionCatcherTry(void (^ _Nonnull tryBlock)(void),
                         void (^ _Nonnull catchBlock)(NSException *exception));

NS_ASSUME_NONNULL_END

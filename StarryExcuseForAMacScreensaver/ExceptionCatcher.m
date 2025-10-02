#import "ExceptionCatcher.h"

void ExceptionCatcherTry(void (^ _Nonnull tryBlock)(void),
                         void (^ _Nonnull catchBlock)(NSException *exception)) {
    @try {
        if (tryBlock) { tryBlock(); }
    }
    @catch (NSException *exception) {
        if (catchBlock) { catchBlock(exception); }
    }
}

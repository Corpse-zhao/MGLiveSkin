#import "MGManager.h"

// 唯一入口：注入由 filter plist 保证，这里再做一次 bundle id 双重确认。
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.saicmotor.mgapp"]) {
            [[MGManager shared] boot];
        }
    }
}

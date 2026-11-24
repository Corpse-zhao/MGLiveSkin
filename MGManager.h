#import <Foundation/Foundation.h>

#define MG_VERSION @"0.1.9"
#define MG_TARGET_BUNDLE @"com.saicmotor.mgapp"

@interface MGManager : NSObject
+ (instancetype)shared;
- (void)boot;
@end

#import "MGManager.h"
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

// ---------------- 常量 ----------------
static NSString * const kKeyCarRect      = @"mgliveskin_car_rect";
static NSString * const kKeyRegionMap    = @"mgliveskin_region_map";   // {VC类名: "x,y,w,h"} 归一化屏幕坐标
static NSString * const kKeyManualMap    = @"mgliveskin_manual_map";   // 旧版视图类匹配，boot 清除
static NSString * const kKeyManualClass  = @"mgliveskin_manual_class"; // 旧版单值，boot 清除
static NSString * const kKeyBallHidden   = @"mgliveskin_ball_hidden";

// ---------------- 日志 ----------------
static NSString *MGDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/MGLiveSkin"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}

static void MGLogLine(NSString *line) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
    });
    NSString *out = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSString *path = [MGDir() stringByAppendingPathComponent:@"log.txt"];
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long sz = [[fm attributesOfItemAtPath:path error:NULL] fileSize];
    if (sz > 400 * 1024) {
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (!h) {
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [h seekToEndOfFile];
    [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}
#define MGLog(...) do { MGLogLine([NSString stringWithFormat:__VA_ARGS__]); } while (0)

// ---------------- 图片工具（沿用九号插件已验证算法） ----------------
static NSData *MGPNGData(NSData *data) {
    if (!data.length) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                                (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!dst) { CGImageRelease(img); return nil; }
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    return ok ? out : nil;
}

static NSData *MGEncodePNG(CGImageRef img) {
    if (!img) return nil;
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
                                                                (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!dst) return nil;
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? out : nil;
}

// 从四边泛洪抹掉与背景连通的近白像素
static size_t MGStripWhite(uint8_t *p, int w, int h) {
    const int T = 243;
    size_t cap = (size_t)(w + h) * 8 + 1024;
    int32_t *sx = (int32_t *)malloc(sizeof(int32_t) * cap);
    int32_t *sy = (int32_t *)malloc(sizeof(int32_t) * cap);
    if (!sx || !sy) { free(sx); free(sy); return 0; }
    size_t sp = 0;
#define MSG_IS_BG(q) ((q)[3] == 255 && (q)[0] >= T && (q)[1] >= T && (q)[2] >= T)
#define MSG_PUSH(px, py) do { if (sp < cap) { sx[sp] = (px); sy[sp] = (py); sp++; } } while (0)
    for (int x = 0; x < w; x++) {
        if (MSG_IS_BG(p + (size_t)x * 4)) MSG_PUSH(x, 0);
        if (MSG_IS_BG(p + ((size_t)(h - 1) * w + x) * 4)) MSG_PUSH(x, h - 1);
    }
    for (int y = 0; y < h; y++) {
        if (MSG_IS_BG(p + (size_t)y * w * 4)) MSG_PUSH(0, y);
        if (MSG_IS_BG(p + ((size_t)y * w + w - 1) * 4)) MSG_PUSH(w - 1, y);
    }
    size_t filled = 0;
    while (sp > 0) {
        sp--;
        int x = sx[sp], y = sy[sp];
        uint8_t *row = p + (size_t)y * w * 4;
        if (!MSG_IS_BG(row + (size_t)x * 4)) continue;
        int l = x, r = x;
        while (l - 1 >= 0 && MSG_IS_BG(row + (size_t)(l - 1) * 4)) l--;
        while (r + 1 < w && MSG_IS_BG(row + (size_t)(r + 1) * 4)) r++;
        for (int i = l; i <= r; i++) {
            uint8_t *q = row + (size_t)i * 4;
            q[0] = q[1] = q[2] = q[3] = 0;
            filled++;
        }
        for (int dy = -1; dy <= 1; dy += 2) {
            int ny = y + dy;
            if (ny < 0 || ny >= h) continue;
            uint8_t *nrow = p + (size_t)ny * w * 4;
            BOOL run = NO;
            for (int i = l; i <= r; i++) {
                BOOL bg = MSG_IS_BG(nrow + (size_t)i * 4);
                if (bg && !run) { MSG_PUSH(i, ny); run = YES; }
                else if (!bg) run = NO;
            }
        }
    }
#undef MSG_IS_BG
#undef MSG_PUSH
    free(sx); free(sy);
    return filled;
}

static CGRect MGOpaqueBounds(uint8_t *p, int w, int h) {
    int minX = w, minY = h, maxX = -1, maxY = -1;
    for (int y = 0; y < h; y++) {
        uint8_t *row = p + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            if (row[(size_t)x * 4 + 3] > 8) {
                if (x < minX) minX = x;
                if (x > maxX) maxX = x;
                if (y < minY) minY = y;
                if (y > maxY) maxY = y;
            }
        }
    }
    if (maxX < 0) return CGRectZero;
    return CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
}

// 任意图片 -> 去白底 + 裁边 PNG
static NSData *MGPrepareCarPNG(NSData *data) {
    if (!data.length) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return nil;
    size_t ow = CGImageGetWidth(img), oh = CGImageGetHeight(img);
    if (!ow || !oh) { CGImageRelease(img); return nil; }
    CGFloat sc = 1.0;
    if (MAX(ow, oh) > 1600) sc = 1600.0 / (CGFloat)MAX(ow, oh);
    size_t w = (size_t)lround((double)ow * sc), h = (size_t)lround((double)oh * sc);
    if (!w) w = 1;
    if (!h) h = 1;

    NSMutableData *buf = [NSMutableData dataWithLength:w * 4 * h];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { CGImageRelease(img); return nil; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
    CGImageRelease(img);

    uint8_t *p = (uint8_t *)buf.mutableBytes;
    size_t px = w * h;
    BOOL opaque = YES;
    for (size_t i = 0; i < px; i++) { if (p[i * 4 + 3] < 250) { opaque = NO; break; } }
    if (opaque) {
        size_t filled = MGStripWhite(p, (int)w, (int)h);
        if (filled > px * 9 / 10) { CGContextRelease(ctx); return MGPNGData(data); }
    }
    CGRect box = MGOpaqueBounds(p, (int)w, (int)h);
    CGImageRef full = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!full) return MGPNGData(data);
    CGRect use = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
    if (!CGRectIsEmpty(box)) {
        CGFloat area = box.size.width * box.size.height;
        if (area >= (CGFloat)px * 0.06 && area <= (CGFloat)px * 0.995) {
            use = CGRectIntegral(CGRectInset(box, -box.size.width * 0.02, -box.size.height * 0.02));
            use = CGRectIntersection(use, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h));
            if (CGRectIsNull(use) || use.size.width < 1 || use.size.height < 1)
                use = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
        }
    }
    NSData *out = nil;
    if (use.size.width < (CGFloat)w || use.size.height < (CGFloat)h) {
        CGImageRef cropped = CGImageCreateWithImageInRect(full, use);
        if (cropped) { out = MGEncodePNG(cropped); CGImageRelease(cropped); }
    }
    if (!out) out = MGEncodePNG(full);
    CGImageRelease(full);
    return out;
}

static NSString *MGFileStamp(NSString *path) {
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    NSNumber *sz = a[NSFileSize];
    NSDate *md = a[NSFileModificationDate];
    if (![sz isKindOfClass:[NSNumber class]]) return nil;
    return [NSString stringWithFormat:@"%llu|%.4f", sz.unsignedLongLongValue,
            md ? md.timeIntervalSince1970 : 0.0];
}

static CGRect MGParseRect(NSString *s) {
    NSArray *p = [s componentsSeparatedByString:@","];
    if (p.count < 4) return CGRectMake(0, 0, 1, 1);
    CGRect r = CGRectMake([p[0] floatValue], [p[1] floatValue], [p[2] floatValue], [p[3] floatValue]);
    if (r.size.width <= 0.01 || r.size.height <= 0.01) return CGRectMake(0, 0, 1, 1);
    return r;
}

// ---------------- 反闪回：接管 UIView 的 setHidden: ----------------
static IMP gOrigSetHidden = NULL;
static __weak UIView *gGuardView = nil;

static void MGSetHidden(id self, SEL _cmd, BOOL hidden) {
    if (!hidden && gGuardView == (UIView *)self) hidden = YES;
    if (gOrigSetHidden) ((void (*)(id, SEL, BOOL))gOrigSetHidden)(self, _cmd, hidden);
}

// ---------------- 穿透窗口 / 框选视图 ----------------
@interface MGPassWindow : UIWindow
@end
@implementation MGPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    if (!hit || hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface MGSelectionView : UIView
@property (nonatomic, copy) void (^pickRect)(CGRect r);   // self 坐标系
@end

@implementation MGSelectionView {
    CGPoint _start;
    CGRect _cur;
    CAShapeLayer *_box;
    BOOL _dragging;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = NO;
        _box = [CAShapeLayer layer];
        _box.fillColor = [[UIColor colorWithRed:1.0 green:0.42 blue:0.0 alpha:0.18] CGColor];
        _box.strokeColor = [[UIColor colorWithRed:1.0 green:0.42 blue:0.0 alpha:0.95] CGColor];
        _box.lineWidth = 2.0;
        _box.lineDashPattern = @[@6, @4];
        _box.hidden = YES;
        [self.layer addSublayer:_box];
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _start = [[touches anyObject] locationInView:self];
    _cur = CGRectMake(_start.x, _start.y, 0, 0);
    _dragging = YES;
    _box.hidden = NO;
    _box.path = nil;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_dragging) return;
    CGPoint p = [[touches anyObject] locationInView:self];
    _cur = CGRectMake(MIN(_start.x, p.x), MIN(_start.y, p.y),
                      fabs(p.x - _start.x), fabs(p.y - _start.y));
    _box.path = [UIBezierPath bezierPathWithRect:_cur].CGPath;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_dragging) return;
    _dragging = NO;
    _box.hidden = YES;
    CGRect r = _cur;
    if (r.size.width < 40 || r.size.height < 40) {
        // 只点了一下：用点为中心给个默认框（后续可微调）
        r = CGRectMake(_start.x - 150, _start.y - 130, 300, 260);
    }
    r = CGRectIntersection(r, self.bounds);
    if (self.pickRect) self.pickRect(r);
}

@end

// ---------------- 管理器 ----------------
@interface MGManager () <PHPickerViewControllerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *ballWindow;
@property (nonatomic, strong) UIButton *ballButton;
@property (nonatomic, strong) UIWindow *selectionWindow;
@property (nonatomic, weak) UIView *carView;
@property (nonatomic, strong) UIImageView *overlayView;
@property (nonatomic, strong) UIView *adjustView;
@property (nonatomic, strong) UIImage *carImage;
@property (nonatomic, copy) NSString *imageStamp;
@property (nonatomic, assign) BOOL origSaved;
@property (nonatomic, assign) BOOL origHidden;
@property (nonatomic, assign) CGFloat origAlpha;
@property (nonatomic, assign) BOOL adjusting;
@end

@implementation MGManager

+ (instancetype)shared {
    static MGManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [MGManager new]; });
    return m;
}

#pragma mark - 启动

- (void)boot {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MGLog(@"========== MGLiveSkin %@ boot ==========", MG_VERSION);
        // 清理历史遗留：0.1.1 的隐藏标记（死胡同）、0.1.4 前的视图类匹配配置（跨页误命中）
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud removeObjectForKey:kKeyBallHidden];
        [ud removeObjectForKey:kKeyManualClass];
        [ud removeObjectForKey:kKeyManualMap];
        [self installHiddenHook];
        // App 启动后 scene 才就绪，做多轮补装
        for (int i = 1; i <= 8; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.7 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self ensureBall];
                [self applyOverlays];
            });
        }
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self
                                                        selector:@selector(tick) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onForeground)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    });
}

- (void)installHiddenHook {
    if (gOrigSetHidden) return;
    Method m = class_getInstanceMethod([UIView class], @selector(setHidden:));
    if (!m) { MGLog(@"[hook] UIView setHidden 不存在，跳过"); return; }
    gOrigSetHidden = method_setImplementation(m, (IMP)MGSetHidden);
    MGLog(@"[hook] setHidden 已接管");
}

- (void)onForeground {
    [self ensureBall];
    [self applyOverlays];
}

- (void)tick {
    if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) return;
    if (self.adjusting) return;
    [self applyOverlays];
}

#pragma mark - 窗口与页面

- (UIWindow *)appMainWindow {
    // 优先 keyWindow 且排除键盘/文本特效窗口（0.1.4 曾误取到 UIInputWindowController）
    NSArray<UIWindow *> *wins = [self appWindows];
    for (UIWindow *w in wins) {
        if (w.isKeyWindow && ![self isSystemInputWindow:w]) return w;
    }
    for (UIWindow *w in wins) {
        if (![self isSystemInputWindow:w]) return w;
    }
    return nil;
}

- (BOOL)isSystemInputWindow:(UIWindow *)w {
    NSString *rc = NSStringFromClass([w.rootViewController class]);
    if ([rc containsString:@"Input"] || [rc containsString:@"TextEffects"]) return YES;
    if ([NSStringFromClass([w class]) containsString:@"TextEffects"]) return YES;
    if (w.windowLevel >= UIWindowLevelAlert) return YES;   // 系统弹层
    return NO;
}

// 所有 App 窗口（排除插件自己的），按 windowLevel 降序、keyWindow 优先。
- (NSArray<UIWindow *> *)appWindows {
    NSMutableArray<UIWindow *> *out = [NSMutableArray new];
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w == self.ballWindow || w == self.selectionWindow) continue;
            if (w.hidden || !w.rootViewController) continue;
            if ([self isSystemInputWindow:w]) continue;
            [out addObject:w];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel > b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel < b.windowLevel) return NSOrderedDescending;
        if (a.isKeyWindow) return NSOrderedAscending;
        if (b.isKeyWindow) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

- (UIViewController *)topVC {
    UIWindow *win = [self appMainWindow];
    UIViewController *vc = win.rootViewController;
    for (int i = 0; i < 8 && vc; i++) {
        UIViewController *next = nil;
        if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed)
            next = vc.presentedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]])
            next = ((UINavigationController *)vc).topViewController;
        else if ([vc isKindOfClass:[UITabBarController class]])
            next = ((UITabBarController *)vc).selectedViewController;
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

static BOOL MGViewHasText(UIView *v, NSArray<NSString *> *keys, NSInteger depth) {
    if (!v || depth > 14) return NO;
    NSString *text = nil;
    if ([v isKindOfClass:[UILabel class]]) text = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UIButton class]]) text = [(UIButton *)v titleForState:UIControlStateNormal];
    if (text.length) {
        for (NSString *k in keys) if ([text containsString:k]) return YES;
    }
    for (UIView *s in v.subviews) {
        if (MGViewHasText(s, keys, depth + 1)) return YES;
    }
    return NO;
}

- (BOOL)onVehicleStatusPage:(UIView *)root vc:(UIViewController *)vc {
    NSString *title = vc.title ?: vc.navigationItem.title;
    for (NSString *k in @[@"车辆状态", @"VehicleStatus", @"CarStatus", @"爱车", @"续航", @"里程"]) {
        if (title.length && [title containsString:k]) return YES;
    }
    // VC 类名带 Car/Vehicle/Drive/Status/LoveCar 也算（已知 RWMyLoveCarStatuVC_DY）
    NSString *vcn = NSStringFromClass([vc class]);
    for (NSString *k in @[@"Car", @"Vehicle", @"Drive", @"Status", @"LoveCar"]) {
        if ([vcn containsString:k]) return YES;
    }
    return MGViewHasText(root, @[@"车辆状态", @"当前续航", @"总里程", @"胎压",
                                 @"续航", @"里程", @"空调", @"车辆健康",
                                 @"蓝牙控制", @"寻车", @"后备箱", @"主驾加热"], 0);
}

// 自动识别车图：按尺寸/比例/位置/页面特征打分，扫描所有 App 窗口。
// 手动框选过的配置（class+父视图+尺寸）拥有最高优先级，且跳过页面判断。
- (UIView *)findCarView {
    UIView *cached = self.carView;
    if (cached && cached.superview && cached.window) return cached;

    UIViewController *vcNow = [self topVC];
    NSString *vcKey = NSStringFromClass([vcNow class]);
    NSDictionary *map = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kKeyManualMap];
    id rawCfg = map[vcKey];
    NSString *mCls = nil, *mSup = nil;
    CGFloat mW = 0, mH = 0;
    if ([rawCfg isKindOfClass:[NSString class]]) {          // 旧格式：仅 class
        mCls = rawCfg;
    } else if ([rawCfg isKindOfClass:[NSDictionary class]]) {
        mCls = rawCfg[@"cls"];
        mSup = rawCfg[@"sup"];
        mW = [rawCfg[@"w"] floatValue];
        mH = [rawCfg[@"h"] floatValue];
    }

    UIView *autoBest = nil;
    CGFloat autoBestScore = 0;
    UIWindow *autoWin = nil;
    BOOL anyPageOK = NO;

    for (UIWindow *win in [self appWindows]) {
        UIView *root = win.rootViewController.view;
        if (!root) continue;
        CGFloat W = win.bounds.size.width, H = win.bounds.size.height;
        if (W < 100 || H < 100) continue;

        // ---- 手动路径：class + 父视图 + 尺寸，逐级放宽 ----
        if (mCls.length) {
            struct { NSString *sup; BOOL needSize; int pass; } passes[] = {
                { mSup, YES, 1 },   // 全匹配
                { mSup, NO,  2 },   // class + 父视图
                { nil,  NO,  3 },   // 仅 class
            };
            for (int pi = 0; pi < 3; pi++) {
                NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
                UIView *best = nil;
                CGFloat bestArea = 0;
                while (stack.count) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    if (v == self.overlayView || v == self.adjustView) continue;
                    if (!v.hidden && v.alpha > 0.05 &&
                        [NSStringFromClass([v class]) isEqualToString:mCls]) {
                        CGSize b = v.bounds.size;
                        if (b.width >= 50 && b.height >= 50) {
                            if (passes[pi].sup.length &&
                                ![NSStringFromClass([v.superview class]) isEqualToString:passes[pi].sup]) {
                                if (stack.count < 4000) [stack addObjectsFromArray:v.subviews];
                                continue;
                            }
                            if (passes[pi].needSize) {
                                CGFloat dw = fabs(b.width - mW) / MAX(mW, 1.0);
                                CGFloat dh = fabs(b.height - mH) / MAX(mH, 1.0);
                                if (dw > 0.35 || dh > 0.35) {
                                    if (stack.count < 4000) [stack addObjectsFromArray:v.subviews];
                                    continue;
                                }
                            }
                            CGRect fr = [v convertRect:v.bounds toView:root];
                            CGRect vis = CGRectIntersection(fr, root.bounds);
                            if (vis.size.width * vis.size.height >= b.width * b.height * 0.6) {
                                CGFloat area = b.width * b.height;
                                if (area > bestArea) { bestArea = area; best = v; }
                            }
                        }
                    }
                    if (stack.count < 4000) [stack addObjectsFromArray:v.subviews];
                }
                if (best) {
                    self.carView = best;
                    MGLog(@"[识别] 手动配置命中(P%d 窗口 %@) %@ frame=%@ superview=%@",
                          passes[pi].pass, NSStringFromClass([win class]),
                          NSStringFromClass([best class]), NSStringFromCGRect(best.frame),
                          NSStringFromClass([best.superview class]));
                    return best;
                }
            }
            continue;   // 此窗口没有手动目标，继续下一个窗口（不回退自动，避免误命中）
        }

        // ---- 自动路径 ----
        BOOL pageOK = [self onVehicleStatusPage:root vc:vcNow];
        if (!pageOK) continue;
        anyPageOK = YES;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if (v == self.overlayView || v == self.adjustView) continue;
            UIImage *im = [v isKindOfClass:[UIImageView class]] ? ((UIImageView *)v).image : nil;
            NSString *cn = NSStringFromClass([v class]);
            // 3D 渲染视图（SceneKit / GLKit / Metal）没有 image 也没有 contents，单独认出来
            BOOL is3D = ([cn containsString:@"GLK"] || [cn containsString:@"SCN"] ||
                         [cn containsString:@"MTK"] || [cn containsString:@"Metal"] ||
                         [cn containsString:@"GLView"]);
            BOOL hasVisual = (im != nil || v.layer.contents != NULL || is3D);
            if (hasVisual && !v.hidden && v.alpha > 0.05) {
                CGSize b = v.bounds.size;
                CGRect inRoot = [v convertRect:v.bounds toView:root];
                CGRect vis = CGRectIntersection(inRoot, root.bounds);
                if (vis.size.width * vis.size.height < b.width * b.height * 0.6) continue;
                CGFloat ratio = b.height / MAX(b.width, 1.0);
                BOOL sizeOK = (b.width >= 90 && b.width <= W * 0.85 &&
                               b.height >= 110 && b.height <= H * 0.75 &&
                               ratio >= 0.25 && ratio <= 6.0);
                BOOL bgLike = (b.width >= W * 0.98 && b.height >= H * 0.9);
                CGFloat midX = CGRectGetMidX(inRoot);
                BOOL centerOK = (midX > W * 0.10 && midX < W * 0.90);
                if (sizeOK && centerOK && !bgLike) {
                    CGFloat score = (b.width * b.height) / (W * H) * 10.0;
                    if (im) score += 2.0;
                    if (is3D) score += 9.0;   // 3D 车模优先级最高，且直接可隐藏
                    for (UIView *p = v.superview; p && p != root; p = p.superview) {
                        if ([p isKindOfClass:[UIControl class]]) { score += 8.0; break; }
                    }
                    if ([cn containsString:@"Car"] || [cn containsString:@"Vehicle"] ||
                        [cn containsString:@"Status"]) score += 6.0;
                    if (score > autoBestScore) { autoBestScore = score; autoBest = v; autoWin = win; }
                }
            }
            if (stack.count < 4000) [stack addObjectsFromArray:v.subviews];
        }
    }

    if (mCls.length) {
        MGLog(@"[识别] 手动配置 %@ 在所有窗口未找到", mCls);
        return nil;
    }
    if (autoBestScore < 3.0 || !autoBest) {
        MGLog(@"[识别] 未找到车图（page=%@ anyPageOK=%d 最高分 %.2f）",
              vcKey, (int)anyPageOK, autoBestScore);
        return nil;
    }
    self.carView = autoBest;
    MGLog(@"[识别] 自动命中(窗口 %@) %@ frame=%@ score=%.2f",
          NSStringFromClass([autoWin class]), NSStringFromClass([autoBest class]),
          NSStringFromCGRect(autoBest.frame), autoBestScore);
    return autoBest;
}

// 手动框选时，按落点找图片视图：从最上层窗口往下扫，
// 在包含落点的候选里选面积最大的非背景图（避免选中全屏背景）
- (UIView *)findImageViewNearPoint:(CGPoint)p inWindow:(UIWindow *)ignored {
    for (UIWindow *win in [self appWindows]) {
        UIView *root = win.rootViewController.view;
        if (!root) continue;
        CGFloat W = win.bounds.size.width, H = win.bounds.size.height;
        CGFloat maxArea = W * H * 0.6;   // 超过屏幕 60% 的当背景排除
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
        UIView *best = nil;
        CGFloat bestArea = 0;
        while (stack.count) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if (v == self.overlayView || v == self.adjustView) continue;
            UIImage *im = [v isKindOfClass:[UIImageView class]] ? ((UIImageView *)v).image : nil;
            if (im || v.layer.contents) {
                CGRect r = [v convertRect:v.bounds toView:win];
                if (CGRectContainsPoint(r, p) && !v.hidden && v.alpha > 0.05) {
                    CGFloat area = r.size.width * r.size.height;
                    if (area > bestArea && area <= maxArea &&
                        r.size.width >= 50 && r.size.height >= 50) {
                        bestArea = area;
                        best = v;
                    }
                }
            }
            if (stack.count < 4000) [stack addObjectsFromArray:v.subviews];
        }
        if (best) {
            MGLog(@"[框选] 命中于窗口 %@ level=%.0f", NSStringFromClass([win class]), win.windowLevel);
            return best;
        }
    }
    return nil;
}

#pragma mark - 覆盖 / 还原

- (CGRect)normRect {
    return MGParseRect([[NSUserDefaults standardUserDefaults] stringForKey:kKeyCarRect]);
}

- (void)saveNormRect:(CGRect)r {
    NSString *s = [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f",
                   r.origin.x, r.origin.y, r.size.width, r.size.height];
    [[NSUserDefaults standardUserDefaults] setObject:s forKey:kKeyCarRect];
}

#pragma mark - 区域模式（车图是 3D 渲染，没有 UIImageView 可替换，只能按区域覆盖）

- (NSString *)currentVCKey {
    return NSStringFromClass([[self topVC] class]);
}

- (CGRect)regionNormForVC:(NSString *)vcKey {
    NSDictionary *m = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kKeyRegionMap];
    NSString *s = [m isKindOfClass:[NSDictionary class]] ? m[vcKey] : nil;
    if (![s isKindOfClass:[NSString class]] || !s.length) return CGRectNull;
    return MGParseRect(s);
}

- (void)saveRegion:(CGRect)r forVC:(NSString *)vcKey {
    if (!vcKey.length) return;
    NSMutableDictionary *m = [[[NSUserDefaults standardUserDefaults]
                               dictionaryForKey:kKeyRegionMap] mutableCopy] ?: [NSMutableDictionary new];
    m[vcKey] = [NSString stringWithFormat:@"%.4f,%.4f,%.4f,%.4f",
                r.origin.x, r.origin.y, r.size.width, r.size.height];
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:kKeyRegionMap];
}

// 按当前页面的区域配置挂载覆盖图；没有配置则返回 NO
- (BOOL)mountRegionOverlayIfNeeded {
    UIWindow *win = [self appMainWindow];
    UIView *root = win.rootViewController.view;
    if (!win || !root) return NO;
    CGRect n = [self regionNormForVC:[self currentVCKey]];
    if (CGRectIsNull(n)) return NO;   // 本页没画框 → 交给视图模式

    if (!self.carImage) {
        // 区域已定但还没选图：清掉旧 overlay，且不再回落到视图模式
        if (self.overlayView) [self unmountOverlay];
        return YES;
    }
    // 从旧模式切过来：先把被隐藏的原图还原
    if (self.carView) {
        UIView *old = self.carView;
        self.carView = nil;
        if (gGuardView == old) gGuardView = nil;
        if (self.origSaved) {
            old.hidden = self.origHidden;
            old.alpha = self.origAlpha;
            self.origSaved = NO;
        }
    }
    if (!self.overlayView) {
        UIImageView *iv = [UIImageView new];
        iv.backgroundColor = [UIColor clearColor];
        iv.userInteractionEnabled = NO;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.clipsToBounds = NO;
        iv.autoresizingMask = UIViewAutoresizingNone;
        self.overlayView = iv;
    }
    CGSize R = root.bounds.size;
    self.overlayView.image = self.carImage;
    self.overlayView.frame = CGRectMake(n.origin.x * R.width, n.origin.y * R.height,
                                        n.size.width * R.width, n.size.height * R.height);
    if (self.overlayView.superview != root) {
        [self.overlayView removeFromSuperview];
        [root addSubview:self.overlayView];
    } else {
        [root bringSubviewToFront:self.overlayView];
    }
    if (self.adjustView) {
        self.adjustView.frame = self.overlayView.frame;
        if (self.adjustView.superview != root) {
            [self.adjustView removeFromSuperview];
            [root addSubview:self.adjustView];
        }
        [root bringSubviewToFront:self.adjustView];
    }
    return YES;
}

- (CGRect)overlayFrameForCar:(UIView *)car {
    if (!car || !car.superview) return CGRectNull;
    CGRect base = [car convertRect:car.bounds toView:car.superview];
    if (base.size.width < 40 || base.size.height < 40) return CGRectNull;
    CGRect n = [self normRect];
    CGRect f = CGRectMake(base.origin.x + n.origin.x * base.size.width,
                          base.origin.y + n.origin.y * base.size.height,
                          n.size.width * base.size.width,
                          n.size.height * base.size.height);
    if (f.size.width > base.size.width * 1.6 || f.size.height > base.size.height * 1.6) {
        MGLog(@"[覆盖] 比例数据异常 %@，回退原车占位", NSStringFromCGRect(n));
        return base;
    }
    return f;
}

- (void)unmountOverlay {
    [self.overlayView removeFromSuperview];
    self.overlayView = nil;
    [self.adjustView removeFromSuperview];
    self.adjustView = nil;
    self.adjusting = NO;
}

- (void)restoreCar:(UIView *)car {
    [self unmountOverlay];
    if (gGuardView == car) gGuardView = nil;
    if (self.origSaved && car) {
        car.hidden = self.origHidden;
        car.alpha = self.origAlpha;
        self.origSaved = NO;
    }
}

- (void)applyOverlays {
    NSString *path = [MGDir() stringByAppendingPathComponent:@"car.png"];
    NSString *stamp = MGFileStamp(path);
    if (![stamp isEqualToString:self.imageStamp]) {
        self.imageStamp = stamp;
        self.carImage = [[UIImage alloc] initWithContentsOfFile:path];
        MGLog(@"[图片] 重新加载 %@ stamp=%@", self.carImage ? @"OK" : @"失败", stamp);
    }
    // 只走区域模式：车图是 3D 渲染（无 UIImageView 可换），本页没有区域就什么都不做
    if ([self mountRegionOverlayIfNeeded]) return;
    if (self.overlayView) [self unmountOverlay];
    if (self.carView) {   // 从旧模式残留的隐藏状态还原
        UIView *old = self.carView;
        self.carView = nil;
        if (gGuardView == old) gGuardView = nil;
        if (self.origSaved) {
            old.hidden = self.origHidden;
            old.alpha = self.origAlpha;
            self.origSaved = NO;
        }
    }
}

#pragma mark - 悬浮球

- (void)ensureBall {
    if (self.ballWindow && !self.ballWindow.hidden) return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kKeyBallHidden]) return;
    UIWindow *win = [self appMainWindow];
    if (!win) return;

    MGPassWindow *w = [[MGPassWindow alloc] initWithFrame:win.bounds];
    w.windowLevel = UIWindowLevelAlert + 50.0;
    w.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];

    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(win.bounds.size.width - 62.0, 150.0, 52.0, 52.0);
    ball.backgroundColor = [[UIColor colorWithRed:1.0 green:0.42 blue:0.0 alpha:1.0] colorWithAlphaComponent:0.92];
    ball.layer.cornerRadius = 26.0;
    ball.clipsToBounds = YES;
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    [ball setTitle:@"换装" forState:UIControlStateNormal];
    [ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(ballPanned:)];
    [ball addGestureRecognizer:pan];
    [vc.view addSubview:ball];

    w.rootViewController = vc;
    w.hidden = NO;
    self.ballWindow = w;
    self.ballButton = ball;
    MGLog(@"[悬浮球] 已安装 level=%.0f", w.windowLevel);
}

- (void)unhideBall { self.ballWindow.hidden = NO; }

- (void)ballPanned:(UIPanGestureRecognizer *)pan {
    UIButton *ball = self.ballButton;
    if (!ball) return;
    CGPoint t = [pan translationInView:ball.superview];
    CGRect f = ball.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    UIView *sv = ball.superview;
    if (sv) {
        f.origin.x = MAX(4.0, MIN(sv.bounds.size.width - f.size.width - 4.0, f.origin.x));
        f.origin.y = MAX(40.0, MIN(sv.bounds.size.height - f.size.height - 4.0, f.origin.y));
    }
    ball.frame = f;
    [pan setTranslation:CGPointZero inView:ball.superview];
}

- (void)alertDone:(NSString *)msg {
    UIViewController *top = [self topVC];
    if (!top) { [self unhideBall]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"MGLiveSkin"
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [self unhideBall]; }]];
    [top presentViewController:ac animated:YES completion:nil];
}

- (void)ballTapped {
    if (self.adjusting) { [self finishAdjust]; return; }
    UIViewController *top = [self topVC];
    if (!top) return;
    self.ballWindow.hidden = YES;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"MG Live 换装"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak MGManager *ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"① 框选车图区域（拖框，推荐先做）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [ws beginManualPick]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"② 替换车辆图片（相册选图）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [ws pickCarImage]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"微调位置 / 大小" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [ws beginAdjust]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"测试生效区域（橙色高亮）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [ws testHit]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复原车图" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) { [ws restoreOriginal]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"导出视图树（诊断）" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [ws dumpViewTree]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *a) { [ws unhideBall]; }]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.ballButton ?: top.view;
        ac.popoverPresentationController.sourceRect = (self.ballButton ?: top.view).bounds;
    }
    [top presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 相册选图

- (void)presentTracked:(UIViewController *)vc {
    UIViewController *top = [self topVC];
    if (!top) { [self unhideBall]; return; }
    [top presentViewController:vc animated:YES completion:nil];
}

- (void)pickCarImage {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentTracked:picker];
}

- (void)loadImageData:(PHPickerResult *)res done:(void (^)(NSData *data))done {
    NSItemProvider *provider = res.itemProvider;
    [provider loadDataRepresentationForTypeIdentifier:@"public.image"
                                    completionHandler:^(NSData *data, NSError *error) {
        if (data.length) { done(data); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [provider loadFileRepresentationForTypeIdentifier:@"public.image"
                                            completionHandler:^(NSURL *url, NSError *e2) {
                NSData *d = nil;
                if (url) {
                    [url startAccessingSecurityScopedResource];
                    d = [NSData dataWithContentsOfURL:url];   // 必须同步拷贝，URL 回调后立即失效
                    [url stopAccessingSecurityScopedResource];
                }
                done(d);
            }];
        });
    }];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    PHPickerResult *res = results.firstObject;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!res) { [self unhideBall]; return; }
        [self loadImageData:res done:^(NSData *data) {
            if (!data.length) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self alertDone:@"图片读取失败，请换一张试试"];
                });
                return;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSData *png = MGPrepareCarPNG(data);
                NSString *path = [MGDir() stringByAppendingPathComponent:@"car.png"];
                BOOL ok = png.length && [png writeToFile:path atomically:YES];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!ok) { [self alertDone:@"图片处理失败，请换一张试试"]; return; }
                    self.imageStamp = nil;
                    self.carView = nil;   // 重新识别
                    [self applyOverlays];
                    MGLog(@"[选图] 已写入 %@ (%lu bytes)", path, (unsigned long)png.length);
                    if (self.overlayView && self.overlayView.superview) {
                        NSString *vcKey = [self currentVCKey];
                        if (!CGRectIsNull([self regionNormForVC:vcKey])) {
                            [self alertDone:@"已替换（区域模式）\n位置不对可用「微调位置 / 大小」"];
                        } else {
                            UIView *car = self.carView;
                            [self alertDone:[NSString stringWithFormat:
                                @"已替换（视图模式）→ %@\nframe=%@",
                                NSStringFromClass([car class]), NSStringFromCGRect(car.frame)]];
                        }
                    } else {
                        [self alertDone:@"图片已保存，但当前页面还没有生效区域。\n"
                         "请先「① 框选车图区域」拖一个框，再选图。"];
                    }
                });
            });
        }];
    }];
}

#pragma mark - 区域框选（车图是 3D 渲染，按区域覆盖）

- (void)beginManualPick {
    UIWindow *win = [self appMainWindow];
    if (!win) { [self unhideBall]; return; }
    MGPassWindow *selWin = [[MGPassWindow alloc] initWithFrame:win.bounds];
    selWin.windowLevel = win.windowLevel + 300.0;
    selWin.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.12];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    MGSelectionView *sv = [[MGSelectionView alloc] initWithFrame:vc.view.bounds];
    UILabel *hint = [UILabel new];
    hint.text = @"按住拖出一个框，正好框住原车图";
    hint.font = [UIFont boldSystemFontOfSize:15.0];
    hint.textColor = [UIColor whiteColor];
    hint.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.frame = CGRectMake(20.0, 100.0, win.bounds.size.width - 40.0, 40.0);
    hint.layer.cornerRadius = 8.0;
    hint.clipsToBounds = YES;
    [vc.view addSubview:sv];
    [vc.view addSubview:hint];
    selWin.rootViewController = vc;
    selWin.hidden = NO;
    self.selectionWindow = selWin;
    __weak MGManager *ws = self;
    sv.pickRect = ^(CGRect r) {
        [ws closeSelection];
        CGFloat W = win.bounds.size.width, H = win.bounds.size.height;
        if (W < 1 || H < 1 || r.size.width < 30 || r.size.height < 30) {
            [ws alertDone:@"框太小了，请重新拖一个框"];
            return;
        }
        CGRect n = CGRectMake(r.origin.x / W, r.origin.y / H,
                              r.size.width / W, r.size.height / H);
        NSString *vcKey = [ws currentVCKey];
        [ws saveRegion:n forVC:vcKey];
        [ws applyOverlays];
        MGLog(@"[框选] 页面 %@ 区域 %@", vcKey, NSStringFromCGRect(r));
        if (ws.overlayView && ws.overlayView.superview) {
            [ws alertDone:[NSString stringWithFormat:
                @"已记录区域（页面 %@）\n%@\n现在选「② 替换车辆图片（相册选图）」",
                vcKey, NSStringFromCGRect(n)]];
        } else {
            [ws alertDone:[NSString stringWithFormat:
                @"已记录区域（页面 %@）\n%@\n还没选图，请选「② 替换车辆图片（相册选图）」",
                vcKey, NSStringFromCGRect(n)]];
        }
    };
}

- (void)closeSelection {
    UIWindow *w = self.selectionWindow;
    self.selectionWindow = nil;
    w.hidden = YES;
    w.rootViewController = nil;
    w.windowScene = nil;
}

// 调试：橙色高亮显示当前生效的位置（区域模式或视图模式），5 秒后消失
- (void)testHit {
    UIWindow *win = [self appMainWindow];
    UIView *root = win.rootViewController.view;
    if (!win || !root) { [self alertDone:@"没有可用窗口"]; return; }

    CGRect n = [self regionNormForVC:[self currentVCKey]];
    UIView *host = root;
    CGRect boxFrame = CGRectNull;
    NSString *desc = nil;

    if (!CGRectIsNull(n)) {
        CGSize R = root.bounds.size;
        boxFrame = CGRectMake(n.origin.x * R.width, n.origin.y * R.height,
                              n.size.width * R.width, n.size.height * R.height);
        desc = [NSString stringWithFormat:@"区域模式 %@\n（页面 %@）",
                NSStringFromCGRect(n), [self currentVCKey]];
    } else {
        self.carView = nil;
        UIView *car = [self findCarView];
        if (!car || !car.superview) {
            [self alertDone:@"当前页面还没有记录区域\n请用「① 框选车图区域」拖一个框"];
            return;
        }
        host = car.superview;
        boxFrame = [car convertRect:car.bounds toView:host];
        desc = [NSString stringWithFormat:@"视图模式 %@\nframe=%@",
                NSStringFromClass([car class]), NSStringFromCGRect(car.frame)];
    }

    UIView *box = [[UIView alloc] initWithFrame:boxFrame];
    box.backgroundColor = [[UIColor colorWithRed:1.0 green:0.42 blue:0.0 alpha:0.45] colorWithAlphaComponent:0.45];
    box.layer.borderColor = [UIColor whiteColor].CGColor;
    box.layer.borderWidth = 2.0;
    box.userInteractionEnabled = NO;
    box.tag = 9527;
    [host addSubview:box];
    [host bringSubviewToFront:box];
    MGLog(@"[测试] 高亮 %@", desc);
    __weak UIView *wbox = box;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [wbox removeFromSuperview]; });
    [self alertDone:[NSString stringWithFormat:
        @"橙色区域 = 当前生效位置\n%@\n不对就用「① 框选车图区域」重新拖框", desc]];
}

#pragma mark - 微调

- (void)beginAdjust {
    if (!self.overlayView) { [self alertDone:@"请先替换车辆图片，再微调"]; return; }
    self.ballWindow.hidden = YES;
    self.adjusting = YES;
    UIView *box = [[UIView alloc] initWithFrame:self.overlayView.frame];
    box.backgroundColor = [UIColor clearColor];
    box.layer.borderColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.0 alpha:0.9].CGColor;
    box.layer.borderWidth = 2.0;
    box.userInteractionEnabled = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(adjustPanned:)];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(adjustPinched:)];
    [box addGestureRecognizer:pan];
    [box addGestureRecognizer:pinch];
    [self.overlayView.superview addSubview:box];
    self.adjustView = box;
    [self alertDone:@"拖动移动 / 双指缩放\n完成后点悬浮球选「完成微调」"];
}

- (void)adjustPanned:(UIPanGestureRecognizer *)g {
    // 区域模式：直接改区域归一化坐标
    UIWindow *win = [self appMainWindow];
    UIView *root = win.rootViewController.view;
    CGSize R = root ? root.bounds.size : CGSizeZero;
    NSString *vcKey = [self currentVCKey];
    CGRect reg = [self regionNormForVC:vcKey];
    if (!CGRectIsNull(reg) && R.width > 1 && R.height > 1) {
        CGPoint t = [g translationInView:root];
        reg.origin.x += t.x / R.width;
        reg.origin.y += t.y / R.height;
        reg.origin.x = MAX(-0.5, MIN(1.5, reg.origin.x));
        reg.origin.y = MAX(-0.5, MIN(1.5, reg.origin.y));
        [self saveRegion:reg forVC:vcKey];
        [g setTranslation:CGPointZero inView:root];
        [self applyOverlays];
        return;
    }
    UIView *car = self.carView;
    if (!car || !car.superview) return;
    CGRect base = [car convertRect:car.bounds toView:car.superview];
    if (base.size.width < 1 || base.size.height < 1) return;
    CGPoint t = [g translationInView:car.superview];
    CGRect n = [self normRect];
    n.origin.x += t.x / base.size.width;
    n.origin.y += t.y / base.size.height;
    n.origin.x = MAX(-0.5, MIN(1.4, n.origin.x));
    n.origin.y = MAX(-0.5, MIN(1.4, n.origin.y));
    [self saveNormRect:n];
    [g setTranslation:CGPointZero inView:car.superview];
    [self applyOverlays];
}

- (void)adjustPinched:(UIPinchGestureRecognizer *)g {
    CGFloat s = g.scale;
    NSString *vcKey = [self currentVCKey];
    CGRect reg = [self regionNormForVC:vcKey];
    if (!CGRectIsNull(reg)) {
        reg.size.width = MAX(0.08, MIN(1.6, reg.size.width * s));
        reg.size.height = MAX(0.08, MIN(1.6, reg.size.height * s));
        [self saveRegion:reg forVC:vcKey];
        g.scale = 1.0;
        [self applyOverlays];
        return;
    }
    CGRect n = [self normRect];
    n.size.width = MAX(0.08, MIN(2.0, n.size.width * s));
    n.size.height = MAX(0.08, MIN(2.0, n.size.height * s));
    [self saveNormRect:n];
    g.scale = 1.0;
    [self applyOverlays];
}

- (void)finishAdjust {
    [self.adjustView removeFromSuperview];
    self.adjustView = nil;
    self.adjusting = NO;
    [self unhideBall];
    [self alertDone:@"微调已保存"];
}

#pragma mark - 恢复 / 诊断

- (void)restoreOriginal {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:kKeyCarRect];
    [ud removeObjectForKey:kKeyManualClass];
    [ud removeObjectForKey:kKeyRegionMap];
    [ud removeObjectForKey:kKeyManualMap];
    NSString *path = [MGDir() stringByAppendingPathComponent:@"car.png"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    self.carImage = nil;
    self.imageStamp = nil;
    UIView *car = self.carView;
    if (car) [self restoreCar:car];
    [self unmountOverlay];
    self.carView = nil;
    gGuardView = nil;
    MGLog(@"[恢复] 已恢复原车图（含区域配置）");
    [self unhideBall];
    [self alertDone:@"已恢复原车图"];
}

- (void)dumpViewTree {
    NSMutableString *out = [NSMutableString stringWithCapacity:8192];
    [out appendFormat:@"==== MGLiveSkin %@ viewtree %@ ====\n", MG_VERSION, [NSDate date]];
    UIViewController *vc = [self topVC];
    [out appendFormat:@"[topVC] %@ title=%@ navTitle=%@\n", NSStringFromClass([vc class]),
     vc.title ?: @"-", vc.navigationItem.title ?: @"-"];
    NSArray<UIWindow *> *wins = [self appWindows];
    [out appendFormat:@"[windows] 共 %lu 个\n", (unsigned long)wins.count];
    for (UIWindow *win in wins) {
        [out appendFormat:@"[window] %@ level=%.0f key=%d bounds=%@ root=%@\n",
         NSStringFromClass([win class]), win.windowLevel, (int)win.isKeyWindow,
         NSStringFromCGRect(win.bounds), NSStringFromClass([win.rootViewController class])];
        [self dump:win.rootViewController.view to:out depth:1];
    }
    if (!wins.count) [out appendString:@"[windows] 无可见窗口\n"];
    NSString *path = [MGDir() stringByAppendingPathComponent:@"viewtree.txt"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    MGLog(@"[诊断] 导出 %lu 字节（%lu 窗口）", (unsigned long)out.length, (unsigned long)wins.count);
    [self unhideBall];
    [self alertDone:[NSString stringWithFormat:@"已导出 %lu 个窗口的视图树：\n%@",
                     (unsigned long)wins.count, path]];
}

- (void)dump:(UIView *)view to:(NSMutableString *)out depth:(NSInteger)depth {
    if (!view || depth > 18) return;
    NSString *text = @"";
    if ([view isKindOfClass:[UILabel class]]) text = ((UILabel *)view).text ?: @"";
    UIImage *im = [view isKindOfClass:[UIImageView class]] ? ((UIImageView *)view).image : nil;
    [out appendFormat:@"%@%@ frame=%@ a=%.2f h=%d img=%@ contents=%@ text=%@ %@\n",
     [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
     NSStringFromClass([view class]),
     NSStringFromCGRect(view.frame),
     view.alpha, (int)view.hidden,
     im ? NSStringFromCGSize(im.size) : @"-",
     view.layer.contents ? @"Y" : @"-",
     text.length > 30 ? [[text substringToIndex:30] stringByAppendingString:@"..."] : text,
     view == self.overlayView ? @"<OUR-OVERLAY>" : (view == self.carView ? @"<CAR-VIEW>" : @"")];
    for (UIView *sub in [view.subviews copy]) [self dump:sub to:out depth:depth + 1];
}

@end

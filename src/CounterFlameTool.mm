//
//  CounterFlameTool.mm — CounterFlame 内部测试工具（standalone 注入 dylib）
//
//  精简重写：UIKit 暗色菜单 + 标准 il2cpp 反射 API（runtime_invoke），防御性判空。
//  arm64 / arm64e 通用 fat dylib。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <string.h>

#pragma mark - il2cpp 类型

typedef void Il2CppDomain;
typedef void Il2CppAssembly;
typedef void Il2CppImage;
typedef void Il2CppClass;
typedef void MethodInfo;
typedef void Il2CppObject;
typedef void Il2CppString;
typedef void Il2CppArray;
typedef void Il2CppType;
typedef void Il2CppThread;
typedef void Il2CppException;

struct CFT_Vec3 { float x, y, z; };
struct CFT_Vec2 { float x, y; };

#pragma mark - il2cpp 函数指针

static Il2CppDomain* (*fn_domain_get)(void);
static Il2CppThread* (*fn_thread_attach)(Il2CppDomain*);
static Il2CppImage*  (*fn_get_corlib)(void);
static const Il2CppAssembly** (*fn_domain_get_assemblies)(const Il2CppDomain*, size_t*);
static const Il2CppImage* (*fn_assembly_get_image)(const Il2CppAssembly*);
static Il2CppClass* (*fn_class_from_name)(const Il2CppImage*, const char*, const char*);
static MethodInfo*  (*fn_class_get_method_from_name)(Il2CppClass*, const char*, int);
static const char*  (*fn_class_get_name)(Il2CppClass*);
static const Il2CppType* (*fn_class_get_type)(Il2CppClass*);
static uint32_t     (*fn_class_get_num_methods)(Il2CppClass*);
static Il2CppClass*  (*fn_object_get_class)(Il2CppObject*);
static int32_t      (*fn_array_length)(Il2CppArray*);
static int          (*fn_class_is_assignable_from)(Il2CppClass*, Il2CppClass*);
static Il2CppString* (*fn_string_new)(const char*);
static void*        (*fn_resolve_icall)(const char*);
static Il2CppObject* (*fn_runtime_invoke)(const MethodInfo*, void*, void**, Il2CppException**);
static void*        (*fn_object_unbox)(Il2CppObject*);

#pragma mark - 日志

static NSString* CFTLogPath(void) {
    static NSString *p;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES).firstObject;
        p = [docs stringByAppendingPathComponent:@"counterflame_tool.log"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
            [@"--- CounterFlameTool log ---\n" writeToFile:p atomically:YES
                                                   encoding:NSUTF8StringEncoding error:nil];
        }
    });
    return p;
}

static void CFTLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[CounterFlameTool] %@", msg);
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:CFTLogPath()];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - 全局状态

static BOOL gReady = NO;
static Il2CppDomain *gDomain;
static Il2CppClass *gUnityObjectClass;
static Il2CppClass *gComponentClass;
static Il2CppClass *gTransformClass;
static Il2CppClass *gCameraClass;
static MethodInfo *gFindObjectsOfType;
static MethodInfo *gGetTransform;
static MethodInfo *gGetPosition;
static MethodInfo *gCameraGetMain;
static MethodInfo *gCameraGetPosition;
static MethodInfo *gWorldToScreenPoint;
static Il2CppObject *gMainCamera;

static NSString *gCurrentClassName = nil;
static NSString *gCurrentComment = nil;
static BOOL gShowBox = YES;
static BOOL gShowName = YES;
static BOOL gShowDistance = YES;
static BOOL gShowRay = NO;

#pragma mark - 固定类配置

@interface CFTTarget : NSObject
@property(nonatomic, copy) NSString *fullName;
@property(nonatomic, copy) NSString *comment;
@property(nonatomic, copy) NSString *ns;
@property(nonatomic, copy) NSString *cls;
@end
@implementation CFTTarget @end

static NSArray<CFTTarget*>* CFTTargets(void) {
    static NSArray *a;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        NSArray *raw = @[
            @[@"ScarletWork.Game.Audio.PlayerAudio", @"真人玩家"],
            @[@"ScarletWork.Training.ArenaBot", @"人机"],
            @[@"UnityEngine.BoxCollider", @"物品 1"],
            @[@"UnityEngine.Rigidbody", @"物品 2"]
        ];
        NSMutableArray *m = [NSMutableArray array];
        for (NSArray *r in raw) {
            NSString *full = r[0];
            NSRange dot = [full rangeOfString:@"." options:NSBackwardsSearch];
            CFTTarget *tt = [CFTTarget new];
            tt.fullName = full;
            tt.comment = r[1];
            tt.ns = dot.location != NSNotFound ? [full substringToIndex:dot.location] : @"";
            tt.cls = dot.location != NSNotFound ? [full substringFromIndex:dot.location + 1] : full;
            [m addObject:tt];
        }
        a = m;
    });
    return a;
}

#pragma mark - 反射辅助

static Il2CppObject* CFTInvoke(const MethodInfo *m, void *obj, void **params) {
    if (!m || !fn_runtime_invoke) return NULL;
    Il2CppException *exc = NULL;
    Il2CppObject *r = fn_runtime_invoke(m, obj, params, &exc);
    if (exc) CFTLog(@"invoke 异常 method=%p", m);
    return r;
}

static Il2CppClass* CFTFindUnityClass(const char *ns, const char *name) {
    if (!gDomain || !fn_domain_get_assemblies) return NULL;
    size_t count = 0;
    const Il2CppAssembly **assemblies = fn_domain_get_assemblies(gDomain, &count);
    if (!assemblies) return NULL;
    for (size_t i = 0; i < count; i++) {
        const Il2CppImage *img = fn_assembly_get_image(assemblies[i]);
        if (!img) continue;
        Il2CppClass *c = fn_class_from_name(img, ns, name);
        if (c) return c;
    }
    return NULL;
}

static Il2CppClass* CFTFindGameClass(CFTTarget *tt) {
    if (!gDomain) return NULL;
    size_t count = 0;
    const Il2CppAssembly **assemblies = fn_domain_get_assemblies(gDomain, &count);
    if (!assemblies) return NULL;
    for (size_t i = 0; i < count; i++) {
        const Il2CppImage *img = fn_assembly_get_image(assemblies[i]);
        if (!img) continue;
        Il2CppClass *c = fn_class_from_name(img, tt.ns.UTF8String, tt.cls.UTF8String);
        if (c) return c;
    }
    return NULL;
}

#pragma mark - 初始化

static void CFTResolve(void* *ptr, const char *name) {
    *ptr = dlsym(RTLD_DEFAULT, name);
    CFTLog(@"%@ %s", *ptr ? @"✓" : @"✗", name);
}

static void CFTInit(void) {
    if (gReady) return;

    CFTResolve((void**)&fn_domain_get, "il2cpp_domain_get");
    CFTResolve((void**)&fn_thread_attach, "il2cpp_thread_attach");
    CFTResolve((void**)&fn_get_corlib, "il2cpp_get_corlib");
    CFTResolve((void**)&fn_domain_get_assemblies, "il2cpp_domain_get_assemblies");
    CFTResolve((void**)&fn_assembly_get_image, "il2cpp_assembly_get_image");
    CFTResolve((void**)&fn_class_from_name, "il2cpp_class_from_name");
    CFTResolve((void**)&fn_class_get_method_from_name, "il2cpp_class_get_method_from_name");
    CFTResolve((void**)&fn_class_get_name, "il2cpp_class_get_name");
    CFTResolve((void**)&fn_class_get_type, "il2cpp_class_get_type");
    CFTResolve((void**)&fn_class_get_num_methods, "il2cpp_class_get_num_methods");
    CFTResolve((void**)&fn_object_get_class, "il2cpp_object_get_class");
    CFTResolve((void**)&fn_array_length, "il2cpp_array_length");
    CFTResolve((void**)&fn_class_is_assignable_from, "il2cpp_class_is_assignable_from");
    CFTResolve((void**)&fn_string_new, "il2cpp_string_new");
    CFTResolve((void**)&fn_resolve_icall, "il2cpp_resolve_icall");
    CFTResolve((void**)&fn_runtime_invoke, "il2cpp_runtime_invoke");
    CFTResolve((void**)&fn_object_unbox, "il2cpp_object_unbox");

    if (!fn_domain_get || !fn_thread_attach) {
        CFTLog(@"缺少核心 il2cpp 导出，终止");
        return;
    }

    gDomain = fn_domain_get();
    if (fn_thread_attach) fn_thread_attach(gDomain);
    CFTLog(@"domain=%p thread 已 attach", gDomain);

    gUnityObjectClass = CFTFindUnityClass("UnityEngine", "Object");
    gComponentClass = CFTFindUnityClass("UnityEngine", "Component");
    gTransformClass = CFTFindUnityClass("UnityEngine", "Transform");
    gCameraClass = CFTFindUnityClass("UnityEngine", "Camera");
    CFTLog(@"Object=%p Component=%p Transform=%p Camera=%p",
           gUnityObjectClass, gComponentClass, gTransformClass, gCameraClass);

    if (gUnityObjectClass) {
        gFindObjectsOfType = fn_class_get_method_from_name(gUnityObjectClass,
                                                            "FindObjectsOfType", 1);
    }
    if (gComponentClass) {
        gGetTransform = fn_class_get_method_from_name(gComponentClass, "get_transform", 0);
    }
    if (gTransformClass) {
        gGetPosition = fn_class_get_method_from_name(gTransformClass, "get_position", 0);
    }
    if (gCameraClass) {
        gCameraGetMain = fn_class_get_method_from_name(gCameraClass, "get_main", 0);
        gCameraGetPosition = fn_class_get_method_from_name(gCameraClass, "get_position", 0);
        gWorldToScreenPoint = fn_class_get_method_from_name(gCameraClass,
                                                            "WorldToScreenPoint", 1);
    }

    CFTLog(@"方法 Find=%p trans=%p pos=%p camMain=%p w2s=%p",
           gFindObjectsOfType, gGetTransform, gGetPosition, gCameraGetMain, gWorldToScreenPoint);

    gReady = (gDomain != NULL);
    CFTLog(@"初始化完成 ready=%d", gReady);
}

#pragma mark - 摄像机

static void CFTGetCamera(void) {
    if (!gReady || !gCameraGetMain) {
        CFTLog(@"获取摄像机：条件不足");
        return;
    }
    gMainCamera = CFTInvoke(gCameraGetMain, NULL, NULL);
    CFTLog(@"获取摄像机：%@", gMainCamera ? @"成功" : @"失败");
}

#pragma mark - ESP 元素

@interface CFTItem : NSObject
@property(nonatomic) CGPoint point;
@property(nonatomic) BOOL valid;
@property(nonatomic, copy) NSString *label;
@property(nonatomic) double distance;
@end
@implementation CFTItem @end

static NSArray<CFTItem*>* CFTBuildItems(Il2CppClass *targetClass, CFTTarget *tt) {
    NSMutableArray *items = [NSMutableArray array];
    if (!gReady || !targetClass || !gFindObjectsOfType) return items;

    const Il2CppType *type = fn_class_get_type ? fn_class_get_type(targetClass) : NULL;
    void *typeArg = (void*)type;
    Il2CppObject *arrObj = CFTInvoke(gFindObjectsOfType, NULL, &typeArg);
    if (!arrObj) {
        CFTLog(@"FindObjectsOfType 返回空");
        return items;
    }
    Il2CppArray *arr = (Il2CppArray*)arrObj;
    int32_t n = fn_array_length ? fn_array_length(arr) : 0;
    CFTLog(@"扫描 %@ 命中 %d 个", tt.fullName, n);

    CFTGetCamera();
    Il2CppObject *cam = gMainCamera;

    struct CFT_Vec3 camPos = {0,0,0};
    if (cam && gCameraGetPosition && fn_object_unbox) {
        Il2CppObject *box = CFTInvoke(gCameraGetPosition, cam, NULL);
        if (box) {
            struct CFT_Vec3 *p = (struct CFT_Vec3*)fn_object_unbox(box);
            if (p) camPos = *p;
        }
    }

    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat screenH = UIScreen.mainScreen.bounds.size.height;
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;

    for (int32_t i = 0; i < n; i++) {
        Il2CppObject *elem = ((Il2CppObject**)arr)[i];
        if (!elem) continue;

        Il2CppObject *transform = NULL;
        struct CFT_Vec3 wpos = {0,0,0};

        if (gGetTransform) transform = CFTInvoke(gGetTransform, elem, NULL);
        if (transform && gGetPosition && fn_object_unbox) {
            Il2CppObject *pb = CFTInvoke(gGetPosition, transform, NULL);
            if (pb) {
                struct CFT_Vec3 *p = (struct CFT_Vec3*)fn_object_unbox(pb);
                if (p) wpos = *p;
            }
        }

        float dx = wpos.x - camPos.x;
        float dy = wpos.y - camPos.y;
        float dz = wpos.z - camPos.z;
        double dist = sqrt(dx*dx + dy*dy + dz*dz);

        CGPoint pt = CGPointZero;
        BOOL valid = NO;
        if (cam && gWorldToScreenPoint && fn_object_unbox) {
            struct CFT_Vec3 arg = wpos;
            void *argp = &arg;
            Il2CppObject *sb = CFTInvoke(gWorldToScreenPoint, cam, &argp);
            if (sb) {
                // WorldToScreenPoint 返回 Vector3（z 为距离），取前两个 float
                struct CFT_Vec3 *sp = (struct CFT_Vec3*)fn_object_unbox(sb);
                if (sp) {
                    CGFloat px = sp->x / scale;
                    CGFloat py = (screenH * scale - sp->y) / scale;
                    if (px >= 0 && px <= screenW && py >= 0 && py <= screenH) {
                        pt = CGPointMake(px, py);
                        valid = YES;
                    }
                }
            }
        }

        CFTItem *item = [CFTItem new];
        item.point = pt;
        item.valid = valid;
        item.distance = dist;
        item.label = [NSString stringWithFormat:@"%@", tt.comment];
        [items addObject:item];
    }
    return items;
}

#pragma mark - ESP 覆盖视图

@class CFTOverlayView;
static UIWindow *gOverlayWindow;
static CFTOverlayView *gOverlayView;

@interface CFTOverlayView : UIView
@property(nonatomic, strong) NSArray<CFTItem*> *items;
@end

@implementation CFTOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        _items = @[];
    }
    return self;
}

- (void)setItems:(NSArray<CFTItem*>*)items {
    _items = [items copy];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    UIColor *accent = [UIColor colorWithRed:1.0 green:0.45 blue:0.05 alpha:1.0];

    for (CFTItem *it in self.items) {
        if (!it.valid) continue;
        CGPoint p = it.point;

        CGFloat boxW = 64, boxH = 84;
        CGRect box = CGRectMake(p.x - boxW/2, p.y - boxH/2, boxW, boxH);

        if (gShowBox) {
            CGContextSetStrokeColorWithColor(ctx, accent.CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeRect(ctx, box);
        }

        if (gShowRay) {
            CGContextSetStrokeColorWithColor(ctx, accent.CGColor);
            CGContextSetLineWidth(ctx, 1.0);
            CGContextMoveToPoint(ctx, self.bounds.size.width/2, self.bounds.size.height);
            CGContextAddLineToPoint(ctx, p.x, p.y);
            CGContextStrokePath(ctx);
        }

        NSString *name = gShowName ? it.label : @"";
        NSString *dist = gShowDistance ? [NSString stringWithFormat:@"%.0fm", it.distance] : @"";
        NSString *top = name.length ? [NSString stringWithFormat:@"%@ %@", name, dist] : dist;
        if (top.length) {
            NSDictionary *attr = @{
                NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightMedium],
                NSForegroundColorAttributeName: accent
            };
            CGSize sz = [top sizeWithAttributes:attr];
            [top drawAtPoint:CGPointMake(p.x - sz.width/2, box.origin.y - 14)
              withAttributes:attr];
        }
    }
}

@end

static void CFTSetupOverlay(void) {
    if (gOverlayWindow) return;
    gOverlayWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    gOverlayWindow.windowLevel = UIWindowLevelStatusBar + 300;
    gOverlayWindow.userInteractionEnabled = NO;
    gOverlayView = [[CFTOverlayView alloc] initWithFrame:gOverlayWindow.bounds];
    gOverlayWindow.rootViewController = [UIViewController new];
    [gOverlayWindow.rootViewController.view addSubview:gOverlayView];
    gOverlayWindow.hidden = NO;
}

#pragma mark - 扫描定时

static NSTimer *gScanTimer;

static void CFTRefreshScan(void) {
    if (!gReady || !gCurrentClassName) return;
    CFTTarget *tt = nil;
    for (CFTTarget *t in CFTTargets()) {
        if ([t.fullName isEqualToString:gCurrentClassName]) { tt = t; break; }
    }
    if (!tt) return;

    Il2CppClass *cls = CFTFindGameClass(tt);
    if (!cls) {
        CFTLog(@"未找到类 %@", tt.fullName);
        return;
    }
    NSArray<CFTItem*> *items = CFTBuildItems(cls, tt);
    dispatch_async(dispatch_get_main_queue(), ^{
        CFTSetupOverlay();
        gOverlayView.items = items;
    });
}

static void CFTSelectTarget(CFTTarget *tt) {
    CFTInit();
    CFTGetCamera();
    gCurrentClassName = tt.fullName;
    gCurrentComment = tt.comment;
    CFTLog(@"选择类 %@（%@），重新获取摄像机", tt.fullName, tt.comment);

    if (!gScanTimer) {
        gScanTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES
                                                        block:^(NSTimer *t) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                CFTRefreshScan();
            });
        }];
    }
    CFTRefreshScan();
}

#pragma mark - 菜单 / 悬浮按钮

@class CFTController;
static UIWindow *gBtnWindow;
static UIView *gBtn;
static CFTController *gController;
static void CFTMenuShow(void);

@interface CFTController : NSObject
- (void)onTap;
- (void)onPan:(UIPanGestureRecognizer*)gr;
@end
@implementation CFTController

- (void)onTap {
    CFTMenuShow();
}

- (void)onPan:(UIPanGestureRecognizer*)gr {
    UIWindow *win = gBtnWindow;
    if (!win) return;
    const CGFloat half = 28;
    CGPoint t = [gr translationInView:win];
    CGPoint c = win.center;
    c.x += t.x; c.y += t.y;
    CGRect sb = win.screen.bounds;
    c.x = MAX(half, MIN(sb.size.width - half, c.x));
    c.y = MAX(half, MIN(sb.size.height - half, c.y));
    win.center = c;
    [gr setTranslation:CGPointZero inView:win];
}
@end

static void CFTMenuShow(void) {
    CFTInit();
    UIViewController *top = NULL;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.hidden) continue;
        UIViewController *vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (vc) { top = vc; break; }
    }
    if (!top) return;

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"CounterFlame 内部测试"
        message:gCurrentClassName ? [NSString stringWithFormat:@"当前：%@", gCurrentComment] : nil
        preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"获取摄像机"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
            CFTInit(); CFTGetCamera();
        });
    }]];

    for (CFTTarget *tt in CFTTargets()) {
        NSString *title = [NSString stringWithFormat:@"%@（%@）", tt.fullName, tt.comment];
        [sheet addAction:[UIAlertAction actionWithTitle:title
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
                CFTSelectTarget(tt);
            });
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:
        [NSString stringWithFormat:@"显示方框：%@", gShowBox ? @"开" : @"关"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        gShowBox = !gShowBox;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:
        [NSString stringWithFormat:@"显示名字：%@", gShowName ? @"开" : @"关"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        gShowName = !gShowName;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:
        [NSString stringWithFormat:@"显示距离：%@", gShowDistance ? @"开" : @"关"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        gShowDistance = !gShowDistance;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:
        [NSString stringWithFormat:@"显示射线：%@", gShowRay ? @"开" : @"关"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        gShowRay = !gShowRay;
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭"
        style:UIAlertActionStyleCancel handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = gBtn;
        sheet.popoverPresentationController.sourceRect = gBtn.bounds;
    }
    [top presentViewController:sheet animated:YES completion:nil];
}

static void CFTSetupButton(void) {
    if (gBtnWindow) return;
    gBtnWindow = [[UIWindow alloc] initWithFrame:CGRectMake(30, 280, 56, 56)];
    gBtnWindow.windowLevel = UIWindowLevelStatusBar + 400;
    gBtnWindow.backgroundColor = UIColor.clearColor;

    gBtn = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    gBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.12 alpha:0.9];
    gBtn.layer.cornerRadius = 28;
    gBtn.layer.borderWidth = 1;
    gBtn.layer.borderColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.05 alpha:1].CGColor;

    UILabel *lab = [[UILabel alloc] initWithFrame:gBtn.bounds];
    lab.text = @"CF";
    lab.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.05 alpha:1];
    lab.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    lab.textAlignment = NSTextAlignmentCenter;
    [gBtn addSubview:lab];

    gController = [CFTController new];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:gController
                                                                          action:@selector(onTap)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gController
                                                                          action:@selector(onPan:)];
    [gBtn addGestureRecognizer:tap];
    [gBtn addGestureRecognizer:pan];

    UIViewController *vc = [UIViewController new];
    vc.view = gBtn;
    gBtnWindow.rootViewController = vc;
    gBtnWindow.hidden = NO;
}

#pragma mark - 加载入口

__attribute__((constructor)) static void CFT_ctor(void) {
    @autoreleasepool {
        NSString *bid = [NSBundle.mainBundle bundleIdentifier];
        CFTLog(@"✅ constructor bid=%@", bid);
        dispatch_async(dispatch_get_main_queue(), ^{
            CFTSetupButton();
        });
        // 后台预解析，不弹窗、不阻塞
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            CFTInit();
        });
    }
}

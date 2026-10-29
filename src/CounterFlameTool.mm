//
//  CounterFlameTool.mm — CounterFlame 内部测试工具（standalone 注入 dylib）
//
//  v2：安卓 libtool 风格实色面板（无液态玻璃）；修复触控穿透、选类闪退；
//  选类自动获取类/对象/摄像机；绘制总开关默认关。
//  v3：悬浮窗触摸修复——整块面板作为触摸接收区，空白区域拦截触摸不穿透到游戏；
//  面板任意区域可拖动，不再局限于小圆点/标题栏。
//  v4：触摸穿透根因修复——窗口绑定活跃 UIWindowScene（未绑定 scene 的窗口触摸
//  投递不稳定，是穿透的根因）；触摸窗口整块命中+兜底拦截；ESP 绘制窗口改为
//  纯渲染窗口彻底不拦触摸；面板窗口层级高于悬浮球；拖动只从空白区开始，
//  控件上的触摸不触发拖动、点击不受影响。
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
static void*        (*fn_array_addr_with_size)(Il2CppArray*, uint32_t, uint32_t);
static int          (*fn_class_is_assignable_from)(Il2CppClass*, Il2CppClass*);
static Il2CppString* (*fn_string_new)(const char*);
static void*        (*fn_resolve_icall)(const char*);
static Il2CppObject* (*fn_runtime_invoke)(const MethodInfo*, void*, void**, Il2CppException**);
static void*        (*fn_object_unbox)(Il2CppObject*);
static Il2CppObject* (*fn_type_get_object)(const Il2CppType*);

#pragma mark - 颜色（实色，无透明毛玻璃）

static UIColor* CFTHex(unsigned int rgb, CGFloat a) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF)/255.0
                           green:((rgb >> 8) & 0xFF)/255.0
                            blue:(rgb & 0xFF)/255.0 alpha:a];
}
#define kCFTBg      CFTHex(0x0E1013, 0.98)   // 面板底
#define kCFTBar     CFTHex(0x171A1F, 1.0)    // 标题栏
#define kCFTLine    CFTHex(0x2B3038, 1.0)    // 边框/分隔
#define kCFTBtn     CFTHex(0x1A1E23, 1.0)    // 按钮底
#define kCFTBtnHi   CFTHex(0x23282F, 1.0)    // 按钮按下
#define kCFTText    CFTHex(0xE6E8EB, 1.0)    // 主文字
#define kCFTSUB     CFTHex(0x8A9099, 1.0)    // 次文字
#define kCFTAccent  CFTHex(0xFF720F, 1.0)    // 品牌橙
#define kCFTOff     CFTHex(0x262B33, 1.0)    // 开关关底

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

#pragma mark - 全局状态（绘制默认全关）

static BOOL gReady = NO;
static Il2CppDomain *gDomain;
static Il2CppClass *gUnityObjectClass;
static Il2CppClass *gComponentClass;
static Il2CppClass *gTransformClass;
static Il2CppClass *gCameraClass;
static MethodInfo *gFindObjectsOfType;
static MethodInfo *gFindObjectsByType;
static MethodInfo *gTypeGetTypeFromHandle;
static MethodInfo *gGetTransform;
static MethodInfo *gGetPosition;
static MethodInfo *gCameraGetMain;
static MethodInfo *gCameraGetPosition;
static MethodInfo *gWorldToScreenPoint;
static Il2CppObject *gMainCamera;

static NSString *gCurrentClassName = nil;
static NSString *gCurrentComment = nil;
static BOOL gDrawEnabled = NO;   // 绘制总开关，默认关
static BOOL gShowBox = NO;
static BOOL gShowName = NO;
static BOOL gShowDistance = NO;
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
    static NSArray<CFTTarget*> *a;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        NSArray *raw = @[
            @[@"ScarletWork.Game.Audio.PlayerAudio", @"真人玩家"],
            @[@"ScarletWork.Training.ArenaBot", @"人机"],
            @[@"UnityEngine.BoxCollider", @"物品 1"],
            @[@"UnityEngine.Rigidbody", @"物品 2"]
        ];
        NSMutableArray<CFTTarget*> *m = [NSMutableArray array];
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

static void CFTAttach(void) {
    if (fn_thread_attach && gDomain) fn_thread_attach(gDomain);
}

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

// Il2CppType* -> C# System.Type 对象（FindObjectsOfType 需要的是对象，不是裸元数据指针）
static Il2CppObject* CFTTypeObject(const Il2CppType *t) {
    if (!t) return NULL;
    if (fn_type_get_object) return fn_type_get_object(t);
    if (gTypeGetTypeFromHandle) {
        // 兜底：Type.GetTypeFromHandle(RuntimeTypeHandle)，handle 内部值即 Il2CppType*
        void *handle = (void*)t;
        return CFTInvoke(gTypeGetTypeFromHandle, NULL, &handle);
    }
    return NULL;
}

// 安全取数组元素：il2cpp 数组头部 32 字节，不能直接把数组指针当数据区
static Il2CppObject* CFTArrayElem(Il2CppArray *arr, int32_t idx) {
    if (!arr) return NULL;
    if (fn_array_addr_with_size) {
        void **slot = (void**)fn_array_addr_with_size(arr, (uint32_t)sizeof(void*),
                                                      (uint32_t)idx);
        return slot ? *slot : NULL;
    }
    return ((Il2CppObject**)((char*)arr + 0x20))[idx];
}

#pragma mark - 初始化

static void CFTResolve(void* *ptr, const char *name) {
    *ptr = dlsym(RTLD_DEFAULT, name);
    CFTLog(@"%@ %s", *ptr ? @"✓" : @"✗", name);
}

static void CFTInit(void) {
    if (gReady) return;
    CFTAttach();

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
    CFTResolve((void**)&fn_array_addr_with_size, "il2cpp_array_addr_with_size");
    CFTResolve((void**)&fn_class_is_assignable_from, "il2cpp_class_is_assignable_from");
    CFTResolve((void**)&fn_string_new, "il2cpp_string_new");
    CFTResolve((void**)&fn_resolve_icall, "il2cpp_resolve_icall");
    CFTResolve((void**)&fn_runtime_invoke, "il2cpp_runtime_invoke");
    CFTResolve((void**)&fn_object_unbox, "il2cpp_object_unbox");
    CFTResolve((void**)&fn_type_get_object, "il2cpp_type_get_object");

    if (!fn_domain_get || !fn_thread_attach) {
        CFTLog(@"缺少核心 il2cpp 导出，终止");
        return;
    }

    gDomain = fn_domain_get();
    CFTAttach();
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
        gFindObjectsByType = fn_class_get_method_from_name(gUnityObjectClass,
                                                            "FindObjectsByType", 2);
    }
    Il2CppClass *sysType = CFTFindUnityClass("System", "Type");
    if (sysType) {
        gTypeGetTypeFromHandle = fn_class_get_method_from_name(sysType,
                                                               "GetTypeFromHandle", 1);
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

    CFTLog(@"方法 Find=%p FindByType=%p trans=%p pos=%p camMain=%p w2s=%p typeObj=%p",
           gFindObjectsOfType, gFindObjectsByType, gGetTransform, gGetPosition,
           gCameraGetMain, gWorldToScreenPoint, fn_type_get_object);

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
    if (!gReady || !targetClass) return items;

    const Il2CppType *type = fn_class_get_type ? fn_class_get_type(targetClass) : NULL;
    Il2CppObject *typeObj = CFTTypeObject(type);
    if (!typeObj) {
        CFTLog(@"无法取得 System.Type 对象，放弃本次扫描");
        return items;
    }

    Il2CppObject *arrObj = NULL;
    if (gFindObjectsOfType) {
        void *p0 = typeObj;
        arrObj = CFTInvoke(gFindObjectsOfType, NULL, &p0);
    } else if (gFindObjectsByType) {
        // 新 Unity：FindObjectsByType(Type, FindObjectsSortMode)，sortMode=None(0)
        void *p0 = typeObj;
        int32_t mode = 0;
        void *params[2] = { &p0, &mode };
        arrObj = CFTInvoke(gFindObjectsByType, NULL, params);
    } else {
        CFTLog(@"无可用的对象查找方法");
        return items;
    }
    if (!arrObj) {
        CFTLog(@"对象查找返回空");
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
        Il2CppObject *elem = CFTArrayElem(arr, i);
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

#pragma mark - 窗口构造（scene 感知，保证触摸投递稳定）

// iOS 13+ scene 应用：window 必须挂到活跃的 UIWindowScene，否则虽然能显示，
// 触摸投递会不稳定（表现为只有个别控件能点、其他区域穿透到游戏）。
static UIWindowScene* CFTActiveWindowScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback && ws.activationState != UISceneActivationStateUnattached) fallback = ws;
    }
    return fallback;
}

// 触摸接收窗口：整个窗口矩形都是命中区，命中后交给内部视图；
// 内部没有子视图命中时回落到 panel 本身，绝不让事件漏给下层窗口（游戏）。
@interface CFTTouchWindow : UIWindow
@end

@implementation CFTTouchWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(self.bounds, point);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isUserInteractionEnabled || self.isHidden || self.alpha <= 0.01) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit) return hit;
    if (CGRectContainsPoint(self.bounds, point)) {
        return self.rootViewController.view ?: self;
    }
    return nil;
}

@end

// 纯绘制窗口：完全不参与触摸，命中直接返回 nil，事件穿透给下面的窗口。
@interface CFTPaintOnlyWindow : UIWindow
@end

@implementation CFTPaintOnlyWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

@end

static UIWindow* CFTMakeTouchWindow(CGRect frame, UIWindowLevel level) {
    UIWindow *w = nil;
    UIWindowScene *ws = CFTActiveWindowScene();
    if (ws) w = [[CFTTouchWindow alloc] initWithWindowScene:ws];
    if (!w) w = [[CFTTouchWindow alloc] initWithFrame:frame];
    w.frame = frame;
    w.windowLevel = level;
    w.backgroundColor = UIColor.clearColor;
    w.userInteractionEnabled = YES;
    w.hidden = YES;   // 由调用方在挂好 rootViewController 之后再显示
    CFTLog(@"建立触摸窗口 frame=%@ level=%.0f scene=%@",
           NSStringFromCGRect(frame), (double)level, ws ? @"已绑定" : @"无(scene 回退)");
    return w;
}

#pragma mark - ESP 覆盖视图（纯绘制，不接收触摸）

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
    if (!gDrawEnabled) return;   // 总开关关：什么都不画
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    UIColor *accent = kCFTAccent;

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
    gOverlayWindow = [[CFTPaintOnlyWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    gOverlayWindow.windowLevel = UIWindowLevelStatusBar + 300;
    gOverlayWindow.userInteractionEnabled = NO;
    gOverlayView = [[CFTOverlayView alloc] initWithFrame:gOverlayWindow.bounds];
    gOverlayWindow.rootViewController = [UIViewController new];
    [gOverlayWindow.rootViewController.view addSubview:gOverlayView];
    gOverlayWindow.hidden = !gDrawEnabled;
}

#pragma mark - 扫描定时

static NSTimer *gScanTimer;

static void CFTRefreshScan(void) {
    if (!gReady || !gDrawEnabled || !gCurrentClassName) return;
    CFTTarget *tt = nil;
    for (CFTTarget *t in CFTTargets()) {
        if ([t.fullName isEqualToString:gCurrentClassName]) { tt = t; break; }
    }
    if (!tt) return;

    Il2CppClass *cls = CFTFindGameClass(tt);   // 每轮重新获取类
    if (!cls) {
        CFTLog(@"未找到类 %@", tt.fullName);
        return;
    }
    NSArray<CFTItem*> *items = CFTBuildItems(cls, tt);
    dispatch_async(dispatch_get_main_queue(), ^{
        CFTSetupOverlay();
        gOverlayWindow.hidden = NO;
        gOverlayView.items = items;
    });
}

static void CFTSelectTarget(CFTTarget *tt) {
    CFTAttach();
    CFTInit();
    CFTGetCamera();                              // 点类名同时自动重新获取摄像机
    gCurrentClassName = tt.fullName;
    gCurrentComment = tt.comment;

    Il2CppClass *cls = CFTFindGameClass(tt);     // 自动获取类与对象校验
    CFTLog(@"选择类 %@（%@）类=%@ 摄像机=%p",
           tt.fullName, tt.comment, cls ? @"已获取" : @"未找到", gMainCamera);

    if (!gScanTimer) {
        gScanTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES
                                                        block:^(NSTimer *t) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                CFTAttach();                     // GCD 线程每次必须 attach
                CFTRefreshScan();
            });
        }];
    }
    CFTRefreshScan();
}

#pragma mark - 矩形开关（安卓风格，非系统 UISwitch）

@interface CFTSwitch : UIControl
@property(nonatomic, assign, getter=isOn) BOOL on;
@property(nonatomic, copy) void (^changed)(BOOL on);
@property(nonatomic, strong) UIView *knob;
@end

@implementation CFTSwitch

@synthesize on = _on;
@synthesize changed = _changed;
@synthesize knob = _knob;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 3;
        self.backgroundColor = kCFTOff;
        CGFloat k = frame.size.height - 4;
        _knob = [[UIView alloc] initWithFrame:CGRectMake(2, 2, k, k)];
        _knob.backgroundColor = kCFTText;
        _knob.layer.cornerRadius = 2;
        [self addSubview:_knob];
        [self addTarget:self action:@selector(didTap)
                       forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)applyVisual:(BOOL)animated {
    void (^b)(void) = ^{
        self.backgroundColor = self.on ? kCFTAccent : kCFTOff;
        CGFloat k = self.frame.size.height - 4;
        self.knob.frame = CGRectMake(self.on ? self.frame.size.width - k - 2 : 2,
                                     2, k, k);
    };
    if (animated) [UIView animateWithDuration:0.12 animations:b]; else b();
}

- (void)setOn:(BOOL)on {
    _on = on;
    [self applyVisual:NO];
}

- (void)didTap {
    _on = !_on;
    [self applyVisual:YES];
    if (self.changed) self.changed(_on);
}

@end

#pragma mark - 触摸接收面板（整块拦截，防止穿透到游戏）

@interface CFTPanelView : UIView
@end

@implementation CFTPanelView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return YES;   // 整个面板区域（含空白/内边距）都算命中，一律不穿透
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit) return hit;          // 子控件（按钮/开关）优先
    return self;                  // 空白区域由面板自己接下，不交给下层窗口
}

// 兜底：空白处的触摸被面板吞掉（不做任何事），确保不会落到游戏视图上。
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}

@end

#pragma mark - 菜单面板（独立窗口，整块可触控）

static UIWindow *gMenuWindow;
static UIView *gPanel;
static NSMutableArray<UIButton*> *gClassButtons;
static CFTSwitch *gSwDraw;
static CFTSwitch *gSwBox;
static CFTSwitch *gSwName;
static CFTSwitch *gSwDist;
static CFTSwitch *gSwRay;

@interface CFTMenuController : NSObject <UIGestureRecognizerDelegate>
- (void)onMenuPan:(UIPanGestureRecognizer*)gr;
- (void)onMinimize;
@end
@implementation CFTMenuController

// 拖动只从“非控件区域”开始：点在按钮/开关上时让控件自己处理，点击不会被拖动吃掉。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v && v != gPanel) {
        if ([v isKindOfClass:[UIControl class]]) return NO;
        v = v.superview;
    }
    return YES;
}

- (void)onMenuPan:(UIPanGestureRecognizer*)gr {
    UIWindow *win = gMenuWindow;
    if (!win) return;
    CGPoint t = [gr translationInView:win];
    CGPoint c = win.center;
    c.x += t.x; c.y += t.y;
    CGRect sb = win.screen.bounds;
    CGRect f = win.frame;
    c.x = MAX(f.size.width/2, MIN(sb.size.width - f.size.width/2, c.x));
    c.y = MAX(f.size.height/2, MIN(sb.size.height - f.size.height/2, c.y));
    win.center = c;
    [gr setTranslation:CGPointZero inView:win];
}

- (void)onMinimize {
    gMenuWindow.hidden = YES;
}

@end
static CFTMenuController *gMenuController;

static UILabel* CFTMakeLabel(CGRect frame, NSString *text, UIColor *color,
                             UIFontWeight w, CGFloat size) {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.textColor = color;
    l.font = [UIFont systemFontOfSize:size weight:w];
    return l;
}

static UIButton* CFTMakeRectButton(CGRect frame, NSString *title) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    b.layer.cornerRadius = 3;
    b.layer.borderWidth = 1;
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:kCFTText forState:UIControlStateNormal];
    b.backgroundColor = kCFTBtn;
    b.layer.borderColor = kCFTLine.CGColor;
    b.adjustsImageWhenHighlighted = NO;
    b.showsTouchWhenHighlighted = NO;
    return b;
}

static void CFTUpdateClassButtonStyles(void) {
    NSArray<CFTTarget*> *targets = CFTTargets();
    for (NSUInteger i = 0; i < gClassButtons.count; i++) {
        UIButton *b = gClassButtons[i];
        CFTTarget *t = (CFTTarget*)targets[i];
        BOOL sel = [t.fullName isEqualToString:gCurrentClassName];
        b.layer.borderColor = (sel ? kCFTAccent : kCFTLine).CGColor;
        [b setTitleColor:(sel ? kCFTAccent : kCFTText) forState:UIControlStateNormal];
        b.backgroundColor = sel ? CFTHex(0xFF720F, 0.14) : kCFTBtn;
    }
}

static void CFTUpdateSubSwitches(void) {
    NSArray *sub = @[gSwBox, gSwName, gSwDist, gSwRay];
    for (CFTSwitch *s in sub) {
        s.enabled = gDrawEnabled;
        s.alpha = gDrawEnabled ? 1.0 : 0.35;
    }
}

static void CFTMenuBuild(void) {
    if (gMenuWindow) return;

    const CGFloat W = 285, H = 446;
    CGRect defaultFrame = CGRectMake(35, 90, W, H);

    // 面板窗口层级高于悬浮球窗口，避免面板被小球窗口压住
    gMenuWindow = CFTMakeTouchWindow(defaultFrame, UIWindowLevelStatusBar + 450);
    gMenuWindow.exclusiveTouch = YES;

    gPanel = [[CFTPanelView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    gPanel.backgroundColor = kCFTBg;
    gPanel.layer.cornerRadius = 6;
    gPanel.layer.borderWidth = 1;
    gPanel.layer.borderColor = kCFTLine.CGColor;
    gPanel.clipsToBounds = YES;

    // 标题栏（含最小化按钮）
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 36)];
    bar.backgroundColor = kCFTBar;
    UILabel *title = CFTMakeLabel(CGRectMake(12, 0, 200, 36),
                                  @"CounterFlame", kCFTAccent,
                                  UIFontWeightBold, 13);
    [bar addSubview:title];

    UIButton *min = [UIButton buttonWithType:UIButtonTypeCustom];
    min.frame = CGRectMake(W - 44, 0, 44, 36);
    [min setTitle:@"—" forState:UIControlStateNormal];
    [min setTitleColor:kCFTSUB forState:UIControlStateNormal];
    min.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    gMenuController = [CFTMenuController new];
    [min addTarget:gMenuController action:@selector(onMinimize)
                 forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:min];

    [gPanel addSubview:bar];

    // 整块面板可拖动（标题栏不再单独挂手势，避免拖动量叠加）
    UIPanGestureRecognizer *mp = [[UIPanGestureRecognizer alloc]
        initWithTarget:gMenuController action:@selector(onMenuPan:)];
    mp.cancelsTouchesInView = NO;   // 不取消按钮/开关的点击
    mp.delaysTouchesBegan = NO;
    mp.maximumNumberOfTouches = 1;
    mp.delegate = gMenuController;  // 控件上的触摸不触发拖动
    [gPanel addGestureRecognizer:mp];

    // 分组：目标类
    [gPanel addSubview:CFTMakeLabel(CGRectMake(12, 44, 200, 12),
                                    @"目标类（点击自动获取）", kCFTSUB,
                                    UIFontWeightRegular, 11)];

    gClassButtons = [NSMutableArray array];
    NSArray *targets = CFTTargets();
    for (NSUInteger i = 0; i < targets.count; i++) {
        CFTTarget *tt = targets[i];
        CGFloat y = 60 + i * 40;
        UIButton *b = CFTMakeRectButton(CGRectMake(12, y, W - 24, 34),
                                        [NSString stringWithFormat:@"%@  ·  %@",
                                                 tt.comment, tt.cls]);
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
        [b addTarget:b action:@selector(cft_classTapped:)
                forControlEvents:UIControlEventTouchUpInside];
        b.tag = (NSInteger)i;
        [gPanel addSubview:b];
        [gClassButtons addObject:b];
    }

    // 摄像机
    UIButton *camBtn = CFTMakeRectButton(CGRectMake(12, 220, W - 24, 32),
                                         @"重新获取摄像机");
    [camBtn addTarget:camBtn action:@selector(cft_cameraTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:camBtn];

    // 分隔
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(12, 260, W - 24, 1)];
    sep.backgroundColor = kCFTLine;
    [gPanel addSubview:sep];

    [gPanel addSubview:CFTMakeLabel(CGRectMake(12, 268, 100, 12),
                                    @"绘制", kCFTSUB,
                                    UIFontWeightRegular, 11)];

    // 开关行
    NSArray *rows = @[
        @[@"绘制总开关", @"draw"],
        @[@"方框", @"box"],
        @[@"名字", @"name"],
        @[@"距离", @"dist"],
        @[@"射线", @"ray"]
    ];
    NSMutableArray *sws = [NSMutableArray array];
    for (NSUInteger i = 0; i < rows.count; i++) {
        CGFloat y = 286 + i * 30;
        [gPanel addSubview:CFTMakeLabel(CGRectMake(12, y, 160, 24),
                                        rows[i][0], kCFTText,
                                        UIFontWeightRegular, 12)];
        CFTSwitch *sw = [[CFTSwitch alloc] initWithFrame:CGRectMake(W - 12 - 46,
                                                                    y + 3, 46, 24)];
        [gPanel addSubview:sw];
        [sws addObject:sw];
    }
    gSwDraw = sws[0]; gSwBox = sws[1]; gSwName = sws[2];
    gSwDist = sws[3]; gSwRay = sws[4];

    gSwDraw.on = gDrawEnabled;
    gSwBox.on = gShowBox; gSwName.on = gShowName;
    gSwDist.on = gShowDistance; gSwRay.on = gShowRay;

    gSwDraw.changed = ^(BOOL on) {
        gDrawEnabled = on;
        CFTSetupOverlay();
        gOverlayWindow.hidden = !on;
        if (!on) {
            gOverlayView.items = @[];
        } else {
            [gOverlayView setNeedsDisplay];
        }
        CFTUpdateSubSwitches();
    };
    gSwBox.changed = ^(BOOL on) {
        gShowBox = on; [gOverlayView setNeedsDisplay];
    };
    gSwName.changed = ^(BOOL on) {
        gShowName = on; [gOverlayView setNeedsDisplay];
    };
    gSwDist.changed = ^(BOOL on) {
        gShowDistance = on; [gOverlayView setNeedsDisplay];
    };
    gSwRay.changed = ^(BOOL on) {
        gShowRay = on; [gOverlayView setNeedsDisplay];
    };

    CFTUpdateSubSwitches();
    CFTUpdateClassButtonStyles();

    UIViewController *vc = [UIViewController new];
    vc.view = gPanel;
    gMenuWindow.rootViewController = vc;
    gMenuWindow.hidden = YES;   // 挂好根控制器后再由 CFTMenuShow 显示
    CFTLog(@"菜单面板构建完成 size=%@ 面板可交互=%@",
           NSStringFromCGSize(gPanel.frame.size), gPanel.isUserInteractionEnabled ? @"是" : @"否");
}

// 按钮事件（挂到 UIButton 上，需在类层级可见）
@interface UIButton (CFTHandlers)
- (void)cft_classTapped:(UIButton*)sender;
- (void)cft_cameraTapped;
@end
@implementation UIButton (CFTHandlers)
- (void)cft_classTapped:(UIButton*)sender {
    NSArray *targets = CFTTargets();
    if ((NSUInteger)sender.tag >= targets.count) return;
    CFTTarget *tt = targets[sender.tag];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CFTAttach();
        CFTSelectTarget(tt);
        dispatch_async(dispatch_get_main_queue(), ^{
            CFTUpdateClassButtonStyles();
        });
    });
}
- (void)cft_cameraTapped {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CFTAttach();
        CFTInit();
        CFTGetCamera();
    });
}
@end

static void CFTMenuShow(void) {
    CFTMenuBuild();
    // 若 frame 超出屏幕（拖动过/旋转），回到默认位置
    CGRect f = gMenuWindow.frame;
    CGRect sb = UIScreen.mainScreen.bounds;
    if (f.origin.x < 0 || f.origin.y < 0 ||
        CGRectGetMaxX(f) > sb.size.width || CGRectGetMaxY(f) > sb.size.height) {
        gMenuWindow.frame = CGRectMake(35, 90, f.size.width, f.size.height);
    }
    CFTUpdateClassButtonStyles();
    CFTUpdateSubSwitches();
    gMenuWindow.hidden = NO;
    CFTLog(@"菜单显示 frame=%@ level=%.0f",
           NSStringFromCGRect(gMenuWindow.frame), (double)gMenuWindow.windowLevel);
}

#pragma mark - 悬浮按钮

static UIWindow *gBtnWindow;
static UIView *gBtn;

@interface CFTController : NSObject
- (void)onTap;
- (void)onPan:(UIPanGestureRecognizer*)gr;
@end
@implementation CFTController

- (void)onTap {
    if (gMenuWindow && !gMenuWindow.hidden) {
        gMenuWindow.hidden = YES;
    } else {
        CFTMenuShow();
    }
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

static void CFTSetupButton(void) {
    if (gBtnWindow) return;
    gBtnWindow = CFTMakeTouchWindow(CGRectMake(30, 280, 56, 56), UIWindowLevelStatusBar + 400);
    gBtnWindow.exclusiveTouch = YES;

    gBtn = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    gBtn.backgroundColor = CFTHex(0x121417, 0.95);
    gBtn.layer.cornerRadius = 28;
    gBtn.layer.borderWidth = 1;
    gBtn.layer.borderColor = kCFTAccent.CGColor;

    UILabel *lab = [[UILabel alloc] initWithFrame:gBtn.bounds];
    lab.text = @"CF";
    lab.textColor = kCFTAccent;
    lab.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    lab.textAlignment = NSTextAlignmentCenter;
    [gBtn addSubview:lab];

    CFTController *ctl = [CFTController new];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:ctl
                                                                          action:@selector(onTap)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:ctl
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
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            CFTAttach();
            CFTInit();
        });
    }
}

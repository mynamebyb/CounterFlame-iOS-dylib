#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <string.h>
#import <os/lock.h>

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

#pragma mark - 颜色（实色；主题蓝色）

static UIColor* CFTHex(unsigned int rgb, CGFloat a) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF)/255.0
                           green:((rgb >> 8) & 0xFF)/255.0
                            blue:(rgb & 0xFF)/255.0 alpha:a];
}
#define kCFTBg      CFTHex(0x0E1013, 0.98)
#define kCFTBar     CFTHex(0x171A1F, 1.0)
#define kCFTLine    CFTHex(0x2B3038, 1.0)
#define kCFTBtn     CFTHex(0x1A1E23, 1.0)
#define kCFTBtnHi   CFTHex(0x23282F, 1.0)
#define kCFTText    CFTHex(0xE6E8EB, 1.0)
#define kCFTSUB     CFTHex(0x8A9099, 1.0)
#define kCFTAccent  CFTHex(0x3B9DFF, 1.0)   // ▼ 主题蓝
#define kCFTOff     CFTHex(0x262B33, 1.0)

#pragma mark - 日志（仅控制台，不写文件）

static void CFTLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[CounterFlameTool] %@", msg);
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
static BOOL gDrawEnabled = NO;
static BOOL gShowBox = NO;
static BOOL gShowName = NO;
static BOOL gShowDistBar = NO;   // ▼ 距离由数值文字改为色管
static BOOL gShowRay = NO;
static os_unfair_lock gScanLock = OS_UNFAIR_LOCK_INIT;
static BOOL gScanInProgress = NO;

// ▼ 修复性能/断触/闪退：所有 il2cpp invoke 只在一条专用串行队列上执行。
//   旧版闪退根因是把扫描抛到 GCD 并发队列——多线程无 attach / 并发访问 GC 直接崩；
//   上一版改回主线程又导致扫描同步阻塞渲染与触摸（卡、断触）。
//   串行队列保证：同一时刻只有一个 invoke 在跑，每次执行前 thread_attach（幂等）。
static dispatch_queue_t gScanQueue = NULL;
// ▼ 渲染与扫描解耦：CADisplayLink 以屏幕刷新率重绘，数据来自最近一次扫描结果
static CADisplayLink *gDisplayLink;
// 屏幕参数缓存（仅主线程写入，扫描线程只读），避免在非主线程访问 UIScreen
static CGFloat gScreenScale = 2.0, gScreenW = 0, gScreenH = 0;

static inline BOOL CFTIsMainThread(void) {
    return [NSThread isMainThread];
}

#pragma mark - CFTSwitch 接口前向声明

@interface CFTSwitch : UIControl
@property(nonatomic, assign, getter=isOn) BOOL on;
@property(nonatomic, copy) void (^changed)(BOOL on);
@property(nonatomic, strong) UIView *knob;
@end

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

// ▼ 人物判定：非 UnityEngine.* 的游戏逻辑类都是挂在角色上的人物组件，
//   其 Transform 位于脚底原点；UnityEngine.*（BoxCollider/Rigidbody）为物品，坐标正常。
static BOOL CFTIsHumanTarget(CFTTarget *tt) {
    return ![tt.fullName hasPrefix:@"UnityEngine."];
}

// 人物抬升（世界单位）：脚底→身体中部，远处框顶约到头顶，近处覆盖身体
static const float kCFTHumanLift = 0.9f;

#pragma mark - 反射辅助

static void CFTAttach(void) {
    if (fn_thread_attach && gDomain) fn_thread_attach(gDomain);
}

static Il2CppObject* CFTInvoke(const MethodInfo *m, void *obj, void **params) {
    if (!m || !fn_runtime_invoke) return NULL;
    Il2CppException *exc = NULL;
    Il2CppObject *r = fn_runtime_invoke(m, obj, params, &exc);
    if (exc) {
        Il2CppClass *ec = fn_object_get_class ? fn_object_get_class((Il2CppObject*)exc) : NULL;
        const char *ename = (ec && fn_class_get_name) ? fn_class_get_name(ec) : "Unknown";
        CFTLog(@"invoke 异常 method=%p 类名=%s", m, ename ? ename : "Unknown");
    }
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

static Il2CppObject* CFTTypeObject(const Il2CppType *t) {
    if (!t) return NULL;
    if (fn_type_get_object) return fn_type_get_object(t);
    if (gTypeGetTypeFromHandle) {
        void *handle = (void*)t;
        return CFTInvoke(gTypeGetTypeFromHandle, NULL, &handle);
    }
    return NULL;
}

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

    gReady = (gDomain != NULL);
    CFTLog(@"初始化完成 ready=%d", gReady);
}

#pragma mark - 摄像机（仅在扫描队列线程调用）

static void CFTGetCamera(void) {
    if (!gReady || !gCameraGetMain) return;
    gMainCamera = CFTInvoke(gCameraGetMain, NULL, NULL);
}

#pragma mark - ESP 元素

@interface CFTItem : NSObject
@property(nonatomic) CGPoint point;
@property(nonatomic) BOOL valid;
@property(nonatomic, copy) NSString *label;
@property(nonatomic) double distance;
@end
@implementation CFTItem @end

static NSArray<CFTItem*>* CFTBuildItems(Il2CppClass *targetClass, CFTTarget *tt, NSInteger index) {
    NSMutableArray *items = [NSMutableArray array];
    if (!gReady || !targetClass) return items;

    const Il2CppType *type = fn_class_get_type ? fn_class_get_type(targetClass) : NULL;
    Il2CppObject *typeObj = CFTTypeObject(type);
    if (!typeObj) return items;

    Il2CppObject *arrObj = NULL;
    if (gFindObjectsOfType) {
        void *p0 = typeObj;
        arrObj = CFTInvoke(gFindObjectsOfType, NULL, &p0);
    } else if (gFindObjectsByType) {
        void *p0 = typeObj;
        int32_t mode = 0;
        void *params[2] = { &p0, &mode };
        arrObj = CFTInvoke(gFindObjectsByType, NULL, params);
    }
    if (!arrObj) return items;

    Il2CppArray *arr = (Il2CppArray*)arrObj;
    int32_t n = fn_array_length ? fn_array_length(arr) : 0;

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

    CGFloat scale = gScreenScale;
    CGFloat screenH = gScreenH;
    CGFloat screenW = gScreenW;
    BOOL human = CFTIsHumanTarget(tt);

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
        // ▼ 人物 Transform 在脚底，世界坐标抬高半身高，投影随距离自然缩放
        if (human) wpos.y += kCFTHumanLift;

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
                    // ▼ 修复背向误绘：z<=0 表示目标在摄像机背后，
                    //   其 x/y 投影会镜像到屏幕另一侧（180° 方向），必须丢弃
                    if (sp->z > 0.0f) {
                        CGFloat px = sp->x / scale;
                        CGFloat py = (screenH * scale - sp->y) / scale;
                        if (px >= 0 && px <= screenW && py >= 0 && py <= screenH) {
                            pt = CGPointMake(px, py);
                            valid = YES;
                        }
                    }
                }
            }
        }

        CFTItem *item = [CFTItem new];
        item.point = pt;
        item.valid = valid;
        item.distance = dist;
        if (human) {
            item.label = [NSString stringWithFormat:@"%@ #%ld", tt.comment, (long)(index + 1)];
        } else {
            item.label = @"物品";
        }
        [items addObject:item];
    }
    return items;
}

#pragma mark - 窗口构造（scene 感知）

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

@interface CFTTouchWindow : UIWindow
@end

@implementation CFTTouchWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(self.bounds, point);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isUserInteractionEnabled || self.isHidden) return nil;
    if (!CGRectContainsPoint(self.bounds, point)) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit) return hit;
    return self.rootViewController.view;
}

@end

@interface CFTPaintOnlyWindow : UIWindow
@end

@implementation CFTPaintOnlyWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;   // 绘制层永不吞触摸
}

@end

@interface CFTBallWindow : UIWindow
@end

@implementation CFTBallWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (!CGRectContainsPoint(self.bounds, point)) return NO;
    CGFloat cx = self.bounds.size.width / 2.0;
    CGFloat cy = self.bounds.size.height / 2.0;
    return hypot(point.x - cx, point.y - cy) <= 30.0;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.isUserInteractionEnabled || self.isHidden) return nil;
    if (![self pointInside:point withEvent:event]) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    return hit;
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
    w.hidden = NO;
    return w;
}

// ▼ 主线程缓存屏幕参数，扫描线程只读，避免跨线程访问 UIScreen
static void CFTCacheScreen(void) {
    UIScreen *s = UIScreen.mainScreen;
    gScreenScale = s.scale;
    gScreenW = s.bounds.size.width;
    gScreenH = s.bounds.size.height;
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
}

// 距离色管配色：t=0 最远→绿，0.5 中→黄，1 最近→红
static UIColor* CFTColorForNorm(CGFloat t) {
    CGFloat r, g;
    if (t < 0.5) { r = t * 2.0; g = 1.0; }
    else         { r = 1.0; g = 1.0 - (t - 0.5) * 2.0; }
    return [UIColor colorWithRed:r green:g blue:0.12 alpha:1.0];
}

- (void)drawRect:(CGRect)rect {
    if (!gDrawEnabled) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    UIColor *accent = kCFTAccent;

    // ▼ 本帧内归一化距离，色管随位置变化持续更新
    CGFloat minD = CGFLOAT_MAX, maxD = -CGFLOAT_MAX;
    if (gShowDistBar) {
        for (CFTItem *it in self.items) {
            if (!it.valid) continue;
            if (it.distance < minD) minD = it.distance;
            if (it.distance > maxD) maxD = it.distance;
        }
    }
    BOOL hasRange = (maxD - minD) > 1.0;

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

        if (gShowName) {
            NSDictionary *attr = @{
                NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightMedium],
                NSForegroundColorAttributeName: accent
            };
            NSString *top = it.label ?: @"";
            if (top.length) {
                CGSize sz = [top sizeWithAttributes:attr];
                [top drawAtPoint:CGPointMake(p.x - sz.width/2, box.origin.y - 14)
                  withAttributes:attr];
            }
        }

        // ▼ 色管：物体正下方，绿(远)→黄(中)→红(近)
        if (gShowDistBar) {
            CGFloat t = hasRange ? (CGFloat)((it.distance - minD) / (maxD - minD)) : 0.0;
            UIColor *bar = CFTColorForNorm(t);
            CGFloat barW = 40, barH = 5;
            CGRect tube = CGRectMake(p.x - barW/2, box.origin.y + boxH + 4, barW, barH);
            CGContextSetFillColorWithColor(ctx, bar.CGColor);
            CGContextFillRect(ctx, tube);
            CGContextSetStrokeColorWithColor(ctx, kCFTLine.CGColor);
            CGContextSetLineWidth(ctx, 0.5);
            CGContextStrokeRect(ctx, tube);
        }
    }
}

@end

static void CFTSetupOverlay(void) {
    if (gOverlayWindow) return;
    CFTCacheScreen();
    UIWindowScene *ws = CFTActiveWindowScene();
    if (ws) {
        gOverlayWindow = [[CFTPaintOnlyWindow alloc] initWithWindowScene:ws];
    } else {
        gOverlayWindow = [[CFTPaintOnlyWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    gOverlayWindow.frame = UIScreen.mainScreen.bounds;
    gOverlayWindow.windowLevel = UIWindowLevelStatusBar + 300;
    gOverlayWindow.userInteractionEnabled = NO;
    gOverlayView = [[CFTOverlayView alloc] initWithFrame:gOverlayWindow.bounds];
    gOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gOverlayWindow.rootViewController = [UIViewController new];
    [gOverlayWindow.rootViewController.view addSubview:gOverlayView];
    gOverlayWindow.hidden = !gDrawEnabled;
}

#pragma mark - 渲染循环（与扫描解耦）

// CADisplayLink 的 target 需要 selector，用轻量 NSObject 包一层转发。
@interface CFTRenderPump : NSObject {
@public
    void (^_tick)(void);
}
- (void)tick;
@end
@implementation CFTRenderPump
- (void)tick { if (_tick) _tick(); }
@end
static CFTRenderPump *gPump;

#pragma mark - 扫描调度（串行队列 + kick 模型）

static CFTSwitch *gSwDraw;
static void CFTUpdateSubSwitches(void);
static void CFTCleanupDrawState(void);

// 从扫描队列发起一轮：构建原生结果后回主线程更新视图。
// 绝不把托管对象指针跨线程保存——只传 CGPoint/double/NSString。
static void CFTKickScan(CFTTarget *tt) {
    dispatch_async(gScanQueue, ^{
        // ▼ 修复"点绘制没效果"：dylib 加载通常早于 Unity 运行时启动，
        //   构造器里的首次 CFTInit 会失败（gReady=NO）。旧版靠点击类名时
        //   重试 init 兜底；上一版重写把它删了，导致永不重试。
        //   现在每轮扫描都先重试 CFTInit（幂等：已就绪立即返回）。
        CFTInit();
        CFTAttach();   // 幂等：确保本线程已挂到 il2cpp
        if (!gReady) {
            dispatch_async(dispatch_get_main_queue(), ^{
                os_unfair_lock_lock(&gScanLock);
                gScanInProgress = NO;
                os_unfair_lock_unlock(&gScanLock);
            });
            return;
        }
        Il2CppClass *cls = CFTFindGameClass(tt);
        NSArray<CFTItem*> *items = nil;
        if (cls) {
            NSUInteger idx = 0;
            for (CFTTarget *t in CFTTargets()) {
                if ([t.fullName isEqualToString:tt.fullName]) break;
                idx++;
            }
            items = CFTBuildItems(cls, tt, (NSInteger)idx);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            os_unfair_lock_lock(&gScanLock);
            BOOL stillEnabled = gDrawEnabled;
            BOOL sameClass = (gCurrentClassName && [gCurrentClassName isEqualToString:tt.fullName]);
            gScanInProgress = NO;
            os_unfair_lock_unlock(&gScanLock);
            if (!stillEnabled || !sameClass) return;
            CFTSetupOverlay();
            if (!gOverlayWindow || !gOverlayView) return;
            gOverlayWindow.hidden = NO;
            gOverlayView.items = items ?: @[];
        });
    });
}

static void CFTRefreshScan(void) {
    os_unfair_lock_lock(&gScanLock);
    // ▼ 不再因 !gReady 直接跳过：发起扫描让扫描队列有机会重试初始化
    if (!gDrawEnabled || !gCurrentClassName || gScanInProgress) {
        os_unfair_lock_unlock(&gScanLock);
        return;
    }
    gScanInProgress = YES;
    CFTTarget *tt = nil;
    for (CFTTarget *t in CFTTargets()) {
        if ([t.fullName isEqualToString:gCurrentClassName]) { tt = t; break; }
    }
    if (!tt) {
        gScanInProgress = NO;
        os_unfair_lock_unlock(&gScanLock);
        return;
    }
    os_unfair_lock_unlock(&gScanLock);
    CFTKickScan(tt);
}

static NSTimer *gScanTimer;

static void CFTStopScanTimer(void) {
    if (!CFTIsMainThread()) { dispatch_async(dispatch_get_main_queue(), ^{ CFTStopScanTimer(); }); return; }
    os_unfair_lock_lock(&gScanLock);
    NSTimer *tmr = gScanTimer;
    gScanTimer = nil;
    os_unfair_lock_unlock(&gScanLock);
    if (tmr) [tmr invalidate];
}

static void CFTStartScanTimer(void) {
    if (!CFTIsMainThread()) { dispatch_async(dispatch_get_main_queue(), ^{ CFTStartScanTimer(); }); return; }
    os_unfair_lock_lock(&gScanLock);
    if (gScanTimer) {
        os_unfair_lock_unlock(&gScanLock);
        return;
    }
    BOOL drawOn = gDrawEnabled;
    NSString *curCls = [gCurrentClassName copy];
    os_unfair_lock_unlock(&gScanLock);
    if (!drawOn || !curCls.length) return;
    // timer 只负责在主线程"踢一脚"，重活全部在扫描队列，不阻塞渲染/触摸。
    // 用 timerWithTimeInterval + commonModes：游戏运行中主 runloop 常年处于
    // UITrackingRunLoopMode，default 模式的 timer 会被挂起（卡顿诱因之一）；
    // 且 scheduledTimer 后再手动 addTimer 会重复注册、双倍触发。
    gScanTimer = [NSTimer timerWithTimeInterval:(1.0/30.0) repeats:YES
                                         block:^(NSTimer *t) {
        CFTRefreshScan();
    }];
    [NSRunLoop.mainRunLoop addTimer:gScanTimer forMode:NSRunLoopCommonModes];
}

static void CFTStartPump(void) {
    if (!CFTIsMainThread()) { dispatch_async(dispatch_get_main_queue(), ^{ CFTStartPump(); }); return; }
    if (gDisplayLink) return;
    if (!gPump) {
        gPump = [CFTRenderPump new];
        gPump->_tick = ^{ if (gDrawEnabled && gOverlayView) [gOverlayView setNeedsDisplay]; };
    }
    gDisplayLink = [CADisplayLink displayLinkWithTarget:gPump selector:@selector(tick)];
    [gDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

static void CFTStopPump(void) {
    if (!CFTIsMainThread()) { dispatch_async(dispatch_get_main_queue(), ^{ CFTStopPump(); }); return; }
    if (gDisplayLink) {
        [gDisplayLink invalidate];
        gDisplayLink = nil;
    }
    if (gOverlayView) gOverlayView.items = @[];
    if (gOverlayWindow) gOverlayWindow.hidden = YES;
}

static void CFTCleanupDrawState(void) {
    if (!CFTIsMainThread()) { dispatch_async(dispatch_get_main_queue(), ^{ CFTCleanupDrawState(); }); return; }
    CFTStopScanTimer();
    CFTStopPump();
    os_unfair_lock_lock(&gScanLock);
    gDrawEnabled = NO;
    gScanInProgress = NO;
    os_unfair_lock_unlock(&gScanLock);
    if (gSwDraw) gSwDraw.on = NO;
    CFTUpdateSubSwitches();
    CFTLog(@"绘制状态已清理");
}

static void CFTSelectTarget(CFTTarget *tt) {
    os_unfair_lock_lock(&gScanLock);
    gDrawEnabled = NO;
    gScanInProgress = NO;
    gCurrentClassName = [tt.fullName copy];
    gCurrentComment = [tt.comment copy];
    os_unfair_lock_unlock(&gScanLock);
    CFTLog(@"选择类 %@（%@）", tt.fullName, tt.comment);
}

#pragma mark - 矩形开关

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

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect hit = CGRectInset(self.bounds, -10, -10);
    return CGRectContainsPoint(hit, point);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CGPoint local = [self convertPoint:point toView:self];
    if (![self pointInside:local withEvent:event]) return nil;
    return self;
}

@end

#pragma mark - 触摸接收面板

@interface CFTPanelView : UIView
@end

@implementation CFTPanelView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!CGRectContainsPoint(self.bounds, point)) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit) return hit;
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}

@end

#pragma mark - 菜单面板

static UIWindow *gMenuWindow;
static UIView *gPanel;
static NSMutableArray<UIButton*> *gClassButtons;
static CFTSwitch *gSwBox;
static CFTSwitch *gSwName;
static CFTSwitch *gSwDist;
static CFTSwitch *gSwRay;

@interface CFTMenuController : NSObject <UIGestureRecognizerDelegate>
- (void)onMenuPan:(UIPanGestureRecognizer*)gr;
- (void)onMinimize;
@end
@implementation CFTMenuController

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
    CFTCleanupDrawState();
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
        b.backgroundColor = sel ? CFTHex(0x3B9DFF, 0.14) : kCFTBtn;   // ▼ 蓝色选中态
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

    CGFloat screenH = UIScreen.mainScreen.bounds.size.height;
    const CGFloat H = MIN(400.0, MAX(320.0, screenH - 160.0));
    const CGFloat W = 285, scrollH = H - 36;
    const CGFloat contentH = 360;
    CGRect defaultFrame = CGRectMake(35, MAX(20.0, (screenH - H) / 2.0), W, H);

    gMenuWindow = CFTMakeTouchWindow(defaultFrame, UIWindowLevelStatusBar + 450);
    gMenuWindow.exclusiveTouch = YES;
    gMenuWindow.hidden = YES;

    gPanel = [[CFTPanelView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    gPanel.backgroundColor = kCFTBg;
    gPanel.layer.cornerRadius = 6;
    gPanel.layer.borderWidth = 1;
    gPanel.layer.borderColor = kCFTLine.CGColor;
    gPanel.clipsToBounds = YES;

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

    UIPanGestureRecognizer *mp = [[UIPanGestureRecognizer alloc]
        initWithTarget:gMenuController action:@selector(onMenuPan:)];
    mp.cancelsTouchesInView = NO;
    mp.delaysTouchesBegan = NO;
    mp.maximumNumberOfTouches = 1;
    [bar addGestureRecognizer:mp];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 36, W, scrollH)];
    scroll.backgroundColor = kCFTBg;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.bounces = NO;
    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, contentH)];
    content.backgroundColor = kCFTBg;
    scroll.contentSize = content.bounds.size;
    [scroll addSubview:content];
    [gPanel addSubview:scroll];

    [content addSubview:CFTMakeLabel(CGRectMake(12, 8, 200, 12),
                                     @"目标类（点击自动获取）", kCFTSUB,
                                     UIFontWeightRegular, 11)];

    gClassButtons = [NSMutableArray array];
    NSArray *targets = CFTTargets();
    for (NSUInteger i = 0; i < targets.count; i++) {
        CFTTarget *tt = targets[i];
        CGFloat y = 20 + i * 36;
        UIButton *b = CFTMakeRectButton(CGRectMake(12, y, W - 24, 34),
                                        [NSString stringWithFormat:@"%@  ·  %@",
                                                 tt.comment, tt.cls]);
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
        [b addTarget:b action:@selector(cft_classTapped:)
                forControlEvents:UIControlEventTouchUpInside];
        b.tag = (NSInteger)i;
        [content addSubview:b];
        [gClassButtons addObject:b];
    }

    // ▼ 已按要求删除"重新获取摄像机"按钮

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(12, 168, W - 24, 1)];
    sep.backgroundColor = kCFTLine;
    [content addSubview:sep];

    [content addSubview:CFTMakeLabel(CGRectMake(12, 176, 100, 12),
                                     @"绘制", kCFTSUB,
                                     UIFontWeightRegular, 11)];

    NSArray *rows = @[
        @[@"绘制总开关", @"draw"],
        @[@"方框", @"box"],
        @[@"名字", @"name"],
        @[@"距离色管", @"dist"],
        @[@"射线", @"ray"]
    ];
    NSMutableArray *sws = [NSMutableArray array];
    for (NSUInteger i = 0; i < rows.count; i++) {
        CGFloat y = 194 + i * 28;
        [content addSubview:CFTMakeLabel(CGRectMake(12, y, 160, 24),
                                         rows[i][0], kCFTText,
                                         UIFontWeightRegular, 12)];
        CFTSwitch *sw = [[CFTSwitch alloc] initWithFrame:CGRectMake(W - 12 - 46,
                                                                    y + 3, 46, 24)];
        [content addSubview:sw];
        [sws addObject:sw];
    }
    gSwDraw = sws[0]; gSwBox = sws[1]; gSwName = sws[2];
    gSwDist = sws[3]; gSwRay = sws[4];

    gSwDraw.on = gDrawEnabled;
    gSwBox.on = gShowBox; gSwName.on = gShowName;
    gSwDist.on = gShowDistBar; gSwRay.on = gShowRay;

    gSwDraw.changed = ^(BOOL on) {
        if (on) {
            os_unfair_lock_lock(&gScanLock);
            BOOL hasClass = gCurrentClassName.length > 0;
            gDrawEnabled = hasClass;
            os_unfair_lock_unlock(&gScanLock);
            if (!hasClass) {
                CFTLog(@"绘制总开关已开，但未选择目标类");
                gSwDraw.on = NO;
                CFTUpdateSubSwitches();
                return;
            }
            CFTSetupOverlay();
            if (gOverlayWindow) gOverlayWindow.hidden = NO;
            CFTStartPump();
            CFTRefreshScan();
            CFTStartScanTimer();
        } else {
            CFTCleanupDrawState();
        }
        CFTUpdateSubSwitches();
        CFTLog(@"绘制总开关 → %@", on ? @"开" : @"关");
    };
    gSwBox.changed = ^(BOOL on) {
        gShowBox = on;
        if (gOverlayView) [gOverlayView setNeedsDisplay];
    };
    gSwName.changed = ^(BOOL on) {
        gShowName = on;
        if (gOverlayView) [gOverlayView setNeedsDisplay];
    };
    gSwDist.changed = ^(BOOL on) {
        gShowDistBar = on;
        if (gOverlayView) [gOverlayView setNeedsDisplay];
    };
    gSwRay.changed = ^(BOOL on) {
        gShowRay = on;
        if (gOverlayView) [gOverlayView setNeedsDisplay];
    };

    CFTUpdateSubSwitches();
    CFTUpdateClassButtonStyles();

    UIViewController *vc = [UIViewController new];
    vc.view = gPanel;
    gMenuWindow.rootViewController = vc;
}

#pragma mark - 按钮处理

@interface UIButton (CFTHandlers)
- (void)cft_classTapped:(UIButton*)sender;
@end
@implementation UIButton (CFTHandlers)
- (void)cft_classTapped:(UIButton*)sender {
    NSArray<CFTTarget*> *targets = CFTTargets();
    if ((NSUInteger)sender.tag >= targets.count) return;
    CFTTarget *tt = (CFTTarget*)targets[sender.tag];
    CFTCleanupDrawState();
    CFTSelectTarget(tt);
    CFTUpdateClassButtonStyles();
}
@end

#pragma mark - 菜单显隐

static void CFTMenuShow(void) {
    CFTMenuBuild();

    CGRect f = gMenuWindow.frame;
    CGRect sb = UIScreen.mainScreen.bounds;
    if (f.origin.x < 0 || f.origin.y < 0 ||
        CGRectGetMaxX(f) > sb.size.width || CGRectGetMaxY(f) > sb.size.height) {
        gMenuWindow.frame = CGRectMake(35, 90, f.size.width, f.size.height);
    }
    CFTUpdateClassButtonStyles();
    CFTUpdateSubSwitches();
    gMenuWindow.hidden = NO;
}

#pragma mark - 悬浮按钮（蓝色主题）

static UIWindow *gBtnWindow;
static UIView *gBtn;

@interface CFTController : NSObject
- (void)onTap;
- (void)onPan:(UIPanGestureRecognizer*)gr;
@end
static CFTController *gBtnCtl;
@implementation CFTController

- (void)onTap {
    if (gMenuWindow && !gMenuWindow.hidden) {
        gMenuWindow.hidden = YES;
    } else {
        CFTMenuShow();
    }
}

- (void)onPan:(UIPanGestureRecognizer*)gr {
    if (!gBtnWindow) return;
    CGFloat tx = [gr translationInView:gBtnWindow].x;
    CGFloat ty = [gr translationInView:gBtnWindow].y;
    CGRect wf = gBtnWindow.frame;
    wf.origin.x += tx;
    wf.origin.y += ty;
    CGRect sb = gBtnWindow.screen.bounds;
    wf.origin.x = MAX(0, MIN(wf.origin.x, sb.size.width  - wf.size.width));
    wf.origin.y = MAX(0, MIN(wf.origin.y, sb.size.height - wf.size.height));
    gBtnWindow.frame = wf;
    [gr setTranslation:CGPointZero inView:gBtnWindow];
}
@end

static void CFTSetupButton(void) {
    if (gBtnWindow) return;

    UIWindowScene *ws = CFTActiveWindowScene();
    if (!ws) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CFTSetupButton();
        });
        return;
    }

    CGSize sb = UIScreen.mainScreen.bounds.size;
    CGRect winFrame = CGRectMake(30, MAX(120, sb.height * 0.35), 56, 56);

    gBtnWindow = [[CFTBallWindow alloc] initWithWindowScene:ws];
    gBtnWindow.frame = winFrame;
    gBtnWindow.windowLevel = UIWindowLevelAlert + 100;
    gBtnWindow.backgroundColor = UIColor.clearColor;
    gBtnWindow.userInteractionEnabled = YES;
    gBtnWindow.hidden = NO;

    gBtn = [[UIView alloc] initWithFrame:gBtnWindow.bounds];
    gBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gBtn.backgroundColor = CFTHex(0x121417, 0.95);
    gBtn.layer.cornerRadius = 28;
    gBtn.layer.borderWidth = 1;
    gBtn.layer.borderColor = kCFTAccent.CGColor;   // ▼ 蓝色描边

    UILabel *lab = [[UILabel alloc] initWithFrame:gBtn.bounds];
    lab.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lab.userInteractionEnabled = NO;
    lab.text = @"CF";
    lab.textColor = kCFTAccent;                    // ▼ 蓝色文字
    lab.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    lab.textAlignment = NSTextAlignmentCenter;
    [gBtn addSubview:lab];

    gBtnCtl = [CFTController new];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:gBtnCtl
                                                                          action:@selector(onTap)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gBtnCtl
                                                                          action:@selector(onPan:)];
    tap.cancelsTouchesInView = NO;
    pan.cancelsTouchesInView = NO;
    [gBtn addGestureRecognizer:tap];
    [gBtn addGestureRecognizer:pan];

    UIViewController *vc = [UIViewController new];
    vc.view = gBtn;
    gBtnWindow.rootViewController = vc;
    gBtn.frame = gBtnWindow.bounds;
}

#pragma mark - 加载入口

__attribute__((constructor)) static void CFT_ctor(void) {
    @autoreleasepool {
        gScanQueue = dispatch_queue_create("com.counterflame.scan", DISPATCH_QUEUE_SERIAL);
        dispatch_async(dispatch_get_main_queue(), ^{
            CFTCacheScreen();
            CFTSetupButton();
        });
        dispatch_async(gScanQueue, ^{
            CFTInit();
        });
    }
}

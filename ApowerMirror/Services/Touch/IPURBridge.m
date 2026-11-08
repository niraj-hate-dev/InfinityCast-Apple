//
//  IPURBridge.m
//  InfinityCast
//
//  Dynamic touch event synthesis bridge using XCTest runtime.
//

#import "IPURBridge.h"
#import "IPURGeometry.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef id (*IPURMsgSendInitRecordDisplay)(id, SEL, NSString *, unsigned long long, long long);
typedef id (*IPURMsgSendInitRecordOrientation)(id, SEL, NSString *, long long);
typedef void (*IPURMsgSendSetLongLong)(id, SEL, long long);
typedef id (*IPURMsgSendInitPath)(id, SEL, CGPoint, double);
typedef void (*IPURMsgSendPathMove)(id, SEL, CGPoint, double);
typedef void (*IPURMsgSendPathOffset)(id, SEL, double);
typedef void (*IPURMsgSendAddPath)(id, SEL, id);
typedef BOOL (*IPURMsgSendSynthesize)(id, SEL, NSError **);

@implementation IPURBridge

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *paths = @[
            @"/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
            @"/Developer/Library/Frameworks/XCTest.framework/XCTest",
            @"/Library/Developer/Frameworks/XCTest.framework/XCTest",
            @"/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/Frameworks/XCTest.framework/XCTest"
        ];
        for (NSString *path in paths) {
            void *handle = dlopen([path UTF8String], RTLD_NOW | RTLD_GLOBAL);
            if (handle) {
                NSLog(@"[InfinityCast] Successfully loaded XCTest from: %@", path);
                break;
            }
        }
    });
}

+ (BOOL)eventSynthesisAvailable {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    return recordClass != Nil && pathClass != Nil
        && [recordClass instancesRespondToSelector:NSSelectorFromString(@"synthesizeWithError:")]
        && [recordClass instancesRespondToSelector:NSSelectorFromString(@"addPointerEventPath:")]
        && [pathClass instancesRespondToSelector:NSSelectorFromString(@"initForTouchAtPoint:offset:")]
        && [pathClass instancesRespondToSelector:NSSelectorFromString(@"moveToPoint:atOffset:")]
        && [pathClass instancesRespondToSelector:NSSelectorFromString(@"liftUpAtOffset:")];
}

static CGSize IPURScreenBounds(void) {
    UIScreen *screen = [UIScreen mainScreen];
    return screen.bounds.size;
}

static long long IPURCurrentOrientation(void) {
    UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                orientation = [(UIWindowScene *)scene interfaceOrientation];
                break;
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        orientation = UIApplication.sharedApplication.statusBarOrientation;
#pragma clang diagnostic pop
    }
    return (orientation >= 1 && orientation <= 4) ? (long long)orientation : 1;
}

static CGPoint IPURConvertTouchPoint(CGPoint point) {
    return IPURPortraitPoint(point, IPURCurrentOrientation(), IPURScreenBounds());
}

static NSString *IPURCreateGestureRecord(NSString *name, int pid, id *record) {
    if (![IPURBridge eventSynthesisAvailable]) {
        return @"private XCTest event synthesis unavailable (XCSynthesizedEventRecord / XCPointerEventPath)";
    }
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    SEL displaySelector = NSSelectorFromString(@"initWithName:displayID:interfaceOrientation:");
    SEL orientationSelector = NSSelectorFromString(@"initWithName:interfaceOrientation:");
    
    long long orientation = 1;
    id created = nil;
    if ([recordClass instancesRespondToSelector:displaySelector]) {
        created = ((IPURMsgSendInitRecordDisplay)objc_msgSend)(
            [recordClass alloc], displaySelector, name, 0ULL, orientation);
    } else if ([recordClass instancesRespondToSelector:orientationSelector]) {
        created = ((IPURMsgSendInitRecordOrientation)objc_msgSend)(
            [recordClass alloc], orientationSelector, name, orientation);
    }
    
    if (created == nil) {
        return @"could not initialize XCSynthesizedEventRecord";
    }
    
    if (pid > 0) {
        SEL targetSelector = NSSelectorFromString(@"setTargetProcessID:");
        if ([created respondsToSelector:targetSelector]) {
            ((IPURMsgSendSetLongLong)objc_msgSend)(created, targetSelector, (long long)pid);
        }
    }
    *record = created;
    return nil;
}

static id IPURNewTouchPath(CGPoint point, double offset) {
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    return ((IPURMsgSendInitPath)objc_msgSend)(
        [pathClass alloc], NSSelectorFromString(@"initForTouchAtPoint:offset:"), IPURConvertTouchPoint(point), offset);
}

static void IPURMove(id path, CGPoint point, double offset) {
    ((IPURMsgSendPathMove)objc_msgSend)(path, NSSelectorFromString(@"moveToPoint:atOffset:"), IPURConvertTouchPoint(point), offset);
}

static void IPURLift(id path, double offset) {
    ((IPURMsgSendPathOffset)objc_msgSend)(path, NSSelectorFromString(@"liftUpAtOffset:"), offset);
}

static NSString *IPURSynthesize(id record, id path) {
    ((IPURMsgSendAddPath)objc_msgSend)(record, NSSelectorFromString(@"addPointerEventPath:"), path);
    NSError *error = nil;
    BOOL ok = ((IPURMsgSendSynthesize)objc_msgSend)(record, NSSelectorFromString(@"synthesizeWithError:"), &error);
    if (!ok) {
        return [NSString stringWithFormat:@"event synthesis failed: %@",
                error.localizedDescription ?: @"synthesizeWithError returned NO"];
    }
    return nil;
}

+ (nullable NSString *)synthesizeTapAt:(CGPoint)point pid:(int)pid {
    return [self synthesizeLongPressAt:point duration:0.04 pid:pid];
}

+ (nullable NSString *)synthesizeLongPressAt:(CGPoint)point duration:(NSTimeInterval)duration pid:(int)pid {
    @try {
        id record = nil;
        NSString *err = IPURCreateGestureRecord(@"InfinityCast-Tap", pid, &record);
        if (err != nil) return err;
        id path = IPURNewTouchPath(point, 0.0);
        if (path == nil) return @"could not create pointer path";
        IPURLift(path, MAX(0.01, duration));
        return IPURSynthesize(record, path);
    } @catch (NSException *ex) {
        return [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason];
    }
}

+ (nullable NSString *)synthesizeDragFrom:(CGPoint)start to:(CGPoint)end duration:(NSTimeInterval)duration pid:(int)pid {
    @try {
        id record = nil;
        NSString *err = IPURCreateGestureRecord(@"InfinityCast-Drag", pid, &record);
        if (err != nil) return err;
        id path = IPURNewTouchPath(start, 0.0);
        if (path == nil) return @"could not create pointer path";
        duration = MAX(0.02, duration);
        IPURMove(path, end, duration);
        IPURLift(path, duration);
        return IPURSynthesize(record, path);
    } @catch (NSException *ex) {
        return [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason];
    }
}

@end

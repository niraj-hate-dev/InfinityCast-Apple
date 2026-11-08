//
//  IPURBridge.h
//  InfinityCast
//
//  Touch event synthesis bridge using XCTest runtime.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface IPURBridge : NSObject

+ (BOOL)eventSynthesisAvailable;
+ (nullable NSString *)synthesizeTapAt:(CGPoint)point pid:(int)pid;
+ (nullable NSString *)synthesizeLongPressAt:(CGPoint)point duration:(NSTimeInterval)duration pid:(int)pid;
+ (nullable NSString *)synthesizeDragFrom:(CGPoint)start to:(CGPoint)end duration:(NSTimeInterval)duration pid:(int)pid;

@end

NS_ASSUME_NONNULL_END

//
//  IPURGeometry.h
//  InfinityCast
//
//  Touch coordinate transformation for iOS screen orientation.
//

#pragma once
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

static inline CGSize IPURScreenSizeFromFrame(CGRect frame, CGSize fallback) {
    if (frame.origin.x == 0 && frame.origin.y == 0
        && isfinite(frame.size.width) && isfinite(frame.size.height)
        && frame.size.width > 0 && frame.size.height > 0) {
        return frame.size;
    }
    return fallback;
}

static inline CGPoint IPURPortraitPoint(CGPoint point, long long interfaceOrientation, CGSize natural) {
    CGFloat width = MIN(natural.width, natural.height);
    CGFloat height = MAX(natural.width, natural.height);
    switch (interfaceOrientation) {
        case 2:  // portrait upside down
            return CGPointMake(width - point.x, height - point.y);
        case 3:  // landscape right
            return CGPointMake(width - point.y, point.x);
        case 4:  // landscape left
            return CGPointMake(point.y, height - point.x);
        default:
            return point;
    }
}

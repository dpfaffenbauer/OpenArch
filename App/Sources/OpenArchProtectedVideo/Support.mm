// Adapted from Ardia (https://github.com/ardia-browser/ardia,
// packages/ardiacore/ios/ArdiaSystemPictureInPicture.mm), Apache License
// 2.0, Copyright 2026 Mantra Patel. Changed for OpenArch. See NOTICE.

#import "Support.h"

namespace {

void AddCornerCap(CGMutablePathRef path, CGPoint corner, CGPoint alongX, CGPoint alongY, CGFloat radius) {
  CGPathMoveToPoint(path, NULL, alongX.x, alongX.y);
  CGPathAddArcToPoint(path, NULL, corner.x, corner.y, alongY.x, alongY.y, radius);
  CGPathAddLineToPoint(path, NULL, corner.x, corner.y);
  CGPathCloseSubpath(path);
}

}

namespace oa_runtime {

void RoundVideoCorners(CALayer *layer, CAShapeLayer *caps, CGFloat radius, NSColor *backdrop, NSRect full, NSRect visible, BOOL hostFlipped,
                       BOOL layerFlipped) {
  const BOOL minYKept = NSMinY(visible) <= NSMinY(full) + 0.5;
  const BOOL maxYKept = NSMaxY(visible) >= NSMaxY(full) - 0.5;
  const BOOL topKept = hostFlipped ? minYKept : maxYKept;
  const BOOL bottomKept = hostFlipped ? maxYKept : minYKept;
  const BOOL layerMinYKept = layerFlipped ? topKept : bottomKept;
  const BOOL layerMaxYKept = layerFlipped ? bottomKept : topKept;
  CACornerMask corners = 0;
  if (layerMinYKept) corners |= kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
  if (layerMaxYKept) corners |= kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
  const CGFloat rounded = corners ? MIN(radius, MIN(NSWidth(visible), NSHeight(visible)) / 2) : 0;
  if (layer.cornerRadius != rounded) layer.cornerRadius = rounded;
  if (layer.maskedCorners != corners && corners) layer.maskedCorners = corners;
  const CGRect bounds = layer.bounds;
  if (!CGRectEqualToRect(caps.frame, bounds)) caps.frame = bounds;
  const BOOL capped = rounded > 0 && backdrop;
  caps.hidden = !capped;
  if (!capped) return;
  caps.fillColor = backdrop.CGColor;
  const CGFloat x0 = CGRectGetMinX(bounds), x1 = CGRectGetMaxX(bounds), y0 = CGRectGetMinY(bounds), y1 = CGRectGetMaxY(bounds);
  CGMutablePathRef path = CGPathCreateMutable();
  if (layerMinYKept) {
    AddCornerCap(path, CGPointMake(x0, y0), CGPointMake(x0 + rounded, y0), CGPointMake(x0, y0 + rounded), rounded);
    AddCornerCap(path, CGPointMake(x1, y0), CGPointMake(x1 - rounded, y0), CGPointMake(x1, y0 + rounded), rounded);
  }
  if (layerMaxYKept) {
    AddCornerCap(path, CGPointMake(x0, y1), CGPointMake(x0 + rounded, y1), CGPointMake(x0, y1 - rounded), rounded);
    AddCornerCap(path, CGPointMake(x1, y1), CGPointMake(x1 - rounded, y1), CGPointMake(x1, y1 - rounded), rounded);
  }
  caps.path = path;
  CGPathRelease(path);
}

}

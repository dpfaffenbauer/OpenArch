// Adapted from Ardia (https://github.com/ardia-browser/ardia,
// packages/ardiacore/ios: ArdiaRuntime.h, ArdiaWebView.mm,
// ArdiaSystemPictureInPicture.mm), Apache License 2.0, Copyright 2026
// Mantra Patel. Changed for OpenArch. See NOTICE.

#import "OpenArchProtectedVideo.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <cmath>

namespace oa_runtime {

inline void WithoutActions(void (^block)(void)) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  block();
  [CATransaction commit];
}

inline id JSONObject(NSString *json) {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
}

inline NSString *JSONText(id value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value ?: NSNull.null options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}

// A message's field, when it has the type asked for.
template <typename T>
T *Field(NSDictionary *d, NSString *key) {
  id value = [d isKindOfClass:NSDictionary.class] ? d[key] : nil;
  return [value isKindOfClass:[T class]] ? value : nil;
}

inline NSString *Text(NSDictionary *d, NSString *key, NSUInteger max) {
  NSString *s = Field<NSString>(d, key);
  if (s.length <= max) return s;
  return [s substringToIndex:[s rangeOfComposedCharacterSequenceAtIndex:max].location];
}

inline bool Flag(NSDictionary *d, NSString *key) {
  return Field<NSNumber>(d, key).boolValue;
}

inline bool Finite(NSDictionary *d, NSString *key, double *out) {
  NSNumber *n = Field<NSNumber>(d, key);
  if (!n || !std::isfinite(n.doubleValue)) return false;
  *out = n.doubleValue;
  return true;
}

// The identifiers of the two views over |page|'s view: its video and the
// copy of its controls. A window's pages share one superview, so each page
// has its own.
inline NSString *VideoViewIdentifier(id<OAPVPage> page) {
  return [NSString stringWithFormat:@"openarch.protectedVideo.%p", page];
}

inline NSString *MirrorViewIdentifier(id<OAPVPage> page) {
  return [NSString stringWithFormat:@"openarch.videoMirror.%p", page];
}

// Rounds |layer|'s corners where the video's own corners are on screen, and
// fills the cut-off corners with |backdrop| (|caps|).
void RoundVideoCorners(CALayer *layer, CAShapeLayer *caps, CGFloat radius, NSColor *backdrop, NSRect full, NSRect visible, BOOL hostFlipped,
                       BOOL layerFlipped);

}

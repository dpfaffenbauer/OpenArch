// Find in page for OpenArch's pages on Chrome's framework: Chrome's find
// bar belongs to Chrome's (hidden) window, so the pane has its own, a small
// bar at the top right of the page, searching with Chrome's FindTabHelper.

#ifndef OPENARCH_FINDBAR_H_
#define OPENARCH_FINDBAR_H_

#import <AppKit/AppKit.h>

namespace content {
class WebContents;
}

@interface OAFindBar : NSVisualEffectView

- (instancetype)initWithWebContents:(content::WebContents*)contents;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

/// Shows the bar at the top right of |pageFrame| (in |view|'s coordinates)
/// and puts the cursor in its field.
- (void)showInView:(NSView*)view pageFrame:(NSRect)pageFrame;
/// Moves it along with the page.
- (void)placeInPageFrame:(NSRect)pageFrame;
/// The next (or previous) match; opens the bar first if needed.
- (void)findNext:(BOOL)forward;
/// Ends the search, keeps the found text selected.
- (void)close;
/// The page goes away: forget it.
- (void)detachWebContents;

@property(readonly) BOOL isOpen;

@end

#endif  // OPENARCH_FINDBAR_H_

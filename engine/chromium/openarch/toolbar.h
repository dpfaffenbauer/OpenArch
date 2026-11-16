// OpenArch's extension toolbar on Chrome's framework (OACPane.toolbarVisible).
// Chrome's toolbar belongs to its (hidden) window; this one sits above the
// page: the pinned extensions' buttons (icon, badge, greyed when the
// action is off for the page) and the puzzle piece with every extension.
// A click runs the extension's action as Chrome's button does
// (ExtensionActionRunner: activeTab, onClicked); an action with a popup
// shows it in a small window below the button.

#ifndef OPENARCH_TOOLBAR_H_
#define OPENARCH_TOOLBAR_H_

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

class BrowserWindowInterface;

namespace content {
class WebContents;
}

/// An extension's side panel (chrome.sidePanel, openPanelOnActionClick),
/// shown by the pane beside the page.
@interface OASidePanel : NSObject
@property(readonly, copy) NSString* extensionID;
/// The panel's page.
@property(readonly) NSView* view;
/// Called when the panel's page closes itself (window.close()).
@property(nonatomic, copy, nullable) void (^onClose)(void);
- (void)wasShown;
@end

@interface OAExtensionToolbar : NSView

/// The site button (right of the extensions) was clicked: show the site's
/// controls below |screenRect|. Without a handler it shows a menu of the
/// extensions.
@property(nonatomic, copy, nullable) void (^siteControlsHandler)(NSRect screenRect);

/// The extensions with an action, for OACPane.extensions.
- (NSArray*)extensionInfos;
/// Runs an extension's action, its popup below |screenRect|.
- (void)runExtension:(NSString*)identifier fromScreenRect:(NSRect)screenRect;
- (void)setExtension:(NSString*)identifier pinned:(BOOL)pinned;

/// Shows (or, for the same extension again, hides) an extension's side panel.
@property(nonatomic, copy, nullable) void (^sidePanelHandler)(OASidePanel* panel);

/// The bar's height above the page.
@property(class, readonly) CGFloat height;

/// The radius of the pane's card: the bar has its top corners.
@property(nonatomic) CGFloat cornerRadius;

/// The page navigated or got its favicon: the site at the bar's left.
- (void)pageChanged;

/// |browser| is the hidden Chrome window holding the page (popups need it);
/// |openURL| opens a page in a new OpenArch tab (Erweiterungen verwalten).
- (instancetype)initWithWebContents:(content::WebContents*)contents
                            browser:(BrowserWindowInterface*)browser
                            openURL:(void (^)(NSString* url))openURL;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

/// The page goes away: forget it, close its popup.
- (void)detachWebContents;

/// Closes an open extension popup (any page's).
+ (void)closePopup;

@end

NS_ASSUME_NONNULL_END

#endif  // OPENARCH_TOOLBAR_H_

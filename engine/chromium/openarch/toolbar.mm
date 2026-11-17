#import "openarch/toolbar.h"

#include "openarch/internal.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/extensions/api/side_panel/side_panel_service.h"
#include "chrome/browser/extensions/extension_action_dispatcher.h"
#include "chrome/common/extensions/api/side_panel.h"
#include "components/tabs/public/tab_interface.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/extensions/extension_uninstall_dialog.h"
#include "chrome/browser/extensions/extension_view.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/extensions/extension_view_host_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/extensions/extension_popup_types.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "url/gurl.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/reload_type.h"
#include "skia/ext/skia_utils_mac.h"
#include "ui/gfx/image/image.h"

@interface OAExtensionToolbar ()
- (void)rebuild;
@end

@interface OACExtensionInfo ()
@property(readwrite, copy) NSString* identifier;
@property(readwrite, copy) NSString* name;
@property(readwrite) NSImage* icon;
@property(readwrite) BOOL pinned;
@property(readwrite, copy) NSString* badge;
@property(readwrite) BOOL activeOnPage;
@end

@implementation OACExtensionInfo
@end

@interface OASidePanel ()
- (instancetype)initWithHost:(std::unique_ptr<extensions::ExtensionViewHost>)host
                 extensionID:(NSString*)extensionID;
- (void)hostClosed;
@end

@interface OAExtensionPopupPanel : NSPanel
@end

@implementation OAExtensionPopupPanel
- (BOOL)canBecomeKeyWindow {
  return YES;
}
@end

namespace {

constexpr CGFloat kBarHeight = 38;
constexpr CGFloat kButton = 28;
constexpr CGFloat kSpacing = 2;

// The one extension popup on screen.
class Popup;
Popup* g_popup = nullptr;

// The uninstall dialog wants a delegate; the toolbar's needs no answer.
class UninstallDelegate : public extensions::ExtensionUninstallDialog::Delegate {};
UninstallDelegate g_uninstall_delegate;

// An extension's popup: its ExtensionViewHost's page in a small window below
// the button, sized by the page (25×25 to 800×600, as in Chrome), shown once
// loaded, gone on window.close(), Escape, a click elsewhere or when OpenArch
// goes to the background.
class Popup : public extensions::ExtensionView {
 public:
  // |owner| is the toolbar whose page opened it: closing that page closes
  // it, closing other pages does not.
  Popup(std::unique_ptr<extensions::ExtensionViewHost> host, NSRect anchor, id owner)
      : host_(std::move(host)), anchor_(anchor), owner_(owner) {
    g_popup = this;
    host_->set_view(this);
    host_->SetCloseHandler(base::BindOnce(&Popup::HostWantsToClose, weak_factory_.GetWeakPtr()));
    panel_ = [[OAExtensionPopupPanel alloc] initWithContentRect:NSMakeRect(0, 0, 25, 25)
                                                       styleMask:NSWindowStyleMaskBorderless |
                                                                 NSWindowStyleMaskNonactivatingPanel
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
    panel_.hasShadow = YES;
    panel_.level = NSPopUpMenuWindowLevel;
    panel_.releasedWhenClosed = NO;
    panel_.opaque = NO;
    panel_.backgroundColor = NSColor.clearColor;
    // A popover: its material, rounded, a hairline border, the page inside.
    NSVisualEffectView* card = [[NSVisualEffectView alloc] initWithFrame:panel_.contentView.bounds];
    card.material = NSVisualEffectMaterialPopover;
    card.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    card.state = NSVisualEffectStateActive;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 12;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [NSColor.separatorColor CGColor];
    card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    panel_.contentView = card;
    NSView* page = host_->host_contents()->GetNativeView().GetNativeNSView();
    page.frame = card.bounds;
    page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [card addSubview:page];
    page.hidden = NO;
    // Gone on a click elsewhere or when OpenArch goes to the background, as
    // Chrome's popups: not on losing key, which another window of OpenArch
    // (or a page taking focus) can take for a moment while the popup stays.
    __block Popup* popup = this;
    NSPanel* panel = panel_;
    click_monitor_ = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                                             NSEventMaskOtherMouseDown
                                     handler:^NSEvent*(NSEvent* event) {
                                       if (event.window != panel) {
                                         popup->CloseSoon();
                                       }
                                       return event;
                                     }];
    resign_observer_ = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidResignActiveNotification
                    object:NSApp
                     queue:nil
                usingBlock:^(NSNotification*) {
                  popup->CloseSoon();
                }];
    host_->CreateRendererSoon();
  }

  ~Popup() override {
    if (g_popup == this) {
      g_popup = nullptr;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:resign_observer_];
    [NSEvent removeMonitor:click_monitor_];
    [panel_ orderOut:nil];
    host_->set_view(nullptr);
  }

  bool IsOwnedBy(id toolbar) const { return owner_ == toolbar; }

  void CloseSoon() {
    if (closing_) {
      return;
    }
    closing_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
  }

  // extensions::ExtensionView:
  gfx::NativeView GetNativeView() override { return host_->host_contents()->GetNativeView(); }

  void ResizeDueToAutoResize(content::WebContents*, const gfx::Size& new_size) override {
    gfx::Size size = new_size;
    size.SetToMax(extensions::kExtensionPopupMinSize);
    size.SetToMin(extensions::kExtensionPopupMaxSize);
    size_ = size;
    Place();
    // The first answer is often the smallest size, before the page laid
    // out; a popup that small shows once the moment below has passed.
    if (loaded_ && size_ != extensions::kExtensionPopupMinSize) {
      Show();
    }
  }

  void RenderFrameCreated(content::RenderFrameHost* frame) override {
    if (frame->IsInPrimaryMainFrame()) {
      EnableAutoResize();
    }
  }

  bool HandleKeyboardEvent(content::WebContents*, const input::NativeWebKeyboardEvent& event) override {
    NSEvent* ns_event = event.os_event.Get();
    if (ns_event.type == NSEventTypeKeyDown && ns_event.keyCode == 53) {
      CloseSoon();
      return true;
    }
    return false;
  }

  // The page tells its size once auto-resize is on, which needs its view:
  // it may not have one yet when its frame is created, so again once loaded.
  // The popup shows when both are there (or, failing a size, at the
  // smallest after a moment).
  void OnLoaded() override {
    host_->host_contents()->WasShown();
    EnableAutoResize();
    loaded_ = true;
    if (!size_.IsEmpty() && size_ != extensions::kExtensionPopupMinSize) {
      Show();
      return;
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(
            [](base::WeakPtr<Popup> popup) {
              if (popup) {
                if (popup->size_.IsEmpty()) {
                  popup->size_ = extensions::kExtensionPopupMinSize;
                }
                popup->Show();
              }
            },
            weak_factory_.GetWeakPtr()),
        base::Milliseconds(500));
  }

 private:
  void EnableAutoResize() {
    if (auto* view = host_->host_contents()->GetRenderWidgetHostView()) {
      view->EnableAutoResize(extensions::kExtensionPopupMinSize, extensions::kExtensionPopupMaxSize);
    }
  }

  void Show() {
    if (shown_) {
      return;
    }
    shown_ = true;
    Place();
    // In softly, a few points up from the button.
    NSRect frame = panel_.frame;
    panel_.alphaValue = 0;
    [panel_ setFrame:NSOffsetRect(frame, 0, 6) display:NO];
    [panel_ makeKeyAndOrderFront:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
      context.duration = 0.14;
      context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
      panel_.animator.alphaValue = 1;
      [panel_.animator setFrame:frame display:YES];
    }];
    host_->host_contents()->Focus();
  }

  void HostWantsToClose(extensions::ExtensionHost*) { CloseSoon(); }

  // Below the button, its right edge at the button's, on screen.
  void Place() {
    if (size_.IsEmpty()) {
      return;
    }
    NSRect frame = NSMakeRect(NSMaxX(anchor_) - size_.width(), NSMinY(anchor_) - 6 - size_.height(),
                              size_.width(), size_.height());
    NSScreen* screen = NSScreen.mainScreen;
    for (NSScreen* candidate in NSScreen.screens) {
      if (NSIntersectsRect(candidate.frame, anchor_)) {
        screen = candidate;
      }
    }
    NSRect visible = screen.visibleFrame;
    frame.origin.x = std::max(NSMinX(visible), std::min(NSMinX(frame), NSMaxX(visible) - NSWidth(frame)));
    frame.origin.y = std::max(NSMinY(visible), NSMinY(frame));
    [panel_ setFrame:frame display:YES];
  }

  std::unique_ptr<extensions::ExtensionViewHost> host_;
  NSRect anchor_;
  __weak id owner_;
  gfx::Size size_;
  NSPanel* __strong panel_;
  id __strong resign_observer_;
  id __strong click_monitor_;
  bool closing_ = false;
  bool loaded_ = false;
  bool shown_ = false;
  base::WeakPtrFactory<Popup> weak_factory_{this};
};

// The side panel's view of its host: the page, at the size the pane gives it.
class SidePanelView : public extensions::ExtensionView {
 public:
  SidePanelView(extensions::ExtensionViewHost* host) : host_(host) { host_->set_view(this); }
  ~SidePanelView() override { host_->set_view(nullptr); }
  gfx::NativeView GetNativeView() override { return host_->host_contents()->GetNativeView(); }
  void ResizeDueToAutoResize(content::WebContents*, const gfx::Size&) override {}
  void RenderFrameCreated(content::RenderFrameHost*) override {}
  bool HandleKeyboardEvent(content::WebContents*, const input::NativeWebKeyboardEvent&) override {
    return false;
  }
  void OnLoaded() override { host_->host_contents()->WasShown(); }

 private:
  raw_ptr<extensions::ExtensionViewHost> host_;
};

// Tells the bar when its extensions or their state change.
class ToolbarObserver : public ToolbarActionsModel::Observer,
                        public extensions::ExtensionActionDispatcher::Observer {
 public:
  ToolbarObserver(Profile* profile, OAExtensionToolbar* bar) : bar_(bar) {
    model_.Observe(ToolbarActionsModel::Get(profile));
    dispatcher_.Observe(extensions::ExtensionActionDispatcher::Get(profile));
  }

  void OnToolbarActionAdded(const ToolbarActionsModel::ActionId&) override { [bar_ rebuild]; }
  void OnToolbarActionRemoved(const ToolbarActionsModel::ActionId&) override { [bar_ rebuild]; }
  void OnToolbarActionUpdated(const ToolbarActionsModel::ActionId&) override { [bar_ rebuild]; }
  void OnToolbarModelInitialized() override { [bar_ rebuild]; }
  void OnToolbarPinnedActionsChanged() override { [bar_ rebuild]; }
  void OnToolbarActionsModelShutdown() override { model_.Reset(); }
  void OnExtensionActionUpdated(extensions::ExtensionAction*,
                                content::WebContents*,
                                content::BrowserContext*) override {
    [bar_ rebuild];
  }
  void OnShuttingDown() override { dispatcher_.Reset(); }

 private:
  __weak OAExtensionToolbar* bar_;
  base::ScopedObservation<ToolbarActionsModel, ToolbarActionsModel::Observer> model_{this};
  base::ScopedObservation<extensions::ExtensionActionDispatcher,
                          extensions::ExtensionActionDispatcher::Observer>
      dispatcher_{this};
};

}  // namespace

@implementation OASidePanel {
  std::unique_ptr<extensions::ExtensionViewHost> _host;
  std::unique_ptr<SidePanelView> _view;
}

- (instancetype)initWithHost:(std::unique_ptr<extensions::ExtensionViewHost>)host
                 extensionID:(NSString*)extensionID {
  if ((self = [super init])) {
    _host = std::move(host);
    _extensionID = [extensionID copy];
    _view = std::make_unique<SidePanelView>(_host.get());
    __weak OASidePanel* weakSelf = self;
    _host->SetCloseHandler(base::BindOnce(^(extensions::ExtensionHost*) {
      [weakSelf hostClosed];
    }));
    _host->CreateRendererSoon();
  }
  return self;
}

- (void)dealloc {
  _view.reset();
  _host.reset();
}

- (NSView*)view {
  return _host->host_contents()->GetNativeView().GetNativeNSView();
}

- (void)wasShown {
  _host->host_contents()->WasShown();
}

- (void)hostClosed {
  if (_onClose) {
    _onClose();
  }
}

@end

// A toolbar button: an icon on a soft, rounded highlight while the pointer
// is over it or it is pressed, a badge as a small pill at its lower right.
@interface OAToolbarButton : NSButton
@property(nonatomic, copy, nullable) NSString* badge;
@property(nonatomic, strong, nullable) NSColor* badgeColor;
@property(nonatomic) BOOL dimmed;
/// The color of symbol images and the highlight (follows the bar's color).
@property(nonatomic, strong, nullable) NSColor* tint;
@end

@implementation OAToolbarButton {
  BOOL _hovered;
  NSTrackingArea* _tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.bordered = NO;
    self.title = @"";
    self.imagePosition = NSImageOnly;
    self.focusRingType = NSFocusRingTypeNone;
  }
  return self;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) {
    [self removeTrackingArea:_tracking];
  }
  _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
                                           options:NSTrackingMouseEnteredAndExited |
                                                   NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
                                             owner:self
                                          userInfo:nil];
  [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent*)event {
  _hovered = YES;
  self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent*)event {
  _hovered = NO;
  self.needsDisplay = YES;
}

- (void)setBadge:(NSString*)badge {
  _badge = [badge copy];
  self.needsDisplay = YES;
}

- (void)setTint:(NSColor*)tint {
  _tint = tint;
  self.needsDisplay = YES;
}

- (void)setDimmed:(BOOL)dimmed {
  _dimmed = dimmed;
  self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSRect bounds = NSInsetRect(self.bounds, 1, 1);
  if (_hovered || self.isHighlighted) {
    CGFloat alpha = self.isHighlighted ? 0.16 : 0.08;
    [[(_tint ?: NSColor.labelColor) colorWithAlphaComponent:alpha] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:7 yRadius:7] fill];
  }
  NSImage* image = self.image;
  if (image) {
    NSSize size = NSMakeSize(16, 16);
    NSRect icon = NSMakeRect(NSMidX(self.bounds) - size.width / 2, NSMidY(self.bounds) - size.height / 2,
                             size.width, size.height);
    CGFloat alpha = _dimmed ? 0.35 : (self.isEnabled ? 1 : 0.5);
    if (image.isTemplate) {
      // Symbols in the label color, as the window's own buttons.
      NSImage* tinted = [NSImage imageWithSize:size
                                       flipped:NO
                                drawingHandler:^BOOL(NSRect rect) {
                                  [image drawInRect:rect];
                                  [(self.tint ?: NSColor.secondaryLabelColor) set];
                                  NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
                                  return YES;
                                }];
      [tinted drawInRect:icon fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:alpha];
    } else {
      [image drawInRect:icon fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:alpha];
    }
  }
  if (_badge.length) {
    NSDictionary* attributes = @{
      NSFontAttributeName : [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
      NSForegroundColorAttributeName : NSColor.whiteColor
    };
    NSSize text = [_badge sizeWithAttributes:attributes];
    CGFloat width = MAX(text.width + 6, 13);
    NSRect pill = NSMakeRect(NSMaxX(self.bounds) - width - 1, self.isFlipped ? NSMaxY(self.bounds) - 13 : 1, width, 12);
    // A ring in the bar's color sets the pill off from the icon.
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.9] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(pill, -1.5, -1.5) xRadius:7.5 yRadius:7.5] fill];
    [(_badgeColor ?: NSColor.systemRedColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:6 yRadius:6] fill];
    [_badge drawAtPoint:NSMakePoint(NSMidX(pill) - text.width / 2, NSMidY(pill) - text.height / 2)
         withAttributes:attributes];
  }
}

@end

// The page's site at the bar's left: its favicon and host; a click copies the
// address.
@interface OASiteLabel : NSButton
@end

@implementation OASiteLabel
- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}
@end

@implementation OAExtensionToolbar {
  raw_ptr<content::WebContents> _contents;
  raw_ptr<BrowserWindowInterface> _browser;
  raw_ptr<Profile> _profile;
  std::unique_ptr<extensions::ExtensionUninstallDialog> _uninstallDialog;
  std::unique_ptr<ToolbarObserver> _observer;
  void (^_openURL)(NSString*);
  NSVisualEffectView* _background;
  NSView* _separator;
  NSView* _divider;
  OASiteLabel* _site;
  NSMutableArray<OAToolbarButton*>* _buttons;
  OAToolbarButton* _puzzle;
  OAToolbarButton* _back;
  OAToolbarButton* _forward;
  OAToolbarButton* _reload;
  NSColor* _tint;  // symbols and text on the bar's color
  BOOL _copied;
}

+ (CGFloat)height {
  return kBarHeight;
}

+ (void)closePopup {
  if (g_popup) {
    g_popup->CloseSoon();
  }
}

// Closes the popup if this toolbar's page opened it.
- (void)closeOwnPopup {
  if (g_popup && g_popup->IsOwnedBy(self)) {
    g_popup->CloseSoon();
  }
}

- (instancetype)initWithWebContents:(content::WebContents*)contents
                            browser:(BrowserWindowInterface*)browser
                            openURL:(void (^)(NSString*))openURL {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 400, kBarHeight)])) {
    _contents = contents;
    _browser = browser;
    _profile = Profile::FromBrowserContext(contents->GetBrowserContext());
    _openURL = [openURL copy];
    _buttons = [NSMutableArray array];
    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _background = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    _background.material = NSVisualEffectMaterialHeaderView;
    _background.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _background.state = NSVisualEffectStateFollowsWindowActiveState;
    _background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_background];

    // A hairline between the bar and the page.
    _separator = [[NSView alloc] init];
    _separator.wantsLayer = YES;
    _separator.layer.backgroundColor = [NSColor.separatorColor CGColor];
    [self addSubview:_separator];

    // Between the pinned extensions and the puzzle piece.
    _divider = [[NSView alloc] init];
    _divider.wantsLayer = YES;
    _divider.layer.backgroundColor = [[NSColor.separatorColor colorWithAlphaComponent:0.6] CGColor];
    [self addSubview:_divider];

    _site = [[OASiteLabel alloc] init];
    _site.bordered = NO;
    _site.imagePosition = NSImageLeading;
    _site.imageHugsTitle = YES;
    _site.lineBreakMode = NSLineBreakByTruncatingTail;
    _site.target = self;
    _site.action = @selector(editAddress:);
    _site.toolTip = @"Adresse ändern (⌥-Klick kopiert sie)";
    NSMenu* siteMenu = [[NSMenu alloc] init];
    NSMenuItem* copyItem = [siteMenu addItemWithTitle:@"Adresse kopieren"
                                               action:@selector(copyAddress:)
                                        keyEquivalent:@""];
    copyItem.target = self;
    _site.menu = siteMenu;
    [self addSubview:_site];

    _puzzle = [[OAToolbarButton alloc] initWithFrame:NSMakeRect(0, 0, kButton, kButton)];
    // As Arc: the site's controls (extensions, permissions) behind one button.
    _puzzle.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3"
                              accessibilityDescription:@"Website-Einstellungen"];
    _puzzle.toolTip = @"Website-Einstellungen und Erweiterungen";
    _puzzle.target = self;
    _puzzle.action = @selector(siteButton:);
    [self addSubview:_puzzle];

    // As Arc: back, forward, reload at the left.
    _back = [self navigationButton:@"arrow.left" tip:@"Zurück" action:@selector(goBack:)];
    _forward = [self navigationButton:@"arrow.right" tip:@"Vorwärts" action:@selector(goForward:)];
    _reload = [self navigationButton:@"arrow.clockwise" tip:@"Neu laden" action:@selector(reload:)];

    _observer = std::make_unique<ToolbarObserver>(_profile, self);
    [self rebuild];
    [self pageChanged];
  }
  return self;
}

- (OAToolbarButton*)navigationButton:(NSString*)symbol tip:(NSString*)tip action:(SEL)action {
  OAToolbarButton* button = [[OAToolbarButton alloc] initWithFrame:NSMakeRect(0, 0, kButton, kButton)];
  button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
  button.toolTip = tip;
  button.target = self;
  button.action = action;
  [self addSubview:button];
  return button;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
  _cornerRadius = cornerRadius;
  self.layer.cornerRadius = cornerRadius;
  // Only the top: the page goes on below (flipped: the top is min y).
  self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
}

- (void)detachWebContents {
  _observer.reset();
  _contents = nullptr;
  _browser = nullptr;
  [self closeOwnPopup];
}

- (void)setFrame:(NSRect)frame {
  [super setFrame:frame];
  [self layoutContent];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  // Layer colors don't follow the appearance by themselves.
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    _separator.layer.backgroundColor = [NSColor.separatorColor CGColor];
    _divider.layer.backgroundColor = [[NSColor.separatorColor colorWithAlphaComponent:0.6] CGColor];
  }];
}

#pragma mark The page

// The bar takes the page's color (its theme-color, else its background), as
// Arc does; symbols and text go light or dark on it.
- (void)applyPageColor {
  std::optional<SkColor> color = _contents ? _contents->GetThemeColor() : std::nullopt;
  if (!color && _contents) {
    color = _contents->GetBackgroundColor();
  }
  if (color && SkColorGetA(*color) == 0xFF) {
    NSColor* fill = skia::SkColorToSRGBNSColor(*color);
    CGFloat luminance = 0.2126 * fill.redComponent + 0.7152 * fill.greenComponent + 0.0722 * fill.blueComponent;
    BOOL dark = luminance < 0.55;
    _background.hidden = YES;
    self.layer.backgroundColor = [fill CGColor];
    _tint = dark ? [NSColor colorWithWhite:1 alpha:0.78] : [NSColor colorWithWhite:0 alpha:0.6];
    _separator.layer.backgroundColor = [(dark ? [NSColor colorWithWhite:1 alpha:0.08]
                                              : [NSColor colorWithWhite:0 alpha:0.08]) CGColor];
    _divider.layer.backgroundColor = [(dark ? [NSColor colorWithWhite:1 alpha:0.14]
                                            : [NSColor colorWithWhite:0 alpha:0.12]) CGColor];
  } else {
    _background.hidden = NO;
    self.layer.backgroundColor = nil;
    _tint = nil;
    [self viewDidChangeEffectiveAppearance];
  }
  for (OAToolbarButton* button in @[ _back, _forward, _reload, _puzzle ]) {
    button.tint = _tint;
  }
  for (OAToolbarButton* button in _buttons) {
    button.tint = _tint;
  }
}

- (void)pageChanged {
  if (!_contents || _copied) {
    return;
  }
  [self applyPageColor];
  _back.enabled = _contents->GetController().CanGoBack();
  _forward.enabled = _contents->GetController().CanGoForward();
  BOOL loading = _contents->IsLoading();
  _reload.image = [NSImage imageWithSystemSymbolName:loading ? @"xmark" : @"arrow.clockwise"
                            accessibilityDescription:loading ? @"Stopp" : @"Neu laden"];
  _reload.toolTip = loading ? @"Stopp" : @"Neu laden";
  GURL url = _contents->GetVisibleURL();
  NSString* host = base::SysUTF8ToNSString(url.host());
  if (!host.length) {
    host = base::SysUTF8ToNSString(url.spec());
  }
  if ([host hasPrefix:@"www."]) {
    host = [host substringFromIndex:4];
  }
  NSImage* favicon = nil;
  if (auto* driver = favicon::ContentFaviconDriver::FromWebContents(_contents)) {
    gfx::Image image = driver->GetFavicon();
    if (!image.IsEmpty()) {
      favicon = image.ToNSImage();
      favicon.size = NSMakeSize(14, 14);
    }
  }
  // As Arc: a link symbol before the domain (a click edits the address).
  NSImageSymbolConfiguration* symbol = [NSImageSymbolConfiguration configurationWithPointSize:11
                                                                                      weight:NSFontWeightSemibold];
  NSColor* text = _tint ?: NSColor.secondaryLabelColor;
  symbol = [symbol configurationByApplyingConfiguration:[NSImageSymbolConfiguration
                                                            configurationWithHierarchicalColor:text]];
  (void)favicon;
  _site.image = [[NSImage imageWithSystemSymbolName:@"link" accessibilityDescription:nil]
      imageWithSymbolConfiguration:symbol];
  _site.attributedTitle = [[NSAttributedString alloc]
      initWithString:[@" " stringByAppendingString:host]
          attributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName : _tint ? [_tint colorWithAlphaComponent:1] : NSColor.labelColor
          }];
  [self layoutContent];
}

// A click edits the address, as ⌘L does (OpenArch's "Adresse öffnen …");
// ⌥-click and the context menu copy it.
- (void)editAddress:(id)sender {
  if (NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption) {
    [self copyAddress:sender];
    return;
  }
  [self.window makeKeyAndOrderFront:nil];
  [NSApp sendAction:NSSelectorFromString(@"openLocation:") to:nil from:self];
}

- (void)copyAddress:(id)sender {
  if (!_contents) {
    return;
  }
  NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:base::SysUTF8ToNSString(_contents->GetVisibleURL().spec())
                forType:NSPasteboardTypeString];
  _copied = YES;
  _site.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:nil];
  _site.attributedTitle = [[NSAttributedString alloc]
      initWithString:@" Adresse kopiert"
          attributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName : NSColor.controlAccentColor
          }];
  [self layoutContent];
  __weak OAExtensionToolbar* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    OAExtensionToolbar* bar = weakSelf;
    if (bar) {
      bar->_copied = NO;
      [bar pageChanged];
    }
  });
}

#pragma mark Extensions

- (const extensions::Extension*)extensionWithID:(const std::string&)identifier {
  return extensions::ExtensionRegistry::Get(_profile)->enabled_extensions().GetByID(identifier);
}

- (extensions::ExtensionAction*)actionOf:(const extensions::Extension*)extension {
  return extension ? extensions::ExtensionActionManager::Get(_profile)->GetExtensionAction(*extension)
                   : nullptr;
}

- (NSImage*)iconOf:(const extensions::Extension*)extension {
  extensions::ExtensionAction* action = [self actionOf:extension];
  gfx::Image image;
  if (action && _contents) {
    image = action->GetExplicitlySetIcon(extensions::ExtensionTabUtil::GetTabId(_contents));
    if (image.IsEmpty()) {
      image = action->GetDefaultIconImage();
    }
  }
  if (image.IsEmpty()) {
    return [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:nil];
  }
  NSImage* icon = image.ToNSImage();
  icon.size = NSMakeSize(16, 16);
  return icon;
}

- (void)rebuild {
  for (OAToolbarButton* button in _buttons) {
    [button removeFromSuperview];
  }
  [_buttons removeAllObjects];
  if (!_contents) {
    return;
  }
  ToolbarActionsModel* model = ToolbarActionsModel::Get(_profile);
  int tab = extensions::ExtensionTabUtil::GetTabId(_contents);
  if (model && model->actions_initialized()) {
    for (const auto& identifier : model->pinned_action_ids()) {
      const extensions::Extension* extension = [self extensionWithID:identifier];
      extensions::ExtensionAction* action = [self actionOf:extension];
      if (!action) {
        continue;
      }
      OAToolbarButton* button = [[OAToolbarButton alloc] initWithFrame:NSMakeRect(0, 0, kButton, kButton)];
      button.image = [self iconOf:extension];
      button.badge = base::SysUTF8ToNSString(action->GetDisplayBadgeText(tab));
      button.badgeColor = skia::SkColorToSRGBNSColor(action->GetBadgeBackgroundColor(tab));
      button.dimmed = !action->GetIsVisible(tab);
      std::string title = action->GetTitle(tab);
      NSString* tip = base::SysUTF8ToNSString(title.empty() ? extension->name() : title);
      button.toolTip = button.dimmed ? [tip stringByAppendingString:@" – auf dieser Seite nicht aktiv"] : tip;
      button.identifier = base::SysUTF8ToNSString(identifier);
      button.target = self;
      button.action = @selector(runAction:);
      button.menu = [self menuForExtension:extension pinned:YES withOpen:NO];
      button.tint = _tint;
      [self addSubview:button];
      [_buttons addObject:button];
    }
  }
  [self layoutContent];
}

- (void)layoutContent {
  NSRect bounds = self.bounds;
  _separator.frame = NSMakeRect(0, NSHeight(bounds) - 0.5, NSWidth(bounds), 0.5);
  CGFloat y = (kBarHeight - kButton) / 2;
  CGFloat x = NSWidth(bounds) - 8 - kButton;
  _puzzle.frame = NSMakeRect(x, y, kButton, kButton);
  _divider.hidden = _buttons.count == 0;
  if (_buttons.count) {
    x -= 6;
    _divider.frame = NSMakeRect(x, (kBarHeight - 16) / 2, 1, 16);
    x -= 5;
  }
  for (OAToolbarButton* button in [_buttons reverseObjectEnumerator]) {
    x -= kButton;
    button.frame = NSMakeRect(x, y, kButton, kButton);
    x -= kSpacing;
  }
  CGFloat left = 8;
  for (OAToolbarButton* button in @[ _back, _forward, _reload ]) {
    button.frame = NSMakeRect(left, y, kButton, kButton);
    left += kButton + kSpacing;
  }
  // The domain in the middle of the bar, as long as it fits between.
  NSSize site = _site.intrinsicContentSize;
  CGFloat room = MAX(0, x - left - 20);
  CGFloat width = MIN(site.width, room);
  CGFloat center = NSMidX(bounds) - width / 2;
  center = MAX(left + 10, MIN(center, x - 10 - width));
  _site.frame = NSMakeRect(center, (kBarHeight - site.height) / 2, width, site.height);
}

#pragma mark Actions

- (void)siteButton:(NSButton*)sender {
  if (!_siteControlsHandler) {
    [self showMenu:sender];
    return;
  }
  _siteControlsHandler([sender.window convertRectToScreen:[sender convertRect:sender.bounds toView:nil]]);
}

- (NSArray*)extensionInfos {
  NSMutableArray<OACExtensionInfo*>* infos = [NSMutableArray array];
  ToolbarActionsModel* model = ToolbarActionsModel::Get(_profile);
  if (!model || !_contents) {
    return infos;
  }
  int tab = extensions::ExtensionTabUtil::GetTabId(_contents);
  for (const auto& identifier : model->action_ids()) {
    const extensions::Extension* extension = [self extensionWithID:identifier];
    extensions::ExtensionAction* action = [self actionOf:extension];
    if (!action) {
      continue;
    }
    OACExtensionInfo* info = [[OACExtensionInfo alloc] init];
    info.identifier = base::SysUTF8ToNSString(identifier);
    info.name = base::SysUTF8ToNSString(extension->name());
    info.icon = [self iconOf:extension];
    info.pinned = model->IsActionPinned(identifier);
    info.badge = base::SysUTF8ToNSString(action->GetDisplayBadgeText(tab));
    info.activeOnPage = action->GetIsVisible(tab);
    [infos addObject:info];
  }
  [infos sortUsingComparator:^NSComparisonResult(OACExtensionInfo* a, OACExtensionInfo* b) {
    if (a.pinned != b.pinned) {
      return a.pinned ? NSOrderedAscending : NSOrderedDescending;
    }
    return [a.name localizedCaseInsensitiveCompare:b.name];
  }];
  return infos;
}

- (void)setExtension:(NSString*)identifier pinned:(BOOL)pinned {
  if (ToolbarActionsModel* model = ToolbarActionsModel::Get(_profile)) {
    model->SetActionVisibility(base::SysNSStringToUTF8(identifier), pinned);
  }
}

- (void)goBack:(id)sender {
  if (_contents && _contents->GetController().CanGoBack()) {
    _contents->GetController().GoBack();
  }
}

- (void)goForward:(id)sender {
  if (_contents && _contents->GetController().CanGoForward()) {
    _contents->GetController().GoForward();
  }
}

- (void)reload:(id)sender {
  if (!_contents) {
    return;
  }
  if (_contents->IsLoading()) {
    _contents->Stop();
  } else {
    _contents->GetController().Reload(content::ReloadType::NORMAL, /*check_for_repost=*/true);
  }
}

- (void)runAction:(id)sender {
  NSString* identifier = [sender isKindOfClass:[NSButton class]] ? [(NSButton*)sender identifier]
                                                                : [sender representedObject];
  NSView* anchorView = _puzzle;
  for (OAToolbarButton* button in _buttons) {
    if ([button.identifier isEqualToString:identifier]) {
      anchorView = button;
    }
  }
  [self runExtension:identifier anchor:anchorView];
}
- (void)runExtension:(NSString*)identifier anchor:(NSView*)anchorView {
  NSRect anchor = anchorView.window
                      ? [anchorView.window convertRectToScreen:[anchorView convertRect:anchorView.bounds toView:nil]]
                      : NSZeroRect;
  [self runExtension:identifier fromScreenRect:anchor];
}

- (void)runExtension:(NSString*)identifier fromScreenRect:(NSRect)anchor {
  const extensions::Extension* extension = [self extensionWithID:base::SysNSStringToUTF8(identifier)];
  extensions::ExtensionAction* action = [self actionOf:extension];
  auto* runner = _contents ? extensions::ExtensionActionRunner::GetForWebContents(_contents) : nullptr;
  if (!action || !runner) {
    return;
  }
  [OAExtensionToolbar closePopup];
  // As Chrome's button: grants activeTab, fires onClicked when there is no
  // popup, says whether to show one (or the extension's side panel).
  extensions::ExtensionAction::ShowAction show = runner->RunAction(extension, /*grant_tab_permissions=*/true);
  int tab = extensions::ExtensionTabUtil::GetTabId(_contents);
  if (show == extensions::ExtensionAction::ShowAction::kToggleSidePanel && _browser && _sidePanelHandler) {
    auto options = extensions::SidePanelService::Get(_profile)->GetOptions(*extension, tab);
    if (!options.path) {
      return;
    }
    std::unique_ptr<extensions::ExtensionViewHost> host = extensions::ExtensionViewHostFactory::CreateSidePanelHost(
        *extension, extension->GetResourceURL(*options.path), _browser,
        tabs::TabInterface::MaybeGetFromContents(_contents));
    if (host) {
      _sidePanelHandler([[OASidePanel alloc] initWithHost:std::move(host) extensionID:identifier]);
    }
    return;
  }
  if (show != extensions::ExtensionAction::ShowAction::kShowPopup || !_browser) {
    return;
  }
  std::unique_ptr<extensions::ExtensionViewHost> host =
      extensions::ExtensionViewHostFactory::CreatePopupHost(*extension, action->GetPopupUrl(tab),
                                                            _browser);
  if (!host) {
    return;
  }
  new Popup(std::move(host), anchor, self);  // deletes itself when closed
}

// An extension's menu: open it, pin or unpin, its options, manage it.
- (NSMenu*)menuForExtension:(const extensions::Extension*)extension pinned:(BOOL)pinned withOpen:(BOOL)withOpen {
  NSString* identifier = base::SysUTF8ToNSString(extension->id());
  NSMenu* menu = [[NSMenu alloc] initWithTitle:base::SysUTF8ToNSString(extension->name())];
  auto add = ^(NSString* title, NSString* symbol, SEL action) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = identifier;
    item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    [menu addItem:item];
  };
  if (withOpen) {
    add(@"Öffnen", @"arrow.up.forward.app", @selector(runAction:));
  }
  add(pinned ? @"Von der Leiste lösen" : @"An die Leiste heften", pinned ? @"pin.slash" : @"pin",
      @selector(togglePin:));
  if (extensions::OptionsPageInfo::HasOptionsPage(extension)) {
    add(@"Optionen", @"gearshape", @selector(openOptions:));
  }
  [menu addItem:[NSMenuItem separatorItem]];
  add(@"Erweiterung verwalten", @"slider.horizontal.3", @selector(manageExtension:));
  if (extensions::ExtensionSystem::Get(_profile)->management_policy()->UserMayModifySettings(extension, nullptr)) {
    add(@"Entfernen …", @"trash", @selector(removeExtension:));
  }
  return menu;
}

- (void)showMenu:(NSButton*)sender {
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Erweiterungen"];
  ToolbarActionsModel* model = ToolbarActionsModel::Get(_profile);
  std::vector<const extensions::Extension*> pinned, others;
  if (model) {
    for (const auto& identifier : model->action_ids()) {
      if (const extensions::Extension* extension = [self extensionWithID:identifier]) {
        (model->IsActionPinned(identifier) ? pinned : others).push_back(extension);
      }
    }
  }
  auto byName = [](auto* a, auto* b) { return a->name() < b->name(); };
  std::sort(pinned.begin(), pinned.end(), byName);
  std::sort(others.begin(), others.end(), byName);
  auto section = ^(NSString* title, const std::vector<const extensions::Extension*>& list, BOOL isPinned) {
    if (list.empty()) {
      return;
    }
    if (menu.numberOfItems) {
      [menu addItem:[NSMenuItem separatorItem]];
    }
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:title]];
    for (const extensions::Extension* extension : list) {
      NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:base::SysUTF8ToNSString(extension->name())
                                                    action:@selector(runAction:)
                                             keyEquivalent:@""];
      item.target = self;
      item.representedObject = base::SysUTF8ToNSString(extension->id());
      item.image = [self iconOf:extension];
      item.submenu = [self menuForExtension:extension pinned:isPinned withOpen:YES];
      [menu addItem:item];
    }
  };
  section(@"Angeheftet", pinned, YES);
  section(@"Weitere Erweiterungen", others, NO);
  if (!menu.numberOfItems) {
    NSMenuItem* none = [[NSMenuItem alloc] initWithTitle:@"Keine Erweiterungen installiert" action:nil keyEquivalent:@""];
    none.enabled = NO;
    [menu addItem:none];
  }
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* store = [[NSMenuItem alloc] initWithTitle:@"Chrome Web Store"
                                                 action:@selector(openStore:)
                                          keyEquivalent:@""];
  store.target = self;
  store.image = [NSImage imageWithSystemSymbolName:@"bag" accessibilityDescription:nil];
  [menu addItem:store];
  NSMenuItem* manage = [[NSMenuItem alloc] initWithTitle:@"Erweiterungen verwalten"
                                                  action:@selector(manage:)
                                           keyEquivalent:@""];
  manage.target = self;
  manage.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil];
  [menu addItem:manage];
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(NSWidth(sender.bounds), NSHeight(sender.bounds) + 4)
                          inView:sender];
}

- (void)togglePin:(NSMenuItem*)sender {
  ToolbarActionsModel* model = ToolbarActionsModel::Get(_profile);
  std::string identifier = base::SysNSStringToUTF8(sender.representedObject);
  if (model) {
    model->SetActionVisibility(identifier, !model->IsActionPinned(identifier));
  }
}

- (void)openOptions:(NSMenuItem*)sender {
  const extensions::Extension* extension =
      [self extensionWithID:base::SysNSStringToUTF8(sender.representedObject)];
  if (extension && _openURL) {
    _openURL(base::SysUTF8ToNSString(extensions::OptionsPageInfo::GetOptionsPage(extension).spec()));
  }
}

// As Chrome's toolbar menu: its confirmation dialog, over this window.
- (void)removeExtension:(NSMenuItem*)sender {
  const extensions::Extension* extension =
      [self extensionWithID:base::SysNSStringToUTF8(sender.representedObject)];
  if (!extension || !_profile) {
    return;
  }
  _uninstallDialog = extensions::ExtensionUninstallDialog::Create(
      _profile, gfx::NativeWindow(self.window), &g_uninstall_delegate);
  _uninstallDialog->ConfirmUninstall(extension, extensions::UNINSTALL_REASON_USER_INITIATED,
                                     extensions::UNINSTALL_SOURCE_TOOLBAR_CONTEXT_MENU);
}

- (void)manageExtension:(NSMenuItem*)sender {
  if (_openURL) {
    _openURL([@"chrome://extensions/?id=" stringByAppendingString:sender.representedObject]);
  }
}

- (void)openStore:(id)sender {
  if (_openURL) {
    _openURL(@"https://chromewebstore.google.com/");
  }
}

- (void)manage:(id)sender {
  if (_openURL) {
    _openURL(@"chrome://extensions");
  }
}

@end

// Dialogs of OpenArch's pages on Chrome's framework. Chrome shows a tab's
// dialogs over its window (here the hidden one that holds the page), so
// OpenArch's window hosts them instead:
//
// - web-modal dialogs (alert, confirm, prompt, "Leave site?", HTTP sign-in,
//   print, ...): the pane is the WebContentsModalDialogManager's delegate
//   and host; with a host that is not a Views widget, Chrome shows them as
//   sheets on the host's window;
// - JavaScript dialogs wait for "the tab in front": for OpenArch's pages
//   that is the pane on screen (g_page_foremost_hook);
// - permission prompts (camera, microphone, location, notifications, ...)
//   are OpenArch's, a sheet on the pane's window (g_permission_prompt_hook).

#include "openarch/internal.h"

#import <AppKit/AppKit.h>

#include <memory>
#include <string>
#include <vector>

#include "base/observer_list.h"
#include "base/strings/utf_string_conversions.h"
#include "base/supports_user_data.h"
#include "chrome/browser/openarch_engine_hooks.h"
#include "chrome/browser/openarch_permission_hook.h"
#include "components/permissions/permission_prompt.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_uma_constants.h"
#include "components/permissions/resolvers/permission_prompt_options.h"
#include "components/url_formatter/elide_url.h"
#include "components/web_modal/modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/views/widget/widget.h"

// Set here, read by components/constrained_window (apply.sh, 3f).
extern bool (*openarch_dialog_place_hook)(gfx::NativeWindow parent,
                                          const gfx::Size& size,
                                          gfx::Rect* bounds);

namespace {

const void* const kPaneDialogsKey = &kPaneDialogsKey;

// The host of a page's web-modal dialogs: the window that shows the pane.
class PaneDialogs : public base::SupportsUserData::Data,
                    public web_modal::WebContentsModalDialogManagerDelegate,
                    public web_modal::WebContentsModalDialogHost {
 public:
  explicit PaneDialogs(OACPane* pane) : pane_(pane) {}
  ~PaneDialogs() override {
    for (auto& observer : observers_) {
      observer.OnHostDestroying();
    }
  }

  // web_modal::WebContentsModalDialogManagerDelegate:
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost(
      content::WebContents*) override {
    return this;
  }
  bool IsWebContentsVisible(content::WebContents*) override { return pane_.isVisible; }

  // web_modal::WebContentsModalDialogHost:
  gfx::NativeView GetHostView() const override {
    return gfx::NativeView([openarch::DialogWindowForPane(pane_) contentView]);
  }
  gfx::Point GetDialogPosition(const gfx::Size& size) override {
    NSRect frame = PageFrame();
    return gfx::Point(NSMinX(frame) + (NSWidth(frame) - size.width()) / 2, 0);
  }
  gfx::Size GetMaximumDialogSize() override {
    NSRect frame = PageFrame();
    return gfx::Size(NSWidth(frame), NSHeight(frame));
  }
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override {
    observers_.AddObserver(observer);
  }
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override {
    observers_.RemoveObserver(observer);
  }

 private:
  NSRect PageFrame() const {
    NSRect frame = pane_.screenFrame;
    if (NSIsEmptyRect(frame)) {
      NSView* content = [openarch::DialogWindowForPane(pane_) contentView];
      return content ? content.bounds : NSMakeRect(0, 0, 800, 600);
    }
    return frame;
  }

  __weak OACPane* pane_;
  base::ObserverList<web_modal::ModalDialogHostObserver> observers_;
};

// OpenArch's permission prompt: a sheet on the pane's window, "<site>
// möchte" with Chrome's own words for each permission, Zulassen or
// Blockieren. Switching tabs takes it down; Chrome shows it again once the
// page is back on screen.
class PanePermissionPrompt : public permissions::PermissionPrompt {
 public:
  PanePermissionPrompt(permissions::PermissionPrompt::Delegate* delegate, NSWindow* window)
      : delegate_(delegate->GetWeakPtr()), window_(window), alive_(std::make_shared<bool>(true)) {
    NSAlert* alert = [[NSAlert alloc] init];
    std::u16string origin = url_formatter::FormatUrlForSecurityDisplay(
        delegate->GetRequestingOrigin(), url_formatter::SchemeDisplay::OMIT_HTTP_AND_HTTPS);
    alert.messageText =
        [NSString stringWithFormat:@"%@ möchte", openarch::ToNSString(origin)];
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    for (const auto& request : delegate->Requests()) {
      [lines addObject:[@"• " stringByAppendingString:openarch::ToNSString(
                                                         request->GetMessageTextFragment())]];
    }
    alert.informativeText = [lines componentsJoinedByString:@"\n"];
    [alert addButtonWithTitle:@"Zulassen"];
    [alert addButtonWithTitle:@"Blockieren"];
    alert_ = alert;
    std::shared_ptr<bool> alive = alive_;
    base::WeakPtr<permissions::PermissionPrompt::Delegate> target = delegate_;
    void (^answer)(NSModalResponse) = ^(NSModalResponse response) {
      if (!*alive || !target) {
        return;
      }
      PromptOptions options{std::monostate()};
      if (response == NSAlertFirstButtonReturn) {
        target->Accept(options);
      } else if (response == NSAlertSecondButtonReturn) {
        target->Deny(options);
      } else {
        target->Dismiss(options);
      }
    };
    if (window) {
      [alert beginSheetModalForWindow:window completionHandler:answer];
    } else {
      answer([alert runModal]);
    }
  }

  ~PanePermissionPrompt() override {
    *alive_ = false;
    if (window_ && alert_.window.sheetParent) {
      [window_ endSheet:alert_.window];
    }
  }

  // permissions::PermissionPrompt:
  bool UpdateAnchor() override { return true; }
  TabSwitchingBehavior GetTabSwitchingBehavior() override {
    return kDestroyPromptButKeepRequestPending;
  }
  permissions::PermissionPromptDisposition GetPromptDisposition() const override {
    return permissions::PermissionPromptDisposition::ANCHORED_BUBBLE;
  }
  bool IsAskPrompt() const override { return true; }
  std::optional<gfx::Rect> GetViewBoundsInScreen() const override { return std::nullopt; }
  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants() const override {
    return {};
  }
  std::optional<permissions::feature_params::PermissionElementPromptPosition> GetPromptPosition()
      const override {
    return std::nullopt;
  }

 private:
  base::WeakPtr<permissions::PermissionPrompt::Delegate> delegate_;
  NSWindow* __strong window_;
  NSAlert* __strong alert_;
  std::shared_ptr<bool> alive_;
};

int PageForemost(content::WebContents* contents) {
  OACPane* pane = openarch::PaneForWebContents(contents);
  if (!pane) {
    return -1;
  }
  return pane.isVisible ? 1 : 0;
}

std::unique_ptr<permissions::PermissionPrompt> CreatePermissionPrompt(
    content::WebContents* contents,
    permissions::PermissionPrompt::Delegate* delegate) {
  OACPane* pane = openarch::PaneForWebContents(contents);
  if (!pane) {
    return nullptr;
  }
  return std::make_unique<PanePermissionPrompt>(delegate, openarch::DialogWindowForPane(pane));
}

}  // namespace

namespace openarch {

NSWindow* DialogWindowForPane(OACPane* pane) {
  return pane.window ?: NSApp.mainWindow ?: NSApp.keyWindow;
}

void HostDialogsInPane(content::WebContents* contents, OACPane* pane) {
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents);
  if (!manager) {
    web_modal::WebContentsModalDialogManager::CreateForWebContents(contents);
    manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents);
  }
  auto dialogs = std::make_unique<PaneDialogs>(pane);
  manager->SetDelegate(dialogs.get());
  contents->SetUserData(kPaneDialogsKey, std::move(dialogs));
}

void StopHostingDialogs(content::WebContents* contents) {
  if (auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents)) {
    manager->SetDelegate(nullptr);
  }
}

// Chrome's dialogs over a window of OpenArch's (extension install and
// remove, ...): centred on it, a little below its top, as Chrome puts them
// under its toolbar. Chrome's own windows place theirs themselves.
bool PlaceDialog(gfx::NativeWindow parent, const gfx::Size& size, gfx::Rect* bounds) {
  NSWindow* window = parent.GetNativeNSWindow();
  if (!window || !window.visible || views::Widget::GetWidgetForNativeWindow(parent)) {
    return false;
  }
  NSRect frame = window.frame;
  CGFloat x = NSMidX(frame) - size.width() / 2;
  CGFloat top = NSMaxY(frame) - 64;
  // Views' screen coordinates start at the top left of the first screen.
  CGFloat primary = NSMaxY(NSScreen.screens.firstObject.frame);
  *bounds = gfx::Rect(x, primary - top, size.width(), size.height());
  return true;
}

void InstallDialogHooks() {
  g_page_foremost_hook = &PageForemost;
  g_permission_prompt_hook = &CreatePermissionPrompt;
  openarch_dialog_place_hook = &PlaceDialog;
}

}  // namespace openarch

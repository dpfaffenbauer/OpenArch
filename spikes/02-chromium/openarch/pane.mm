#include "openarch/pane.h"

#import <AppKit/AppKit.h>

#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/tab_helpers.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/native_ui_types.h"
#include "url/gurl.h"

namespace openarch {

Pane::Pane(Profile* profile, const std::string& url) {
  content::WebContents::CreateParams params(profile);
  // Created hidden, like a background tab; ShowInWindow makes it visible.
  params.initially_hidden = true;
  web_contents_ = content::WebContents::Create(params);
  web_contents_->SetDelegate(this);
  // The helpers Chrome attaches to each of its tabs (favicons, permissions,
  // find, password manager, ...), so a tab costs here what it costs in Chrome.
  // Needs a friend declaration in tab_helpers.h (see ../setup.sh).
  TabHelpers::AttachTabHelpers(web_contents_.get());
  LoadURL(url);
}

Pane::~Pane() {
  Hide();
  web_contents_->SetDelegate(nullptr);
}

void Pane::ShowInWindow(NSWindow* window, double x, double y, double width, double height) {
  NSView* view = web_contents_->GetNativeView().GetNativeNSView();
  NSView* content = window.contentView;
  view.frame = NSMakeRect(x, y, width, height);
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (view.superview != content) {
    [content addSubview:view];
  }
  // A WebContents created hidden starts with its NSView hidden; in Chrome
  // the Views host unhides it (WebContentsViewMac::ViewsHostableSetVisible).
  view.hidden = NO;
  visible_ = true;
  web_contents_->WasShown();
}

void Pane::Hide() {
  if (!visible_) {
    return;
  }
  visible_ = false;
  web_contents_->WasHidden();
  NSView* view = web_contents_->GetNativeView().GetNativeNSView();
  view.hidden = YES;
  [view removeFromSuperview];
}

void Pane::LoadURL(const std::string& url) {
  content::NavigationController::LoadURLParams params{GURL(url)};
  params.transition_type = ui::PAGE_TRANSITION_TYPED;
  web_contents_->GetController().LoadURLWithParams(params);
}

content::WebContents* Pane::OpenURLFromTab(
    content::WebContents* source,
    const content::OpenURLParams& params,
    base::OnceCallback<void(content::NavigationHandle&)> navigation_handle_callback) {
  // Enough for the spike: every link opens in the same tab.
  LoadURL(params.url.spec());
  return source;
}

}  // namespace openarch

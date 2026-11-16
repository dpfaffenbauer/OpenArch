// One tab: a WebContents of a Chrome Profile, shown in a window that holds
// many of them. The counterpart of OACPane (App/Sources/OpenArchCore), cut
// down to what the memory bench needs: show, hide, loadURL.
//
// Unlike OACPane, a Pane has no window of its own. Its view is a subview of
// the host window's content view while it is shown and is taken out of the
// view tree while hidden, the way Chrome's own tab strip does it, so hidden
// tabs keep no compositor and no window-sized buffers.

#ifndef OPENARCH_PANE_H_
#define OPENARCH_PANE_H_

#include <memory>
#include <string>

#include "content/public/browser/web_contents_delegate.h"

#if defined(__OBJC__)
@class NSWindow;
#else
class NSWindow;
#endif

class Profile;

namespace content {
class WebContents;
}

namespace openarch {

class Pane : public content::WebContentsDelegate {
 public:
  Pane(Profile* profile, const std::string& url);
  Pane(const Pane&) = delete;
  Pane& operator=(const Pane&) = delete;
  ~Pane() override;

  // Puts the tab into |window| at |frame| (in the content view's
  // coordinates) and tells Chromium it is visible.
  void ShowInWindow(NSWindow* window, double x, double y, double width, double height);
  // Takes the tab out of its window and tells Chromium it is hidden.
  void Hide();
  void LoadURL(const std::string& url);

  bool is_visible() const { return visible_; }
  content::WebContents* web_contents() const { return web_contents_.get(); }

  // content::WebContentsDelegate:
  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)> navigation_handle_callback) override;

 private:
  std::unique_ptr<content::WebContents> web_contents_;
  bool visible_ = false;
};

}  // namespace openarch

#endif  // OPENARCH_PANE_H_

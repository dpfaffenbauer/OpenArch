// OpenArch's permission prompts (engine/chromium in the OpenArch repository,
// docs/chromium-engine.md). Chrome anchors its prompts to its window's
// location bar; OpenArch's pages are shown in OpenArch's windows, so the
// prompt is OpenArch's. //openarch sets the hook; Chrome never does.
#ifndef CHROME_BROWSER_OPENARCH_PERMISSION_HOOK_H_
#define CHROME_BROWSER_OPENARCH_PERMISSION_HOOK_H_

#include <memory>

#include "components/permissions/permission_prompt.h"

namespace content {
class WebContents;
}

namespace openarch {

// Returns OpenArch's prompt for a page OpenArch shows, nullptr for any other
// page (which keeps Chrome's).
using PermissionPromptHook = std::unique_ptr<permissions::PermissionPrompt> (*)(
    content::WebContents* web_contents,
    permissions::PermissionPrompt::Delegate* delegate);
inline PermissionPromptHook g_permission_prompt_hook = nullptr;

}  // namespace openarch

#endif  // CHROME_BROWSER_OPENARCH_PERMISSION_HOOK_H_

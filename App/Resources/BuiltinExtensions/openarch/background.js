// Chrome knows which tabs are audible (including Web Audio and embedded
// players); OpenArch does not. Report changes through the tab's own console,
// which OpenArch reads. Pages extensions may not script (chrome://, the Web
// Store) simply get no indicator.
const MARKER = '__openarch_audio__';

function report(tab) {
  const state = { audible: !!tab.audible, muted: !!tab.mutedInfo?.muted };
  chrome.scripting
    .executeScript({
      target: { tabId: tab.id },
      func: (marker, json) => console.debug(marker + ' ' + json),
      args: [MARKER, JSON.stringify(state)],
    })
    .catch(() => {});
}

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if ('audible' in changeInfo || 'mutedInfo' in changeInfo) {
    report(tab);
  }
});

// Netflix and Disney+ in Chromium, played with Apple's FairPlay
// (protected-video.js). While OpenArch's setting is on, that script runs in
// their pages before the pages' own scripts. A page tells which it is
// (protected-video-relay.js). The registration is kept from one launch to
// the next.
const PROTECTED_VIDEO = {
  id: 'openarch-protected-video',
  matches: ['https://www.netflix.com/*', 'https://www.disneyplus.com/*'],
  js: ['protected-video.js'],
  runAt: 'document_start',
  world: 'MAIN',
  allFrames: false,
};
// When a tab was loaded again, and how often for a script that did not run.
const reloads = new Map();

// Returns whether anything changed.
async function setProtectedVideo(on) {
  const registered = (await chrome.scripting.getRegisteredContentScripts({ ids: [PROTECTED_VIDEO.id] })).length > 0;
  if (on && !registered) await chrome.scripting.registerContentScripts([PROTECTED_VIDEO]);
  if (!on && registered) await chrome.scripting.unregisterContentScripts({ ids: [PROTECTED_VIDEO.id] });
  return on !== registered;
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.openarch !== 'protected-video' || !sender.tab) return;
  const on = message.on === true;
  setProtectedVideo(on)
    .then((changed) => {
      // The page was loaded without the script (or with it, and the
      // setting is off now): once more. A script that still does not run
      // is not worth a third try.
      const mismatch = message.present !== on;
      if (!changed && !mismatch) return;
      const last = reloads.get(sender.tab.id) || { at: 0, mismatches: 0 };
      if (Date.now() - last.at < 5000 || (!changed && last.mismatches >= 2)) return;
      reloads.set(sender.tab.id, { at: Date.now(), mismatches: changed ? 0 : last.mismatches + 1 });
      chrome.tabs.reload(sender.tab.id);
    })
    .catch(() => {});
});

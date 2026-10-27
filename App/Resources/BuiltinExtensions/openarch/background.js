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

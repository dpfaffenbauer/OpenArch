console.log('[probe] service worker started');

// Each check is its own message so a hanging API can't hide the others.
const checks = {
  ping: async () => 'pong',
  storage: async () => {
    await chrome.storage.local.set({ lastPing: Date.now() });
    const { lastPing } = await chrome.storage.local.get('lastPing');
    return typeof lastPing === 'number' ? 'ok' : 'missing';
  },
  tabs: async () => (await chrome.tabs.query({})).length + ' tab(s)',
  sender: async (sender) => 'tab id ' + (sender.tab?.id ?? 'none'),
  // Whether the asking page is its window's active tab, as an extension
  // that acts on "the current tab" (a password manager) finds it.
  active: async (sender) => {
    const [tab] = await chrome.tabs.query({ active: true, windowId: sender.tab?.windowId });
    return tab && tab.id === sender.tab?.id ? 'self' : 'other (' + (tab?.url ?? 'none') + ')';
  },
};

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const check = checks[message?.check];
  if (!check) {
    return false;
  }
  check(sender)
    .then((result) => sendResponse({ result }))
    .catch((error) => sendResponse({ error: error.message }));
  return true;
});

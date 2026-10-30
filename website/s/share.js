// The page for an OpenArch share link opened in any browser: reads the
// #fragment, decrypts here and shows the bookmarks. Text from the share only
// ever goes into textContent and checked href attributes.
import {
  DEFAULT_RELAY, ShareError, buildFragment, fetchLive, openSnapshot, parseFragment, unwrapPassword,
} from "./share-core.js";

const $ = (id) => document.getElementById(id);
const sections = ["loading", "password", "error", "share"];

function show(name) {
  for (const section of sections) $(section).hidden = section !== name;
}

const MESSAGES = {
  "invalid-link": ["This link is incomplete", "Ask for the link again. It may have been cut off when it was copied."],
  unsupported: ["Made by a newer OpenArch", "This share uses a format this page does not know yet. Open it in an up-to-date OpenArch."],
  damaged: ["This share cannot be read", "The link or the data on the share server has been changed or damaged."],
  "not-found": ["Share not found", "It may have expired, or the link may be wrong."],
  ended: ["Sharing has ended", "The person who shared these bookmarks has stopped sharing them."],
  rollback: ["This share cannot be read", "The share server sent an older version than expected."],
  unreachable: ["The share server cannot be reached", "Check your connection and try again."],
  server: ["The share server has a problem", "Try again in a moment."],
};

function showError(error, retry) {
  const code = error instanceof ShareError ? error.code : "damaged";
  if (!(error instanceof ShareError)) console.error(error);
  const [title, text] = MESSAGES[code] ?? MESSAGES.damaged;
  $("error-title").textContent = title;
  $("error-text").textContent = text;
  const button = $("retry");
  button.hidden = !retry || !(code === "unreachable" || code === "server");
  button.onclick = retry ?? null;
  show("error");
}

function host(url) {
  try {
    return new URL(url).host.replace(/^www\./, "");
  } catch {
    return "";
  }
}

/// A space's or folder's icon, when it is an emoji (SF Symbols only exist on
/// Apple's platforms).
function emoji(icon) {
  return typeof icon === "string" && /\p{Extended_Pictographic}/u.test(icon) && Array.from(icon).length <= 4 ? icon : "";
}

/// A letter in a colored square instead of the site's icon, which would
/// tell the site who is looking at the share.
function letterTile(name) {
  const tile = document.createElement("span");
  tile.className = "tile";
  tile.setAttribute("aria-hidden", "true");
  tile.textContent = (Array.from(name)[0] ?? "?").toUpperCase();
  let hash = 0;
  for (const character of name) hash = (hash * 31 + character.codePointAt(0)) >>> 0;
  tile.style.setProperty("--hue", String(hash % 360));
  return tile;
}

function folderGlyph(icon) {
  const symbol = emoji(icon);
  if (symbol) {
    const span = document.createElement("span");
    span.className = "glyph emoji";
    span.setAttribute("aria-hidden", "true");
    span.textContent = symbol;
    return span;
  }
  return $("folder-icon").content.firstElementChild.cloneNode(true);
}

function countTabs(nodes) {
  return nodes.reduce((sum, node) => sum + (node.children ? countTabs(node.children) : 1), 0);
}

function renderNodes(nodes, list) {
  for (const node of nodes) {
    const item = document.createElement("li");
    if (node.children) {
      item.className = "folder";
      const details = document.createElement("details");
      details.open = true;
      const summary = document.createElement("summary");
      const title = document.createElement("span");
      title.className = "title";
      title.textContent = node.title || "Folder";
      const count = document.createElement("span");
      count.className = "count";
      count.textContent = String(countTabs(node.children));
      summary.append(folderGlyph(node.icon), title, count);
      const children = document.createElement("ul");
      renderNodes(node.children, children);
      details.append(summary, children);
      item.append(details);
    } else {
      item.className = "tab";
      const link = document.createElement("a");
      // sanitize() kept http and https links only.
      link.href = node.url;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      const name = host(node.url);
      const text = document.createElement("span");
      text.className = "text";
      const title = document.createElement("span");
      title.className = "title";
      title.textContent = node.title || name || node.url;
      const address = document.createElement("span");
      address.className = "host";
      address.textContent = name;
      text.append(title, address);
      link.append(letterTile(name || node.title || "?"), text);
      item.append(link);
    }
    list.append(item);
  }
}

function formatDate(text) {
  const date = new Date(text);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function render(link, payload, version) {
  $("kind").textContent = payload.kind === "space" ? "Space" : "Folder";
  $("mode").textContent = link.mode === "live" ? "Live" : "Snapshot";
  $("mode").classList.toggle("live", link.mode === "live");
  $("name-text").textContent = payload.name || "Shared bookmarks";
  $("name-icon").textContent = emoji(payload.icon);
  document.title = `${payload.name || "Shared bookmarks"} · OpenArch`;
  if (payload.color) document.documentElement.style.setProperty("--space", payload.color);

  const count = countTabs(payload.items);
  const parts = [count === 1 ? "1 bookmark" : `${count} bookmarks`];
  const updated = payload.updated ? formatDate(payload.updated) : "";
  if (updated) parts.push(link.mode === "live" ? `updated ${updated}` : `shared ${updated}`);
  if (link.mode === "live") {
    parts.push(`version ${version}`);
    if (link.relay) parts.push(`via ${host(link.relay)}`);
  }
  $("meta").textContent = parts.join(" · ");

  // The same, checked link for the app; nothing unparsed goes into it.
  $("open-app").href = "openarch://share#" + buildFragment(link);

  const tree = $("tree");
  tree.replaceChildren();
  renderNodes(payload.items, tree);
  $("empty").hidden = payload.items.length > 0;
  show("share");
}

async function open(link, key) {
  show("loading");
  try {
    if (link.mode === "snapshot") {
      render(link, await openSnapshot(link.blob, key));
    } else {
      const { payload, version } = await fetchLive(link.id, key, link.relay ?? DEFAULT_RELAY);
      render(link, payload, version);
    }
  } catch (error) {
    showError(error, () => open(link, key));
  }
}

function askPassword(link) {
  show("password");
  const form = $("password-form");
  const input = $("password-input");
  const button = $("password-button");
  const message = $("password-error");
  message.hidden = true;
  input.value = "";
  input.focus();
  form.onsubmit = async (event) => {
    event.preventDefault();
    if (!input.value) return;
    button.disabled = true;
    button.textContent = "Opening …";
    message.hidden = true;
    try {
      const key = await unwrapPassword(link.keySlot.bytes, input.value);
      await open(link, key);
    } catch (error) {
      if (error instanceof ShareError && error.code === "wrong-password") {
        message.textContent = "That is not the password. Check it and try again.";
        message.hidden = false;
        input.select();
      } else {
        showError(error);
      }
    } finally {
      button.disabled = false;
      button.textContent = "Open";
    }
  };
}

function run() {
  const fragment = location.hash.slice(1);
  if (!fragment) {
    showError(new ShareError("invalid-link"));
    $("error-title").textContent = "No share in this link";
    $("error-text").textContent = "Links to shared OpenArch bookmarks end in #1. and a long code. Open the whole link you were sent.";
    return;
  }
  let link;
  try {
    link = parseFragment(fragment);
  } catch (error) {
    showError(error);
    return;
  }
  if (link.keySlot.type === "password") askPassword(link);
  else open(link, link.keySlot.bytes);
}

window.addEventListener("hashchange", run);
run();

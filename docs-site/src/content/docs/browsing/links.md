---
title: "Links from other apps"
description: "Make OpenArch your default browser, decide where links from Mail, Slack and other apps open with link rules and Little OpenArch, and how links to apps like Zoom are handled."
---

Once OpenArch is your default browser, links you click in Mail, Slack, Calendar and other apps open in it. By default they open as a new tab in the space you are in. Link rules send a site straight to the space it belongs in, and Little OpenArch can take the rest, as in Arc.

## Making OpenArch your default browser

After the first launch, OpenArch asks once: **OpenArch als Standardbrowser verwenden?** Choose **Als Standard festlegen**, and macOS asks you to confirm.

If you said **Nicht jetzt**, you can do it later in any of these places:

- **OpenArch › Als Standardbrowser festlegen** in the menu bar
- **Settings › Allgemein › Browser › Standardbrowser**
- **Settings › Links › Links aus anderen Apps › Standardbrowser**

The settings show **Aktiv** once OpenArch is the default. OpenArch then opens `http://` and `https://` links and HTML files. If macOS does not take the change, OpenArch says so; you can then choose OpenArch yourself under **System Settings › Desktop & Dock › Default web browser**.

## Where links land

Links from other apps never land in a private window or a [window of its own](/browsing/windows/#a-tab-in-a-window-of-its-own); they go to the normal window you used last. OpenArch decides in this order:

1. **A link rule matches the address:** the window switches to the rule's space and opens the link there in a new tab. A rule can also send the link to Little OpenArch.
2. **No rule, and Little OpenArch is on** (**Settings › Links › In Little OpenArch öffnen**): the link opens in a Little OpenArch window.
3. **Otherwise:** the link opens in a new tab at the top of today's tabs, in the space you are in.

A link that arrives while OpenArch is still starting opens once the window is there.

[Little OpenArch](/browsing/windows/#little-openarch) is a small window for one page. From there, **In Space öffnen** moves the page into the main window without loading it again, and you can close it if you only wanted a look.

Share links of OpenArch's (`openarch.app/s/…`) are not opened as pages: OpenArch offers to add the shared folder or space. See [Sharing](/sharing/share/).

## Link rules

Link rules send links from other apps to a space by their address: GitHub to Work, Google Sheets to Finance.

Set them up under **Settings › Links › Link-Regeln**:

1. Click **Regel hinzufügen**.
2. Type the address part to match.
3. Choose the space, or **Little OpenArch**.

The minus button removes a rule. The first rule that matches wins, so put the narrow ones first.

| Pattern | Matches |
| --- | --- |
| `github.com` | github.com and every subdomain, such as gist.github.com |
| `*.atlassian.net` | every subdomain of atlassian.net; `*` stands for any text |
| `docs.google.com/spreadsheets` | addresses on docs.google.com whose path starts with /spreadsheets |

`https://` and `www.` in a pattern or an address make no difference. Upper and lower case do not matter.

Rules apply only to links from other apps. A link you click in a page inside OpenArch stays where it is.

## Links to apps

Some links are for an app rather than a page: `zoommtg:` for Zoom, `mailto:` for your mail app, `bambustudioopen:` for a 3D printer's software, and so on. When a page goes to such a link, OpenArch asks first, as Chrome does:

> **„zoom.us“ öffnen?**
> meeting.example.com möchte diese App öffnen.

**Öffnen** opens the app, **Abbrechen** does nothing. Tick **Links von … immer in „…“ öffnen**, and the next links of that kind from that site open the app without asking. OpenArch remembers this per site and per kind of link.

If no app on the Mac opens that kind of link, a tab shows a short note instead: **Keine App für …: gefunden**.

## Dragging links in

Links dragged from a page, Safari, Mail or Finder onto the sidebar become tabs where you drop them. Dropped on a space's icon at the bottom of the sidebar, a link opens in a new tab in that space, and the window switches there.

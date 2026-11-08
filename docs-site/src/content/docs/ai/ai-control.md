---
title: "AI control"
description: "Open Chrome's DevTools protocol on this Mac so that Claude Code and other agents can drive OpenArch's real tabs."
---

AI control lets an agent use OpenArch itself: open pages, click, fill in
forms, take screenshots, and read a page's console and network requests, in
your real tabs and signed in as you. It is meant for Claude Code, and works for
anything else that speaks Chrome's DevTools protocol, such as Playwright or
Puppeteer. It is off by default, because while it is on, any program on the Mac
can use it.

## Turn it on

1. Open **Settings › KI** and find the section **KI-Steuerung** (AI control).
2. Turn on **KI-Steuerung erlauben** (Allow AI control).
3. Leave **Port** at 9222, or enter another.
4. OpenArch opens the port at launch, so the settings now say "Wird nach einem
   Neustart von OpenArch aktiv." (Takes effect after a restart). Click **Jetzt
   neu starten** (Restart now).

Afterwards the settings show "Aktiv auf 127.0.0.1:9222". Turning it off, or
changing the port, also takes a restart.

## The antenna

While the port is open, an orange antenna sits at the top of the sidebar, next
to the button that hides it. Resting the pointer on it shows "KI-Steuerung
aktiv: Chrome DevTools Protocol auf 127.0.0.1:9222". When the sidebar is too
narrow for it, an orange dot on the sidebar button takes its place.

## Connect Claude Code

**Settings › KI › Mit Claude Code verbinden** (Connect with Claude Code) shows
the command to run once in Terminal, with a button **Kopieren**:

```sh
claude mcp add openarch -- npx -y chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:9222
```

It adds Google's MCP server `chrome-devtools-mcp` to Claude Code under the name
`openarch`, pointed at OpenArch's port. The port in the command follows the
**Port** field. The server is started with `npx`, so it needs Node.js on the
Mac.

:::note
`claude mcp add` adds a server for the folder you run it in. For Claude Code to
have it in every folder, add `--scope user`:
`claude mcp add --scope user openarch -- npx -y chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:9222`
:::

[Agent chats](/ai/agent-chats/) and [page chats](/ai/page-chat/) in OpenArch
do not need this command: while AI control is on, OpenArch gives every run of
theirs the same server itself.

## What an agent can do with it

Through the port, an agent works in the browser the way you do: it opens pages
and tabs, clicks, types and fills in forms, takes screenshots, and reads the
console and the network requests. It works in your real tabs, in your spaces'
profiles, signed in wherever you are signed in. This is what makes it useful
for testing a page you are building locally, or for a task on a site that needs
your login.

In OpenArch's own chats, these steps show as "Browser: …". Unless a chat is set
to **Alles erlauben** (Allow everything), its first browser step is refused and
shows "Browser-Steuerung nicht erlaubt" with **Erlauben und weiter** (Allow and
continue), which allows OpenArch's browser control for that chat. A page chat
is told to use the browser only when you ask it to do something in a tab.

Other tools that speak the DevTools protocol, such as Playwright or Puppeteer,
connect to the same address, `http://127.0.0.1:9222`.

## Keep it off when you do not need it

:::caution
While the port is open, any program on this Mac can control the browser
through it, not only Claude Code, and without asking: including tabs where you
are signed in. It listens on 127.0.0.1 only, so it cannot be reached from
other devices. Turn AI control on when you need it and off again afterwards.
:::

The antenna in the sidebar is there so that you see when the port is open.

## What Claude gets and what it may do

With AI control, an agent can see whatever your tabs show and do what you can
do in them. Agent chats and page chats get OpenArch's browser server only while
AI control is on, and what a chat may do without asking is set per chat.

OpenArch does not give the server to the [Morning Brief](/ai/morning-brief/)
or to [tidying tabs](/ai/tidy-tabs/). If you added it to Claude Code with
`--scope user`, though, the Morning Brief sees it like any other connector and
may use the tools whose names say they read, such as listing the tabs.

How the runs work in detail: [How OpenArch talks to Claude](/ai/how-it-works/).

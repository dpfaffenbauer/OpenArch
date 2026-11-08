---
title: "Agent chats and Agents"
description: "Work with Claude Code from the sidebar: agent chats that work in a folder on your Mac, and the Agents view that lists every Claude Code session."
---

An agent chat is Claude Code in the sidebar. It sits there like a tab, shows
where the page would be, and works in a folder on your Mac: it reads code,
changes files and runs commands while you go on browsing. The **Agents** view
lists these chats together with every Claude Code session from Terminal or your
editor, so you can see which of them waits for you.

## Turn them on

Agent chats are off until you turn them on under **Settings › KI › Agents in
der Sidebar**:

| Setting | What it does |
| --- | --- |
| **Agent-Chats** | Turns agent chats and the Agents view on |
| **Ordner für neue Chats** (Folder for new chats) | Where new chats work; your home folder unless you choose another with **Wählen …** |
| **Claude Code** | Where OpenArch found `claude` ("Gefunden: …"), or how to install it; **Erneut suchen** (Search again) after installing |

While they are off, **Ablage › Neuer Agent-Chat** and <kbd>⌃0</kbd> open this
settings page instead.

## Start a chat

- **+** at the bottom of the sidebar › **Neuer Agent-Chat**
- the **…** menu beside the space's name › **Neuer Agent-Chat**
- the ✨ that appears when you point at **Neuer Tab**
- **Ablage › Neuer Agent-Chat**
- the command bar: "Neuer Agent-Chat", or type what you want done and choose
  "Agent-Chat starten" to send it as the first message

The chat goes to the top of the tabs under the line, with the cursor in its
field. <kbd>↩</kbd> sends, <kbd>⌥↩</kbd> starts a new line, and **Anhalten**
(Stop) ends a run. The chat is named after its first message; right-click ›
**Umbenennen** renames it. Agent chats are not available in private windows.

The folder shows in the chat's header. Click it for **Ordner wählen …** (Choose
folder) and **Im Finder zeigen**. You can change the folder until you send the
first message; after that Claude Code can only continue the session in that
folder.

## What the agent may do

The menu next to the folder sets this per chat:

| Choice | Meaning |
| --- | --- |
| **Nachfragen** (Ask), the default | Reads files; asks before changes, commands and the browser |
| **Dateien bearbeiten** (Edit files) | Changes files without asking; asks before commands |
| **Alles erlauben** (Allow everything) | Changes files and runs commands without asking |

Claude Code cannot stop in the middle of a run to ask you. What it was not
allowed to do shows in the chat as "… nicht erlaubt" with the command or file,
and a button **Erlauben und weiter** (Allow and continue). It allows that for
this chat and tells the agent to carry on. One click allows:

- for a command, every command that starts with the same program, such as all
  `npm` commands;
- for the browser, all of OpenArch's browser control;
- otherwise the tool, such as changing files.

The chat keeps what you allowed.

:::caution
With **Alles erlauben** the agent runs any command and changes any file
without asking you first.
:::

## While it works

Answers show as Markdown. Each step the agent takes shows as a line, such as
**Befehl** (Command), **Liest** (Reads) or **Ändert** (Changes), with what it
worked on; a click opens what came back. Links in answers open as new tabs.

The chat goes on working while you are in other tabs. Its row in the sidebar
shows a turning wheel while it works and a dot once it has answered while you
were elsewhere. If OpenArch is not in front, its Dock icon bounces once.

With [AI control](/ai/ai-control/) on, the agent also gets OpenArch's tabs as
tools; those steps are titled "Browser: …".

## The panel beside the chat

As in the Claude app, a panel to the right of the chat shows what the agent
works with. The button at the right of the header shows or hides it.

| Section | Shows |
| --- | --- |
| **Umgebung** (Environment) | the folder, the repository and branch if it is a Git repository, and the model Claude Code uses |
| **Kontext** (Context) | how full the conversation's context is, after the first answer |
| **Connectors** | the MCP servers Claude Code started, with a dot: green when connected, red when failed, orange otherwise |
| **Änderungen** (Changes) | files changed since the last commit, with lines added and removed; a click shows the diff |
| **Ausgabe** (Output) | the last five commands and what they printed |

The panel reads the folder again after each run and every ten seconds while it
is open. OpenArch does not choose a model; the chat uses the one Claude Code
uses with your settings.

## Closing and keeping chats

Under the line, closing a chat (its ×, or <kbd>⌘W</kbd>) deletes it with its
messages; there is no archive for chats. To keep one, pin it: right-click ›
**Anheften (⌘D)**. "Heute aufräumen" leaves agent chats where they are. If a
chat is still at work, OpenArch asks first.

Claude Code keeps the session itself, so a deleted chat still shows in the
Agents view and can be continued from there. Messages are saved in
`~/Library/Application Support/OpenArch/Agents/`, one file per chat.

## The Agents view

Click the ✨ at the start of the space bar, press <kbd>⌃0</kbd>, or choose
**Ansicht › Agents**. Like a space of its own, the sidebar then lists your
agents instead of the space's tabs; the page or chat in front stays. Click a
space, or press <kbd>⌃0</kbd> again, to go back.

The list shows every agent chat, from all spaces, and every Claude Code session
on this Mac from the last 30 days, read from Claude Code's transcripts in
`~/.claude/projects` (or in `CLAUDE_CONFIG_DIR`, if OpenArch's environment has
it). OpenArch's own runs (page chats, the Morning Brief,
tidying) are left out. It updates every 30 seconds while agent chats are on,
and every eight seconds while you look at it.

Each agent is one line with its title. On the right:

| Mark | Meaning |
| --- | --- |
| turning wheel | at work |
| yellow dot | waits for you: it has answered |
| orange dot | may wait for your approval |
| ring, with a number | open todos |

Pointing at a line shows how long ago it last did something (and its project,
when the list is grouped by status); resting on it shows its last answer. The ✨ in the space bar gets an orange dot
while sessions wait for you.

The filter menu at the top (**Gruppieren nach**, Group by) sorts the list by
**Status**, into **Wartet auf dich**, **Arbeitet**, **Offene Todos** and
**Ruhend** (Resting, closed at first), or by **Projekt**, the folder each one
works in. A group shows eight lines, then "… weitere zeigen" (show more).
**Suchen** filters by title, project and last answer. The pencil at the top
starts a new agent chat.

A session from Terminal counts as at work while a `claude` process works in its
folder. It waits for you once its last step is an answer, and may wait for your
approval when a step has not come back for 30 seconds, which is often a
question whether it may run something, sometimes just a long command. Without
a running process it rests, or has open todos if its todo list has unfinished
items.

## Continue a session

Click a session to open it as an agent chat at the top of the tabs under the
line, with its history. Your next message continues the same session, in its
folder. If a chat already continues it, that chat opens instead. A session that
still runs in a terminal gets a note that what you write here continues it
separately.

Right-click a line for **Als Agent-Chat öffnen**, **Im Terminal fortsetzen**
(runs `claude --resume` in its folder in Terminal), **Ordner im Finder zeigen**,
**Session-ID kopieren** and, for chats, **Chat löschen**.

## What Claude gets and what it may do

Every message is one run of Claude Code on your own login, in the chat's
folder, continuing the chat's session. OpenArch adds a short note that it is a
chat in OpenArch's sidebar working in that folder. What it may do is the
setting above, plus what you allowed in the chat; with AI control on, it also
gets OpenArch's browser tools.

How the runs work in detail: [How OpenArch talks to Claude](/ai/how-it-works/).

---
title: "Chat with the page"
description: "Press ⌘E to ask Claude about the page in front, a passage you selected on it, or several tabs at once, in a panel beside the page."
---

<kbd>⌘E</kbd> opens a chat with Claude beside the page you are reading, as in
Dia. Claude gets the page's address, title and text, so you can ask for a
summary, an explanation or a translation without copying anything. It runs on
Claude Code on your Mac, with your own Claude login (see
[How OpenArch talks to Claude](/ai/how-it-works/)).

## Open the chat

Press <kbd>⌘E</kbd>, or choose **Ansicht › Mit der Seite chatten** (View ›
Chat with the page). The panel opens to the right of the page, with the cursor
in its field.

Before the first message, the panel shows three questions to start with, such
as "Fasse die Seite zusammen" (sum up the page); a click sends one. Or type your
own: <kbd>↩</kbd> sends, <kbd>⌥↩</kbd> starts a new line. While Claude answers,
the send button becomes **Anhalten** (Stop).

In split view, the chat sits to the right of all sides and belongs to the tab
you opened it on. There is no page chat in private windows, and in Little
OpenArch <kbd>⌘E</kbd> only beeps: move the page into the main window with "In
Space öffnen" first.

## Ask about a selection

Select text on the page and press <kbd>⌘E</kbd>, or right-click it and choose
**Claude fragen** (Ask Claude), the first item of the menu. The chat opens with
the text above the field, under **Auswahl** (Selection). It goes along with
your next message as the focus of the question; in a new chat, the suggested
questions change to "Erkläre die Auswahl" (explain the selection) and
"Übersetze die Auswahl ins Deutsche". The × beside it leaves it out.

With the chat open, select other text and press <kbd>⌘E</kbd> again: that text
becomes the focus instead. With nothing new selected, <kbd>⌘E</kbd> closes the
chat.

## Add other tabs with @

Type @ in the field. A list **Tab dazunehmen** (Add a tab) shows up to eight of
the space's tabs, under the line and pinned, whose title or address contains
what you type after the @. <kbd>↑</kbd> and <kbd>↓</kbd> move through it,
<kbd>↩</kbd> or <kbd>Tab</kbd> picks a tab, <kbd>Esc</kbd> closes the list.

A picked tab appears in your text by its name and as a chip above the field;
the chip's × leaves it out again. Its text goes along with the next message, so
you can compare several pages or sum them up together. A tab that is asleep or
was never opened loads in the background first.

## What goes along

| What | When | Up to |
| --- | --- | --- |
| The page: address, title and text | With the first message, and again once the tab shows a different page | 60,000 characters |
| The selection | With the next message after you chose it | 20,000 characters |
| Each tab named with @ | With the next message | 30,000 characters each |

The text is what the page shows: its article or main area when that holds more
than 500 characters, otherwise the text of the whole page. Longer text is cut
off at the limit. A page that is still loading is waited for, up to about 15
seconds; if its text cannot be read, Claude is told so. Small chips under each
of your messages show what went with it.

OpenArch reads the page through Chrome's DevTools protocol inside its own tab,
not through an open port, so this works without [AI control](/ai/ai-control/).

## Acting in the browser

The chat can also work in your tabs, signed in as you: ask it to fill in a form, click through a page, open something in a new tab or delete what a page lists. It uses OpenArch's own browser tools:

| Tool | What it does |
| --- | --- |
| `list_tabs` | Lists the space's tabs |
| `read_page` | Reads a tab's text and numbers its links, buttons and fields |
| `screenshot` | Takes a picture of the visible part of a tab, so Claude sees the layout, images and charts too |
| `open_tab` | Opens an address in a new tab next to the page, in the background |
| `navigate` | Opens an address in a tab |
| `click` | Clicks an element by its number, as you would with the mouse |
| `type` | Types into a field, or chooses an option in a menu |
| `go_back` | Goes back a page |

Without a tab id they work on the page the chat is about. Reading, and taking a picture, needs no permission. The first time Claude wants to act (open, click, type, go back), the chat shows **Browser-Steuerung nicht erlaubt** with **Erlauben und weiter**. Once allowed, it may act for the rest of this chat.

These tools are part of OpenArch: they need no [AI control](/ai/ai-control/), no open DevTools port and no Node. Each chat reaches them at an address on `127.0.0.1` with a secret of its own, which only its own Claude Code runs get.

:::caution
A page can hide instructions for Claude in its text. Claude is told to act only when you ask it to, never because a page says so, but read what it proposes, and allow acting only in chats where you asked for it.
:::

## Answers and links

Answers stream in as they are written and show as Markdown: code in boxes,
headings in bold, lists with dots. Links, and addresses written out in the
text, open as new tabs next to the page. Claude is asked to answer in the
language you write in, to keep it short, and to say so when the answer is not
in the page.

If Claude Code is missing on the Mac, the chat says so and how to install it.

## Close, come back, start over

<kbd>⌘E</kbd>, <kbd>Esc</kbd> in the chat, or the × in its header
(**Schließen (⌘E)**) closes the panel. The chat keeps its conversation:
<kbd>⌘E</kbd> brings it back as it was, and a follow-up question continues the
same conversation, so Claude still knows the page and its earlier answers.

The pencil in the header, **Neuer Chat zu dieser Seite** (New chat about this
page), clears the chat and starts a new conversation.

Each tab has its own chat, and it lasts as long as the tab. Closing the tab, or
"Heute aufräumen", ends it. Page chats are never saved, so quitting OpenArch
ends them too.

## Where it runs

Every message is one run of Claude Code in a folder of OpenArch's own,
`~/Library/Application Support/OpenArch/PageChats`, away from your files.
Claude Code keeps its usual transcript of these sessions in `~/.claude/projects`,
as it does for every session; the [Agents](/ai/agent-chats/) view leaves them
out.

Your Claude Code skills and slash commands run in this chat too, from the
command bar: see [Skills in the command bar](/ai/skills/).

## What Claude gets and what it may do

Claude gets the text described above and your message, and nothing else from
the browser: no cookies, no screenshots, no other tabs unless you name them
with @. OpenArch adds a short note that explains the chat and these parts of
the message.

The chat runs with Claude Code's default permissions. A run cannot stop to ask
you, so anything that would need your approval is refused and shows in the chat
as "… nicht erlaubt" with a button **Erlauben und weiter** (Allow and continue),
which allows it for this chat. The chat's browser tools read without asking;
acting in the browser needs that button once per chat (see
[Acting in the browser](#acting-in-the-browser)).

Each tool Claude used shows as a row in the chat. Click it to see the whole
command or input and what came back.

How the runs work in detail: [How OpenArch talks to Claude](/ai/how-it-works/).

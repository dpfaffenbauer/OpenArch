---
title: "Claude and ChatGPT on the web"
description: "Type a sentence or a question in the command bar and it opens as a new chat on claude.ai or chatgpt.com, signed in with your own account there."
---

The command bar takes questions as well as addresses. Type a sentence or a
question, press <kbd>↩</kbd>, and a new chat opens on Claude or ChatGPT on the
web with your text in it. It is the website itself, signed in as you, so it
uses your account and subscription there. There is no API key to set up, and
Claude Code is not involved.

## Ask

1. Press <kbd>⌘T</kbd> and type a question, such as "How long does sourdough
   keep in the fridge?"
2. The first row shows your text with "Claude fragen" (Ask Claude) below it.
   Press <kbd>↩</kbd>.
3. A new tab opens on claude.ai with a new chat.

A few words stay a search. Then the search engine is the first row and the
chat the second, one <kbd>↓</kbd> away.

## How it chooses

| You type | First row | Second row |
| --- | --- | --- |
| Text that ends with "?" or has five words or more | the chat | the search |
| Fewer words, no "?" | the search | the chat |
| Something that looks like an address | the address | no chat |

The chat opens like any other result of the command bar: in a new tab from
<kbd>⌘T</kbd>, in place of the page from <kbd>⌘L</kbd>.

## Choose the service

**Settings › KI › Fragen in der Befehlsleiste › Fragen an** (Questions in the
command bar › Ask):

| Choice | Opens |
| --- | --- |
| **Claude** (the default) | a new chat on claude.ai |
| **ChatGPT** | a new chat on chatgpt.com |
| **Aus** (Off) | nothing; the command bar shows no chat row |

## What is sent

Only the text you typed goes to the service you chose, as part of the address:
`https://claude.ai/new?q=…` or `https://chatgpt.com/?q=…`. Nothing of the page
in front or of your other tabs goes along.

As with anything typed in the command bar, the text also goes to your search
engine for suggestions while you type, unless you turned off **Settings ›
Allgemein › Suchen › Suchvorschläge** (search suggestions).

The chat is an ordinary page in the space's profile, so it is signed in
wherever that profile is signed in to claude.ai or chatgpt.com. In a space with
another profile, or in a private window, the site may ask you to sign in first.

## Other ways to ask

Claude, ChatGPT and Perplexity are also among the site searches: type `cl`,
`gpt` or `pp`, press <kbd>Tab</kbd>, then your question. They are edited with
the other site searches under **Settings › Allgemein › Seitensuche**; see
[The command bar](/browsing/command-bar/).

To ask about the page you are reading, use the
[chat with the page](/ai/page-chat/) (<kbd>⌘E</kbd>) instead. To have Claude
Code work in a folder on your Mac, choose "Agent-Chat starten" under the
same text, if [agent chats](/ai/agent-chats/) are on.

## What Claude gets and what it may do

Claude (or ChatGPT) gets your question and nothing else. The chat then runs on
the website like any chat you start there, under that site's rules and your
account's settings; OpenArch does not take part in it.

The other AI features reach Claude differently, through Claude Code on your
Mac: [How OpenArch talks to Claude](/ai/how-it-works/).

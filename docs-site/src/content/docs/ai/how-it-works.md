---
title: "How OpenArch talks to Claude"
description: "OpenArch has no AI of its own and no API key: it runs Claude Code on your Mac, on your own login. What it starts, what Claude gets and where it all ends up."
---

OpenArch contains no language model, and it holds no API key. Its AI features take one of two routes:

- **Claude Code on your Mac.** [Chat with the page](/ai/page-chat/), [skills](/ai/skills/), the [Morning Brief](/ai/morning-brief/), [tidying tabs](/ai/tidy-tabs/) and [agent chats](/ai/agent-chats/) start the `claude` command line tool in the background and read its answers. Claude Code runs on your login, the same one it uses in Terminal, and the usage counts against your Claude plan.
- **Claude or ChatGPT on the web.** A question typed into the command bar can open a new chat on claude.ai or chatgpt.com in a tab, where you are signed in already. That route is a web page like any other; see [Claude and ChatGPT on the web](/ai/web-chats/).

The rest of this page is about the first route.

## What you need

1. Claude Code, from [claude.ai/code](https://claude.ai/code).
2. One login: run `claude` in Terminal once and sign in.

Nothing needs setting up in OpenArch. **Settings › KI** shows whether OpenArch found `claude`, and where.

:::note
OpenArch uses whatever Claude Code is set up with. Usually that is your Claude subscription. If you set Claude Code up with an API key instead, that key is used, and its usage is billed by the API.
:::

## How OpenArch finds `claude`

Apps on the Mac do not see the `PATH` your shell sets up. So the first time an AI feature runs, OpenArch asks your login shell, the way Terminal starts it, where `claude` is (`command -v claude`) and which `PATH` it has. It takes both over and remembers them until OpenArch quits.

If the shell does not answer within ten seconds, OpenArch looks in the usual places: `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude` and `/usr/local/bin/claude`.

## What happens when you send something

Every message starts `claude` once, in print mode:

```sh
claude -p --output-format stream-json --verbose …
```

1. **The message goes in.** OpenArch writes what Claude is to get into a temporary file and hands it to `claude` as its input. A file, not a pipe, so a long page cannot block it.
2. **The answer streams out.** Claude Code reports every step as a line of JSON: the text as it grows, each tool it uses, each tool it was refused, and at the end the result. OpenArch shows them as they come.
3. **The conversation continues.** Claude Code gives every conversation a session ID. The next message in the same chat starts `claude` again with `--resume <session>`. Claude Code then carries on with everything said so far, as if you had typed it in Terminal.

What else `claude` is started with depends on the feature. The folders it runs in are in `~/Library/Application Support/OpenArch`:

| Feature | Runs in | Started with |
| --- | --- | --- |
| Chat with the page, skills | `PageChats` | `--permission-mode default`, `--resume`, `--append-system-prompt` (it is a chat beside a page) and, with [AI control](/ai/ai-control/) on, `--mcp-config` |
| Agent chats | a folder you choose | the chat's permission mode, the tools you allowed (`--allowedTools`), `--resume`, `--append-system-prompt` and, with AI control on, `--mcp-config` |
| Morning Brief | `MorningBrief` | `--permission-mode default` and only reading tools (`--allowedTools`) |
| Tidy tabs | `TabTidy` | `--permission-mode default` |

The page chat, the brief and tidying run in folders of OpenArch's own, away from your files and projects. Agent chats work in the folder you give them, because working on your files is what they are for.

The model is the one Claude Code uses by default. OpenArch does not choose one.

## What Claude gets

Claude gets only what the feature puts into the message, and nothing from your browser beyond that: no cookies, passwords, history or other tabs.

| Feature | What goes to Claude |
| --- | --- |
| Chat with the page | The page's address, title and readable text (up to 60,000 characters), text you selected on it (up to 20,000), tabs you named with @ (up to 30,000 characters each), and what you wrote. The page goes along again only once the tab shows a different one. |
| Skills | The same as the page chat, and which skill to run. Claude Code reads the skill itself. |
| Morning Brief | The brief's prompt and today's date. Claude fetches the rest itself, through your connectors. |
| Tidy tabs | The titles and addresses of the space's today tabs. No page content. |
| Agent chats | What you write. The agent reads and works on files in its folder through Claude Code's tools. |

OpenArch reads a page's text from the open tab: it asks the page for the readable text of its main content, or of the whole page when the main content is short. A tab that is asleep or not loaded has no text to give.

## What Claude may do

`claude -p` runs without a terminal, so Claude Code cannot stop and ask you whether it may use a tool. What happens instead depends on the permission mode:

- **`default`**, used by the page chat, skills, the brief, tidying and agent chats set to **Nachfragen** (ask): Claude Code does what needs no permission, such as reading files in its folder. It refuses everything else. In a chat, a refused tool shows up with a button to allow it, and the next message may use it.
- **`acceptEdits`**, for agent chats set to **Dateien bearbeiten**: it also changes files without asking, but no commands.
- **`bypassPermissions`**, for agent chats set to **Alles erlauben**: it changes files and runs commands without asking.

The **Morning Brief** gets a narrower set. Before it writes, OpenArch starts `claude` once only to learn which tools it has, and stops it as soon as Claude Code lists them, before any question reaches the model. Connectors from claude.ai report their tools a moment later, so OpenArch asks up to three times. Then it allows only the connector tools whose names say they read, such as `get`, `list`, `search`, `read` or `find`. Anything whose name says it creates, sends, changes or deletes is left out. A mail that tells Claude to forward something therefore finds no tool to do it with.

:::caution
With [AI control](/ai/ai-control/) on, chats also get OpenArch's browser tools, which act in your real tabs, signed in as you. They are tools like any other: in **Nachfragen** mode, Claude has to be allowed to use them first.
:::

## Where conversations are kept

- **Claude Code's own transcripts** go to `~/.claude/projects/`, one folder per working folder, as for any Claude Code session. That includes the brief's short tool checks. The [Agents](/ai/agent-chats/) view reads these transcripts.
- **Agent chats** also keep their messages in `~/Library/Application Support/OpenArch/Agents`.
- **Page chats** live as long as their tab. When the tab closes, the chat is gone from OpenArch. Claude Code's transcript stays.
- **Morning Briefs** are saved as one HTML page per day in `~/Library/Application Support/OpenArch/MorningBrief`.

## Where your data goes

OpenArch itself sends nothing to Anthropic or anyone else. What Claude gets goes from Claude Code to Anthropic, under the terms of your Claude account, the same as anything you type into Claude Code in Terminal. Connectors (MCP servers) that Claude Code has get what Claude sends them.

## When it does not work

| What you see | What to do |
| --- | --- |
| "Claude Code wurde auf diesem Mac nicht gefunden" | Install Claude Code from claude.ai/code, run `claude` once in Terminal, then send again. |
| A message about logging in | Run `claude` in Terminal and sign in again (`/login`). |
| "unknown option" in the error | Your Claude Code is older than OpenArch expects: run `claude update`. |
| The brief or tidying gives up after a while | They wait 15 and 4 minutes. Try again; if it keeps happening, run the same in Terminal to see what Claude Code says. |

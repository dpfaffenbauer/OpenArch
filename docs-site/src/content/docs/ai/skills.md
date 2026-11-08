---
title: "Skills in the command bar"
description: "Your own Claude Code skills and slash commands show up in the command bar and run on the page in front, in the page's chat."
---

If you have written skills or slash commands for Claude Code, the command bar
offers them on any page. Choosing one runs it on the page in front, in that
page's [chat](/ai/page-chat/), with the page as its input: a skill that turns
an article into notes, or a command that checks a pull request, works on
whatever you are reading.

## Find a skill

With a tab in front, open the command bar (<kbd>⌘T</kbd> or <kbd>⌘L</kbd>) and
type the beginning of a skill's name, with or without a leading /. Its row
shows:

- the name with a slash, such as `/summarize`
- "Skill" or "Befehl" (command), followed by its description
- **Auf diese Seite anwenden** (Apply to this page) on the right

A name matches when it starts with what you type; from three letters on, also
when it contains it anywhere. A space ends the match, so you cannot type words
after the name here.

A / alone lists your skills and commands in alphabetical order. Typed with a
/, they come first in the results, up to six; without it, up to three come
after tabs and commands.

The rows only appear while a tab is in front: not over an agent chat, not with
nothing open, and not in private windows.

## What OpenArch reads

OpenArch looks in two folders of Claude Code's:

| Folder | What counts | Name | Description |
| --- | --- | --- | --- |
| `~/.claude/skills` | each folder with a `SKILL.md` | `name` in its frontmatter, else the folder's name | `description` in its frontmatter |
| `~/.claude/commands` | every `.md` file, subfolders included | the file's name without `.md` | `description` in its frontmatter, else its first line of text |

A command with the same name as a skill is left out. Descriptions are
shortened to 140 characters.

OpenArch reads only names and descriptions, never runs anything itself, and
reads the folders again at most every ten seconds, so a new skill shows up
without restarting OpenArch. Skills in a project's own `.claude` folder and
skills from plugins are not listed.

If OpenArch's environment has `CLAUDE_CONFIG_DIR`, it reads that folder
instead of `~/.claude`.

:::note
`CLAUDE_CONFIG_DIR` set only in your shell's configuration (`.zshrc` and the
like) does not reach OpenArch when you start it from the Dock or Finder. It
then reads `~/.claude`.
:::

## How a skill runs

Choose the row. The page's chat opens beside the page and sends Claude Code a
message that starts with `/` and the skill's name, followed by:

- the page: its address, title and text, as for a question in the chat
- the selection and the tabs named with @, if the chat has any
- what is in the chat's field, or else "Wende das auf diese Seite an." (Apply
  this to this page.)

Claude Code runs it as the skill or command of that name, the way it would in
the terminal, with the rest of the message as its input. The chat shows your
message as `/name`, with chips for what went along, and the answer streams in
below. Afterwards it is an ordinary page chat: ask follow-up questions, or run
another skill.

A skill always gets the page, even when the chat already had it. If the chat is
still answering, choosing a skill only brings up the chat; choose it again once
the answer is there.

:::tip
To run a skill on part of a page, select the text and press <kbd>⌘E</kbd>
first, so the selection becomes the chat's focus, then choose the skill from
the command bar. Words typed in the chat's field before you choose the skill go
along as its input.
:::

## What Claude gets and what it may do

Claude gets the same as for a question in the page chat: the page, the
selection, the tabs you named, and your words. Claude Code reads the skill's
own file itself. The skill runs in the page chat's folder,
`~/Library/Application Support/OpenArch/PageChats`, not in a project of yours.

It runs with Claude Code's default permissions. A tool the skill would need
your approval for is refused and shows in the chat with **Erlauben und weiter**
(Allow and continue), which allows it for this chat.

How the runs work in detail: [How OpenArch talks to Claude](/ai/how-it-works/).

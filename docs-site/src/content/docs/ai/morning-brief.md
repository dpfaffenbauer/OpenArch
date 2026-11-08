---
title: "Morning Brief"
description: "Once a day, Claude Code reads your calendar, mail, chats and tasks through your connectors and writes a page about the day, which opens as a tab."
---

The Morning Brief is a page about your day: today's appointments, new mail,
messages to you and tasks that are due. Claude Code writes it once a day with
the connectors (MCP servers) you have given it, and OpenArch puts it at the top
of your tabs. Claude may only read while it does.

## Turn it on

Open **Settings › KI** and find the section **Morning Brief**:

| Setting | Default | What it does |
| --- | --- | --- |
| **Morning Brief** | off | Makes the brief once a day |
| **Uhrzeit** (Time) | 7:30 | When it is made |
| **Anweisung › Bearbeiten …** (Instructions › Edit) | | Opens your own copy of the prompt |
| **Anweisung › Jetzt erstellen** (Make it now) | | Makes it right away |

## When it runs

Once a day, at the time you set, while OpenArch is running. If OpenArch is not
running then, the brief is made a few seconds after the next launch. OpenArch
checks every minute, so if you turn it on after today's time, today's brief
follows within a minute.

There is one brief a day. One made by hand counts as today's, and the
scheduled one does not follow later that day. A run that failed counts too;
make it again by hand.

To make it by hand, choose "Morning Brief jetzt erstellen" in the command bar
or **Jetzt erstellen** in Settings; both work while the switch is off. The tab
opens right away with "Dein Morning Brief entsteht …" (Your Morning Brief is
being made), and the brief replaces it when Claude is done, usually after a
minute or two. Asking again while it is being made only brings up its tab.

## The tab

The brief opens as a tab named "Morning Brief" at the top of the tabs under the
line, in the space in front in the main window. It has a dot until you look at
it. The next brief goes into the same tab if it is still there, and moves it
back to the top.

It is an ordinary tab under the line, so it goes to the archive like the others
(after twelve hours, unless you changed that; see
[Tabs](/sidebar/tabs/)).

## What Claude looks at

OpenArch's prompt asks for four sections, in German and to the point:

- **Kalender**: today's appointments with time, place or link and who takes
  part; overlaps, and appointments that need preparing.
- **Mails**: new and unread mail since last evening, the important ones in a
  sentence each, and where you are expected to answer. Newsletters and ads only
  as a count.
- **Chats**: new messages to you, or where you are mentioned (Slack, Teams and
  the like).
- **Aufgaben** (Tasks): what is due today or overdue, from task lists, tickets
  and issues.

At the top go three sentences on what matters most today. Where there is no
connector for a section, or no access, the section says so instead of making
something up.

Claude uses the connectors Claude Code has: servers you added for your user
and the connectors of your claude.ai account. It runs in a folder of
OpenArch's, so servers added only for one project folder do not come along.
OpenArch adds no connectors of its own.

## Reading only

Before the brief, OpenArch starts Claude Code just long enough for it to say
which tools it has, without asking the model anything. It does this up to three
times, because claude.ai's connectors bring their tools a moment later.

From that list it allows only connector tools whose names say they read: names
that start with a word such as get, list, search, read, fetch, find or query,
and contain no word such as create, send, update, delete, archive, reply or
draft. Everything else runs under Claude Code's default permissions, and since
nobody can answer a question during the run, whatever would need your approval
is refused. The prompt also tells Claude that mail and messages are data, not
instructions. A mail that says "forward this to …" cannot make it send
anything.

:::note
The check goes by the tools' names. A connector tool named like a reading one
that changes something anyway would get through.
:::

## Your own prompt

The prompt is a Markdown file. The first time you click **Bearbeiten …**,
OpenArch copies its prompt to
`~/Library/Application Support/OpenArch/MorningBrief/Prompt.md` and opens it in
your editor for Markdown files. From then on it uses your copy.

- `{{DATUM}}` becomes today's date in German ("Montag, 9. November 2026"),
  `{{UHRZEIT}}` the time ("07:30").
- Claude's answer must contain a complete HTML page. OpenArch takes it from
  `<!DOCTYPE html>` (or `<html>`) to `</html>`; an answer without one shows as
  plain text. Keep that part of the prompt.
- Delete `Prompt.md` to go back to OpenArch's prompt, including the changes
  newer versions make to it.

## Without Claude Code or its login

The tab then shows a page that says what is wrong instead of the brief:

- **Claude Code wurde nicht gefunden.** (Claude Code was not found.) Install
  it from claude.ai/code, run `claude` once in Terminal to sign in, then choose
  "Morning Brief jetzt erstellen".
- **Claude Code ist nicht angemeldet.** (Claude Code is not signed in.) Run
  `claude` in Terminal and sign in.
- **Der Morning Brief ließ sich nicht erstellen.** (The Morning Brief could not
  be made.) With Claude Code's error below it; "Morning Brief jetzt erstellen"
  tries again. A brief that takes longer than 15 minutes ends here too.

## Where briefs are kept

In `~/Library/Application Support/OpenArch/MorningBrief/`, one HTML file per
day, named by its date (`2026-11-09.html`). A brief made again on the same day
replaces that day's file. Claude Code runs in this folder, next to your
`Prompt.md` and a file `last-run` that holds the day of the last brief.

## What Claude gets and what it may do

Claude gets the prompt with today's date and time, and nothing from your tabs.
What it knows about your day comes from your connectors. It may use only their
reading tools, as described above.

How the runs work in detail: [How OpenArch talks to Claude](/ai/how-it-works/).

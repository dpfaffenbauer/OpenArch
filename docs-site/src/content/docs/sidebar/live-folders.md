---
title: "GitHub live folders"
description: "Pinned folders that fill themselves with your open pull requests, review requests or issues from GitHub, with each pull request's checks."
---

A live folder is a pinned folder that fills itself from GitHub, as Arc's did: your open pull requests, the ones waiting for your review, or the issues assigned to you. It refreshes every five minutes, uses the GitHub login of its space, and shows whether each pull request's checks passed. No token or setup is needed.

## Make one

Click **+** at the right of the space bar, then **GitHub-Live-Ordner**, and pick one:

| Folder | What it lists | GitHub search |
| --- | --- | --- |
| **Meine Pull Requests** | Open pull requests you wrote | `is:pr is:open author:@me archived:false` |
| **Reviews für mich** | Open pull requests that ask for your review | `is:pr is:open review-requested:@me archived:false` |
| **Meine Issues** | Open issues assigned to you | `is:issue is:open assignee:@me archived:false` |

The folder appears at the top of the space's pinned tabs and fills right away. Its icon has a small pull request or issue symbol inside. You can rename it, move it and open or close it like any folder.

Each entry is a tab with the pull request's or issue's title, in the order GitHub lists them. Click one to open it.

## Signed in as the space

OpenArch asks github.com the way the site asks itself, with the cookies of the space's [profile](/sidebar/spaces/#profiles). So the folder shows what you see on GitHub when you are signed in there in that space. A work space and a private space with different profiles can each have live folders for a different GitHub account.

If that profile is not signed in to GitHub, the folder shows **Bei GitHub anmelden** (sign in to GitHub). Click it to open GitHub's sign-in page, sign in, and the folder fills at its next refresh.

## Refreshing

Every live folder refreshes when OpenArch starts and then every five minutes. To refresh one now, rest the pointer on it and click the round arrow, or right-click it and choose **Jetzt aktualisieren**.

What changes in the folder:

- New pull requests or issues appear.
- One that was closed or merged disappears, unless its page is open at that moment.
- Tabs that stay keep their pages, so a review you are reading does not reload.

:::caution
The folder holds what GitHub returns. A tab you drag into a live folder yourself is gone after the next refresh, unless its page is open then.
:::

When the folder is empty, it says **Keine offenen Pull Requests** or **Keine offenen Issues**. When GitHub cannot be reached, it shows **GitHub nicht erreichbar, erneut versuchen**; click it to try again.

## Checks on pull requests

In folders of pull requests, each pull request shows its CI checks at the right of its row, the way GitHub shows them next to the newest commit:

| Mark | Meaning |
| --- | --- |
| Green check | All checks passed. |
| Red cross | At least one check failed. |
| Orange dotted circle | Checks are still running. |

Rest the pointer on the mark for GitHub's own summary, such as "9 / 15 checks OK". The [tab preview](/sidebar/tabs/#tab-previews) shows the same summary under the address. A pull request without checks has no mark. The marks refresh with the folder.

While you rest the pointer on a row, its buttons take the place of the mark.

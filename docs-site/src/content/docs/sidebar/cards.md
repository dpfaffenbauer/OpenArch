---
title: "Player, meetings and screen sharing"
description: "The cards at the bottom of the sidebar: a player for media in other tabs and Spotify, your next meeting with a join button, and what you are sharing in a call."
---

The bottom of the sidebar, above the space bar, shows small cards for what is going on outside the page in front: your next meeting, a screen you are sharing, and media playing in another tab or in Spotify. Each appears only while there is something to show. From top to bottom they are the meeting, screen sharing and the player.

When an update of OpenArch is ready, a card **Update bereit** joins them; see [Install and update](/start/install/).

## The player

When audio or video plays in a tab that is not on screen, a small player shows it: the cover, the title and the artist, and four bars that move while it plays. It works for any site that plays through a normal audio or video element: music, podcasts, videos. The title, artist and cover come from what the page tells the browser about it (its Media Session); without that, you see the tab's title and the site.

Rest the pointer on the player to open its controls:

- A position bar to click or drag, with the time played and the time left. A live stream shows **LIVE** instead.
- Back: the page's previous track, or the start if the page has none.
- Play and pause.
- Next: the page's next track, when the page has one.
- The speaker, to mute or unmute the tab.
- **↗**, to go to the tab. A click on the cover or title does the same.
- For a video, a button for picture-in-picture (**Bild-in-Bild**).
- **×** closes the player and pauses what plays. The player comes back when the page plays again.

Which tab the player shows: one whose sound is on (a muted video that plays by itself on a page does not count), playing before paused, and of those the one you used last. A paused tab can stay in the player; **×** puts it away.

### Picture-in-picture when you leave a tab

When you switch away from a tab whose video plays with sound, the video keeps playing in a small picture-in-picture window. Coming back to the tab ends it. Turn this off under **Settings › Allgemein › Tabs › Bild-in-Bild beim Tab-Wechsel**.

A muted video that plays by itself, such as an ad or a page background, does not float, and neither does sound without a picture. Calls float too; see [Calls in picture-in-picture](#calls-in-picture-in-picture).

### Spotify

The player also shows what the Spotify app on your Mac plays. Spotify tells every app on the Mac when its track or state changes, so this needs no permission. If Spotify is already playing when OpenArch starts, the player appears with the next change, or right away once you have allowed OpenArch to control Spotify.

The first time you press one of the player's buttons for Spotify, macOS asks whether OpenArch may control Spotify. Allow it, and play, pause, back, next and the position bar control Spotify. **↗** brings Spotify to the front. The cover comes from Spotify's public page for the track.

If a tab and Spotify both have something, what is playing comes first, and a tab before Spotify.

## The next meeting

Turn on **Settings › Allgemein › Kalender › Nächstes Meeting in der Sidebar**. macOS then asks whether OpenArch may read your calendars. If you said no, the setting shows **Zugriff erlauben …**, which opens **System Settings › Privacy & Security › Calendars**.

The card shows a meeting from any calendar in the Calendar app: its title, when it starts (**in 5 Min.**, **beginnt jetzt**) or how long it still runs (**läuft, noch 20 Min.**), and **Beitreten** (join) when the invitation has a call link. Rest the pointer on **Beitreten** to see the link. From two minutes before the start, the icon and the button take on the accent color.

Which meeting it shows:

- If one starts within the next ten minutes, that one, even while another still runs.
- Otherwise one that is running.
- Otherwise the next one that starts within the hour. Further ahead, there is no card.

Events count as meetings when they have a call link or someone else is invited. All-day events, cancelled events and events you declined do not count.

The link is the first one in the event's URL, location or notes that goes to Google Meet, Zoom, Microsoft Teams, Webex, Whereby, Jitsi Meet (meet.jit.si), GoTo Meeting or Amazon Chime.

About a minute before a meeting starts, a message over the page says so, with its title: **„Weekly“ beginnt gleich**. It comes once per meeting. If OpenArch is in the background, its Dock icon bounces.

### Joining

Click **Beitreten**. The call opens in a new folder under the line, named after the meeting with 📹 in front, as in Dia. Links you open from the call land in that folder too, so the documents of the meeting stay together. Clicking **Beitreten** again goes back to the call's tab.

## Screen sharing

When a page shares your screen, a window or a tab, as video calls do, a card with a red border says what is shared: **Du teilst deinen Bildschirm**, **Du teilst ein Fenster**, **Du teilst einen Tab**, or the title of the shared tab. Below that is the site that shares it.

- Click the card to go to the shared tab, or to the call if no tab is shared.
- If a tab is shared and the call is not in front, the camera button goes back to the call (**Zum Tab, der teilt**).
- **■** ends the sharing (**Teilen beenden**), as Chrome's own stop button would; the call notices.

In the sidebar, the tab that shares carries a red dot (**Teilt gerade**), and the tab being shared a red screen symbol (**Wird gerade geteilt**).

OpenArch knows which tab is shared because its built-in extension gives every page a name the sharing page can read. A page that sets its own name for this (Google Slides does, for Meet) keeps it; the card then says only **Du teilst einen Tab**.

## Calls in picture-in-picture

When you leave a tab that is in a call, the call keeps going in a small floating window, as in Arc. A tab counts as in a call while its page uses your camera or microphone. Leaving means switching to another tab or space, minimizing the window, or the window going out of sight behind other windows or on another desktop.

- **Google Meet**, and any site that offers a picture-in-picture of its own, opens its own window: Meet's tiles with its buttons for the microphone, the camera and leaving.
- **Other calls** (Zoom, Microsoft Teams or Slack huddles in the browser) get OpenArch's window: the call's videos in a grid, and buttons for **Mikrofon**, **Kamera** and **Auflegen** (hang up). **‹** (**Zurück zum Tab**) goes back to the call. The buttons use the site's own controls where the page offers them. Otherwise **Mikrofon** and **Kamera** switch your microphone or camera off in the call, and **Auflegen** clicks the site's leave button, or ends your camera and microphone if OpenArch finds none.

Coming back to the tab closes the window: it fades out and the call is back in the page. Closing the window does not end the call.

The window opens at the bottom right of the screen. Drag it elsewhere and the next one opens there. It stays above other apps and shows on every desktop.

Turn this off under **Settings › Allgemein › Tabs › Anrufe in Bild-in-Bild**. To keep one site's videos and calls in their tab, turn off **Bild-in-Bild beim Verlassen** in its [Site Control Center](/browsing/site-controls/), or add the site under **Settings › Allgemein › Tabs › Ohne Bild-in-Bild** (addresses separated by commas).

A tab in a call never [goes to sleep](/sidebar/tabs/#sleeping-tabs).

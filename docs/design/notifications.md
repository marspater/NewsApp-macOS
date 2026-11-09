# Notifications

How a story notification looks and behaves, and when it may interrupt. Which stories become banners, with their scores, lanes and limits, is in the [delivery rules](../notifications.md) (#665). [DESIGN.md](DESIGN.md) section 8.7 points here, and the mechanics are in [implementation-notes.md](implementation-notes.md).

The app draws every banner; the proof of concept has graduated (#926).

## Interruption policy

- **One delivery path.** While News is running, the app draws every banner in every window state: active, behind another app, hidden, minimized or with no window open. The app never delivers through the notification center, so a story cannot arrive twice. Banners are therefore not kept in Notification Center history. Notifications an earlier build left there still act on a click.
- **Permission, settings and Focus.** Every banner stays subject to the app's notification permission and alert style in System Settings, the previews setting, and News's own notification mode (Full, Minimal, Private). It also stays subject to Focus. The notification center remains only to ask permission and read these settings, which is not delivery.
  - Permission not granted, alerts off, or the alert style None: no banner.
  - The Banners style leaves after 6 s; the Alerts style stays until closed.
  - Show Previews Never: the Private banner for the story (no publisher, headline, summary or photo, no actions); a click still opens the story.
  - A Focus on: no banner, read through `INFocusStatusCenter`. While the reader has not allowed Focus status, Focus is unknown and banners show.
- **Nothing is lost.** A story held back by any of these stays in Today and Unread. A banner held back is not recorded as delivered, so it counts toward no limit and announces no event.
- **One banner per story.** Reports of one event share a thread, so a second publisher joins the first banner instead of stacking a second one beside it. Banners post one at a time. A banner with sound plays the reader's alert sound; one without is silent.
- **The Dock badge** counts stories worth attention (unread stories of today's Briefing and breaking stories since the last launch), never the whole unread library; zero hides it.
- **Privacy modes.** Private and Minimal show no headline, summary or image and make no remote image request.

## Presentation

The approved look, light and dark, is [`docs/mocks/story_banner_render.webp`](../mocks/story_banner_render.webp). It illustrates these rules; where it and this document disagree, this document wins.

- **Copy.** The headline is the title, the publisher the subtitle, the feed summary the body, in sentence case, with no label the data does not support ([DESIGN.md](DESIGN.md) section 17).
- **Surface.** A floating panel at the top right of the screen: app icon, publisher in the secondary color, headline on one line and up to three lines of summary on regular glass (`BannerSurface`).
- **Photo.** The story photo fills the trailing side edge to edge, top to bottom, clipped by the banner's own continuous corners and dissolving toward the text. The text shows at once and the photo joins when it loads.
- **Grouped and summary banners** are drawn the same way, without a photo. Minimal and Private banners show only "News Update" and their line.
- **Panel.** It never hides with the app (`canHide` is false) and outlives every window: hiding the app, minimizing or closing its windows takes no banner down.

## Behaviour

- It shows whenever News is running, whether or not a window is on screen.
- One banner at a time. It stays 6 s, and longer while the pointer is over it.
- A click opens the story and clears the banner, opening News's window when none is on screen; a banner without a story brings the window forward.
- On hover (always for an Alerts banner) it shows a close button and, on a story's banner, Save, Mark as Read and Open. The panel grows to hold them.
- Touch ([DESIGN.md](DESIGN.md) section 15): a sideways swipe of 60 pt or more closes the banner. VoiceOver offers Close, and on a story's banner Save and Mark as Read.
- A story whose banner sounds plays the reader's alert sound.
- It slides in from the trailing edge and fades only under Reduce Motion.
- It never takes focus, and VoiceOver hears it as an announcement.

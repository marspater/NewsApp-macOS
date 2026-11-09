# Notifications

How a story notification looks and behaves, and when it may interrupt. Which stories become banners, with their scores, lanes and limits, is in the [delivery rules](../notifications.md) (#665). [DESIGN.md](DESIGN.md) section 8.7 points here, and the mechanics are in [implementation-notes.md](implementation-notes.md).

The app-drawn banner shipped as a proof of concept. This document sets the behaviour it now has to reach, and **target** marks what the code does not do yet.

## Interruption policy

- **One delivery path.** While News is running, the app draws every banner in every window state: active, behind another app, hidden, minimized or with no window open. The app never delivers through the notification center, so a story cannot arrive twice. Banners are therefore not kept in Notification Center history. *Target:* the code still posts through the notification center while hidden or without a window, and files an entry beside the app-drawn banner while News is active.
- **Permission, settings and Focus.** Every banner stays subject to the app's notification permission and alert style in System Settings, the previews setting, and News's own notification mode (Full, Minimal, Private). It also stays subject to Focus. The notification center remains only to ask permission and read these settings, which is not delivery. *Target:* the app-drawn banner reads permission, alert style and previews today, and does not yet honour Focus.
- **Nothing is lost.** A story held back by any of these stays in Today and Unread.
- **One banner per story.** Reports of one event share a thread, so a second publisher joins the first banner instead of stacking a second one beside it. Banners post one at a time. The interruption level follows the triage score.
- **The Dock badge** counts stories worth attention (unread stories of today's Briefing and breaking stories since the last launch), never the whole unread library; zero hides it.
- **Privacy modes.** Private and Minimal show no headline, summary or image and make no remote image request.

## Presentation

The approved look, light and dark, is [`docs/mocks/story_banner_render.webp`](../mocks/story_banner_render.webp). It illustrates these rules; where it and this document disagree, this document wins.

- **Copy.** The headline is the title, the publisher the subtitle, the feed summary the body, in sentence case, with no label the data does not support ([DESIGN.md](DESIGN.md) section 17).
- **Surface.** A floating panel at the top right of the screen: app icon, publisher in the secondary color, headline on one line and up to three lines of summary on regular glass (`BannerSurface`).
- **Photo.** The story photo fills the trailing side edge to edge, top to bottom, clipped by the banner's own continuous corners and dissolving toward the text. The text shows at once and the photo joins when it loads.
- **Grouped and summary banners** are drawn the same way, without a photo.

## Behaviour

- It shows whenever News is running, whether or not a window is on screen.
- One banner at a time. It stays 6 s, and longer while the pointer is over it.
- A click opens the story and clears the banner, opening a window when none is on screen.
- It shows a close button on hover. *Target:* the close button needs a touch path ([DESIGN.md](DESIGN.md) section 15), such as a visible button after a tap on the banner.
- *Target:* Save, Mark as Read and Open move onto the banner, because the system banner that carried them goes away.
- A story whose banner sounds plays the reader's alert sound.
- It slides in from the trailing edge and fades only under Reduce Motion.
- It never takes focus, and VoiceOver hears it as an announcement.

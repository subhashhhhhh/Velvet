# Velvet

<!-- Written in ASD-STE100 Simplified Technical English style. -->

Velvet is a native YouTube client for macOS. It uses less memory than the YouTube website.

The YouTube website can use approximately 2 GB of memory. Velvet uses approximately 200–350 MB when it plays a 1080p video.

Velvet is a personal project. It is not related to YouTube or Google.

## 1. Features

### 1.1 Browse

- Home feed with your recommendations.
- Topic chips above the home feed. Velvet keeps each topic in memory until you refresh it.
- Search.
- History, Watch Later and Playlists.
- Channel pages.
- Live page with live streams and live chat.
- Shorts in a vertical player.
- A "Members only" label on members-only videos. A setting can hide these videos.

### 1.2 Watch

- Playback with mpv and hardware decoding.
- Quality selection, up to the best quality for your display.
- Resume from the last position.
- Captions: manual tracks, auto-generated tracks and auto-translated tracks.
- Chapters on the seek bar.
- SponsorBlock. It skips sponsor segments and other segments that you select.
- DeArrow. It replaces clickbait titles and thumbnails.
- Comments, with replies and GIFs.
- Like, dislike, Watch Later and Save to playlist.

### 1.3 Picture in Picture

The video moves to a Picture in Picture (PiP) window when:

- You go to a different Space.
- You scroll past the player.
- You go to a different page in Velvet.

Each of these behaviors has a setting.

### 1.4 System integration

- Now Playing in Control Center shows the video.
- Media keys and headphone buttons control playback.

## 2. Requirements

- macOS 27 or later.
- Xcode, to build the app.
- An internet connection. On the first start, Velvet downloads yt-dlp and a JavaScript runtime (deno).

## 3. Install

1. Clone the repository:

   ```sh
   gh repo clone subhashhhhhh/Velvet
   cd Velvet
   ```

2. Build and install the app:

   ```sh
   ./install.sh
   ```

   The script builds a Release version. It puts `Velvet.app` in `/Applications`.

3. Start Velvet.

NOTE: You can do the install procedure while Velvet runs. The new version starts when you start Velvet again.

## 4. Sign in

1. Click **Sign In** at the bottom of the sidebar.
2. Sign in to your Google account in the window that opens.
3. Velvet keeps the session cookies in `~/Library/Application Support`. Only your user account can read this file.

Velvet sends the cookies only to YouTube. Velvet does not send the cookies to yt-dlp for most videos. It sends them only when a video needs your account (for example, a members-only video).

## 5. Keyboard shortcuts

### 5.1 Player

| Key | Action |
|---|---|
| Space or K | Play or pause. |
| Left Arrow / Right Arrow | Go back 5 s / go forward 5 s. |
| J / L | Go back 10 s / go forward 10 s. |
| Up Arrow / Down Arrow | Increase / decrease the volume. |
| M | Mute or unmute. |
| F | Enter or exit fullscreen. |
| Esc | Exit fullscreen. |
| P | Start or stop Picture in Picture. |
| C | Show or hide captions. |
| , / . | Decrease / increase the speed. |
| 0 to 9 | Go to 0 % to 90 % of the video. |

### 5.2 App

| Key | Action |
|---|---|
| Command-R | Refresh the page. |
| Command-[ | Go back. |

## 6. Settings

Open the settings with Command-, (comma). The settings are in these categories:

- **General**: start page.
- **Feed**: card size, Shorts shelf, hide watched videos, hide members-only videos.
- **Playback**: quality, codec, autoplay, speed, captions, Picture in Picture behavior, hardware decoding, buffer.
- **SponsorBlock**: on or off, the skip notice, the action for each segment category, the server.
- **DeArrow**: titles, thumbnails, originals on hover.
- **Account**: sign in and sign out.
- **Advanced**: yt-dlp, the JavaScript runtime, tool updates, storage.

## 7. Known limits

- You cannot drag the timeline in the macOS PiP window. Use the ±10 s buttons. Other players have the same limit.
- Velvet does not have a Subscriptions page.
- YouTube changes its API frequently. A YouTube change can stop a feature. Update yt-dlp in the settings first.

## 8. Technology

- Swift 6 and SwiftUI.
- The YouTube InnerTube API for feeds, search, comments and account actions.
- yt-dlp to get the stream URLs.
- mpv (through MPVKit) for playback.

For information about the source code, refer to `CLAUDE.md`.

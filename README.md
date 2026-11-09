<!-- Written in ASD-STE100 Simplified Technical English style. -->

<p align="center">
  <img src="Velvet/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Velvet icon">
</p>

<h1 align="center">Velvet</h1>

<p align="center">
  A native YouTube client for macOS that uses little memory.<br>
  macOS 15 or later · Apple silicon and Intel · Free and open source (MIT)
</p>

---

The YouTube website in a browser can use approximately 2 GB of memory. Velvet uses approximately 200–350 MB when it plays a 1080p video. Velvet is a real Mac app: it has a sidebar, keyboard shortcuts, Picture in Picture, Now Playing and media keys.

Velvet uses your YouTube account. Your home feed, subscriptions, history, Watch Later and playlists are the same as on youtube.com.

Velvet is not related to YouTube or Google.

## 1. Install

### 1.1 Homebrew (recommended)

```sh
brew install --cask subhashhhhhh/velvet/velvet
```

### 1.2 Download

1. Download the disk image for your Mac from the [latest release](https://github.com/subhashhhhhh/Velvet/releases/latest):
   - Apple silicon (M1 or later): `Velvet-<version>-AppleSilicon.dmg`
   - Intel: `Velvet-<version>-Intel.dmg`

   To find which Mac you have, open the Apple menu › **About This Mac**. Look for **Chip** (Apple silicon) or **Processor** (Intel).
2. Open the disk image. Drag **Velvet** to **Applications**.
3. Start Velvet.

Apple does not notarize Velvet, because notarization needs a paid developer account. Thus macOS blocks the app the first time that you open a downloaded copy. To open it, do one of these steps:

- Open **System Settings › Privacy & Security**. Go to **Security** and click **Open Anyway**.
- Or, do this command in Terminal:

  ```sh
  xattr -cr /Applications/Velvet.app
  ```

The Homebrew install does not need this step.

### 1.3 Requirements

- A Mac with Apple silicon or an Intel processor.
- macOS 15 (Sequoia) or later.
- An internet connection. On the first start, Velvet downloads yt-dlp and a JavaScript runtime (Deno). Velvet needs these tools to play videos.

### 1.4 First start

On the first start, Velvet shows a short welcome. It has three steps: what Velvet is, sign in (you can skip it), and a few choices (SponsorBlock, DeArrow and upload notifications). During these steps, Velvet downloads yt-dlp and the JavaScript runtime. The progress shows at the bottom of the window. If you open a video before the downloads are complete, the player shows their progress and starts the video when they are complete.

## 2. Updates

Velvet updates itself. It checks GitHub one time each day. When a new version is available, **Settings › About** shows the release notes and an **Install and Relaunch** button. You can also select **Velvet › Check for Updates…**.

Before Velvet installs an update, it makes sure that the download is complete and that it has the same signature as the installed app. Velvet does not install a changed or replaced download. For more information, refer to [docs/signing.md](docs/signing.md).

Velvet also keeps yt-dlp and the JavaScript runtime up to date. YouTube changes frequently, and new versions of yt-dlp follow these changes.

## 3. Sign in and privacy

1. Click **Sign In** at the bottom of the sidebar.
2. Sign in to your Google account in the window that opens.

Velvet keeps your session cookies in a file in `~/Library/Application Support/com.subhash.Velvet`. Only your macOS user account can read this file. Velvet sends the cookies only to YouTube and Google.

Velvet does not collect data about you. It has no analytics and no telemetry. Velvet connects only to these services:

| Service | Why |
|---|---|
| YouTube and Google | Feeds, search, videos, comments, notifications and account actions. Velvet reads your search history from Google My Activity (you can turn this off). |
| GitHub | yt-dlp and runtime downloads, and the daily Velvet update check. |
| SponsorBlock and DeArrow | Skippable segments, and better titles and thumbnails. Velvet sends only the first characters of a hash of the video ID, so these services cannot see which video you watch. You can turn off each service. |

## 4. Features

### 4.1 Browse

- Home feed with your recommendations, and topic chips.
- Subscriptions, with the newest videos and Shorts from your channels.
- Search, with suggestions and your search history from all your devices.
- History, Watch Later, Playlists and Liked videos.
- Channel pages, with search inside the channel.
- Live streams with live chat.
- Shorts in a vertical player.
- Notifications from your account, with an optional macOS notification for new uploads.
- Continue Watching for videos in a series (Part 2, Episode 3, and so on). Velvet can put the next episode in the queue.
- A queue: add videos and play them one after the other.
- Filters: hide watched videos, members-only videos, promotions, and channels that post AI-generated videos.

### 4.2 Watch

- Playback with mpv and hardware decoding.
- Up to 4K, and HDR on displays that support HDR.
- Resume from the last position.
- Captions: manual tracks, auto-generated tracks and auto-translated tracks.
- Chapters on the seek bar.
- Theater mode.
- SponsorBlock: skip sponsor segments and other segments that you select.
- DeArrow: replace clickbait titles and thumbnails.
- Comments, with replies.
- Like, dislike, subscribe, Watch Later and Save to playlist.

### 4.3 Picture in Picture

The video can move to a Picture in Picture (PiP) window when:

- You go to a different Space or app.
- You scroll past the player.
- You go to a different page in Velvet.

Each of these behaviors has a setting.

### 4.4 System integration

- Now Playing in Control Center.
- Media keys and headphone buttons.
- Trackpad swipes to go back and forward.

## 5. Keyboard shortcuts

### 5.1 Player

| Key | Action |
|---|---|
| Space or K | Play or pause. |
| ← / → | Go back 5 s / go forward 5 s. |
| J / L | Go back 10 s / go forward 10 s. |
| ↑ / ↓ | Increase / decrease the volume. |
| M | Mute or unmute. |
| C | Show or hide captions. |
| R | Loop the video. |
| , / . | Decrease / increase the speed. |
| 0 to 9 | Go to 0 % to 90 % of the video. |
| Shift-N | Play the next video in the queue. |
| F | Enter or exit fullscreen. |
| T | Theater mode. |
| P | Start or stop Picture in Picture. |
| I | Go back to the page. The video continues in Picture in Picture. |

### 5.2 App

| Key | Action |
|---|---|
| Command-K or Command-F | Search. |
| Command-[ / Command-] | Go back / go forward. A two-finger swipe also operates. |
| Command-R | Refresh the page. |
| Command-S | Collapse or expand the sidebar. |
| Command-, (comma) | Open the settings. |

## 6. Settings

Open the settings with Command-, (comma). The settings are in these categories:

- **General**: appearance, start page, sidebar, search suggestions and history.
- **Feed**: videos for each row, Shorts shelf, filters.
- **Playback**: quality, codec, HDR, autoplay, speed, captions, Picture in Picture, queue, theater mode, hardware decoding, buffer.
- **Notifications**: macOS notifications for new uploads.
- **SponsorBlock**: on or off, the skip notice, the action for each segment category, the server.
- **DeArrow**: titles, thumbnails, originals on hover.
- **Account**: sign in and sign out.
- **Advanced**: yt-dlp, the JavaScript runtime, tool updates, storage, reset.
- **About**: version, updates, links.

## 7. Known limits

- You cannot drag the timeline in the macOS Picture in Picture window. Use the ±10 s buttons. Other players have the same limit.
- YouTube changes frequently. A YouTube change can stop a feature. If videos do not play, go to **Settings › Advanced** and click **Check Now** to update yt-dlp.
- The search history comes from the Google My Activity web page. If Google changes this page, Velvet shows a shorter history from YouTube.
- On Intel Macs, hardware decoding of AV1 is not available, and of VP9 only on most Macs from 2017 or later. Velvet selects a codec that your Mac can decode in hardware.

## 8. Report a problem

Open an [issue](https://github.com/subhashhhhhh/Velvet/issues/new). Include:

- The Velvet version (**Settings › About**).
- The macOS version.
- What you did, what you expected, and what occurred.
- For playback problems, the video link.

## 9. Build from source

You need Xcode 27, or Xcode 26 with xcodegen (`brew install xcodegen`).

```sh
git clone https://github.com/subhashhhhhh/Velvet.git
cd Velvet
./install.sh
```

The script builds a Release version and puts `Velvet.app` in `/Applications`. With Xcode 26, it first makes a project from `project.yml`. You can do this procedure while Velvet runs. The new version starts when you start Velvet again.

A build that you make yourself does not have the release signature. Thus it cannot install updates. It shows the release page instead.

For information about the source code, refer to [CLAUDE.md](CLAUDE.md).

## 10. Acknowledgements

- [mpv](https://mpv.io), through [MPVKit](https://github.com/mpvkit/MPVKit), plays the video.
- [yt-dlp](https://github.com/yt-dlp/yt-dlp), with [Deno](https://deno.com), finds the streams.
- [SponsorBlock](https://sponsor.ajay.app) and [DeArrow](https://dearrow.ajay.app) supply segments, titles and thumbnails.

## 11. License

MIT. Refer to [LICENSE](LICENSE).

YouTube is a trademark of Google LLC. Velvet is not related to, approved by or supported by Google or YouTube.

<!-- Written in ASD-STE100 Simplified Technical English. Keep sentences short: 20 words or fewer in procedures, 25 or fewer in descriptions. One instruction in each step. -->

<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Velvet icon">
</p>

<h1 align="center">Velvet</h1>

<p align="center">
  A YouTube client for macOS that uses little memory.<br>
  macOS 15 or later · Apple silicon and Intel · Free and open source (MIT)
</p>

---

Velvet is a macOS app for YouTube. It uses less memory than the YouTube website in a browser.

When it plays the same 1440p video, Velvet uses approximately 360 MB of memory. Safari uses approximately 1.4 GB.

Velvet uses your YouTube account. Your home feed, subscriptions, history, Watch Later and playlists are the same as on youtube.com.

Velvet is not related to YouTube or Google.

## 1. Install

### 1.1 Install with Homebrew

Do this command in Terminal:

```sh
brew install --cask subhashhhhhh/velvet/velvet
```

### 1.2 Install from a download

1. Find the type of your Mac. Open the Apple menu › **About This Mac**.
   - If you see **Chip**, your Mac has Apple silicon.
   - If you see **Processor**, your Mac has an Intel processor.
2. Go to the [latest release](https://github.com/subhashhhhhh/Velvet/releases/latest).
3. Download the disk image for your Mac:
   - Apple silicon: `Velvet-<version>-AppleSilicon.dmg`
   - Intel: `Velvet-<version>-Intel.dmg`
4. Open the disk image.
5. Drag **Velvet** to **Applications**.
6. Start Velvet.

Apple does not notarize Velvet. Notarization needs a paid developer account. Because of this, macOS stops the app the first time that you open a downloaded copy.

To open the app, do one of these procedures:

- Open **System Settings › Privacy & Security**. Go to **Security**. Click **Open Anyway**.
- Do this command in Terminal:

  ```sh
  xattr -cr /Applications/Velvet.app
  ```

NOTE: The Homebrew install does not need these procedures.

### 1.3 Requirements

- A Mac with Apple silicon or an Intel processor.
- macOS 15 (Sequoia) or later.
- An internet connection.

### 1.4 First start

On the first start, Velvet shows a welcome. The welcome has three steps:

1. Information about Velvet.
2. Sign in to your Google account. You can skip this step.
3. Options for SponsorBlock, DeArrow, your full search history and upload notifications.

Velvet needs two tools to play videos: yt-dlp and a JavaScript runtime (Deno). On the first start, Velvet downloads these tools. The progress shows at the bottom of the window.

If you open a video before the downloads are complete, the player shows the progress. The video starts when the downloads are complete.

## 2. Updates

Velvet looks for a new version one time each day. When a new version is available, **Settings › About** shows the release notes and an **Install and Relaunch** button.

To look for a new version at a different time, select **Velvet › Check for Updates…**.

Before Velvet installs an update, it does these checks:

- The download is complete.
- The download has the same signature as the installed app.

If a check fails, Velvet does not install the update. For more information, refer to [docs/signing.md](docs/signing.md).

Velvet also updates yt-dlp and the JavaScript runtime. YouTube changes frequently. New versions of yt-dlp follow these changes.

## 3. Sign in and privacy

To sign in:

1. Click **Sign In** at the right side of the top bar.
2. Sign in to your Google account in the window that opens.

Velvet keeps your session cookies in a file in `~/Library/Application Support/com.subhash.Velvet`. The file is not encrypted. Its permissions let only your macOS user account read it, but other apps that run as your user can read it, and backups include it. Velvet sends the cookies only to YouTube and Google. To remove them, sign out.

Velvet does not collect data about you. It has no analytics and no telemetry.

Velvet connects only to these services:

| Service | Data that Velvet sends | Why Velvet connects |
|---|---|---|
| YouTube and Google | Your session cookies, your searches, and the text that you type in the search box. | Feeds, search, search suggestions, videos, comments, notifications and account actions. When you are signed in, Velvet also reads your search history (from all your devices) from Google My Activity. This is on by default. You can turn it off in the welcome or in **Settings › General**. |
| GitHub | No personal data. | Downloads of yt-dlp and the JavaScript runtime, the daily update check, and the AiSList list of AI channels (only if you select the AI filter). |
| SponsorBlock (sponsor.ajay.app) | The first four characters of a hash of the video ID. The service cannot find which video you watch. | Segments to skip. |
| DeArrow titles (sponsor.ajay.app) | The first four characters of a hash of the video ID. | Better titles, and the time of a better thumbnail. |
| DeArrow thumbnails (dearrow-thumb.ajay.app) | The video ID. This service can see which videos you look at. | The images of better thumbnails. To stop this, set **Settings › DeArrow › Thumbnails** to **Original**. |
| Return YouTube Dislike | The video ID. | Dislike counts. |

You can disable each service in the settings, except YouTube, Google and GitHub.

## 4. Features

### 4.1 Browse

- Home feed with your recommendations and topic chips.
- Subscriptions: the newest videos and Shorts from your channels.
- Search with suggestions and your past searches.
- History, Watch Later, Playlists and Liked videos.
- Channel pages. You can search in a channel and play all its videos.
- Live streams with live chat.
- Shorts in a vertical player.
- Notifications from your account. Velvet can also show a macOS notification for a new upload. To find new uploads, Velvet reads your notifications. Then YouTube marks them as seen on all your devices, as when you open the bell on youtube.com.
- Back and Forward, as in a browser.

### 4.2 Watch

- Playback with mpv and hardware decoding.
- Quality up to 4K. HDR video shows in HDR on displays that can show it.
- Velvet starts a video at the position where you stopped it.
- Captions: manual, auto-generated and auto-translated.
- Chapters on the seek bar.
- Theater mode and loop.
- SponsorBlock skips sponsor segments and other segments that you select.
- DeArrow replaces clickbait titles and thumbnails.
- Dislike counts from Return YouTube Dislike.
- Comments with replies. You can search the comments.
- Related videos with chips: All, From the series, topics, and more.
- Like, dislike, subscribe, Watch Later and Save to playlist.

### 4.3 Queue and playlists

- Add videos to the queue. Velvet plays them one after the other.
- Drag a video in the queue to change the order.
- When you play a video from a playlist, the remaining videos go into the queue.
- Velvet finds videos in a series (Part 2, Episode 3). It can put the next episode in the queue.

### 4.4 Filters

You can hide these videos:

- Videos that you watched.
- Members-only videos.
- Promotions.
- Videos from channels that post AI-generated videos.

### 4.5 Picture in Picture

The video can move to a Picture in Picture (PiP) window when one of these occurs:

- You go to a different Space or app.
- You scroll past the player.
- You go to a different page in Velvet.

Each of these has a setting.

### 4.6 Slow connections

YouTube sets a speed limit for each video link. For high-quality video (1440p HDR and 4K), Velvet downloads from two links at the same time. This makes the download faster.

If the video stops frequently to load, Velvet decreases the quality by one step. A quality that you select yourself does not change.

### 4.7 System integration

- Now Playing in Control Center.
- Media keys and headphone buttons.
- Two-finger swipes on the trackpad to go back and forward.

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
| Command-[ / Command-] | Go back / go forward. |
| Command-R | Refresh the page. |
| Command-S | Collapse or expand the sidebar. |
| Command-, (comma) | Open the settings. |

## 6. Settings

To open the settings, push Command-, (comma). The settings are in these categories:

| Category | Settings |
|---|---|
| General | Appearance, start page, sidebar, search suggestions and search history. |
| Feed | Videos in each row, Shorts shelf, filters. |
| Playback | Quality, codec, HDR, autoplay, speed, captions, dislike counts, series, audio delay, Picture in Picture, queue, theater mode, hardware decoding, buffer, downloads from two links. |
| Notifications | macOS notifications for new uploads. |
| SponsorBlock | On or off, skip notice, action for each segment category, server. |
| DeArrow | Titles, thumbnails, originals on hover. |
| Account | Sign in and sign out. |
| Advanced | yt-dlp, JavaScript runtime, tool updates, storage, reset. |
| About | Version, updates, links. |

## 7. Known limits

- In the macOS Picture in Picture window, you cannot drag the timeline. Use the ±10 s buttons. Other players have the same limit.
- YouTube changes frequently. A change at YouTube can stop a feature. If videos do not play, go to **Settings › Advanced** and click **Check Now** to update yt-dlp.
- The search history comes from the Google My Activity web page. If Google changes this page, Velvet shows a shorter history from YouTube.
- YouTube limits the download speed of each video link. On a slow connection, 4K HDR video can stop to load. Velvet then decreases the quality.
- Intel Macs cannot decode AV1 in hardware. Most Intel Macs from 2017 or later can decode VP9 in hardware. Velvet selects a codec that your Mac can decode in hardware.

## 8. Report a problem

Open an [issue](https://github.com/subhashhhhhh/Velvet/issues/new). Include this information:

- The Velvet version (**Settings › About**).
- The macOS version.
- What you did, what you expected, and what occurred.
- For a playback problem, the video link.

## 9. Build from source

You need Xcode 27, or Xcode 26 with xcodegen (`brew install xcodegen`).

```sh
git clone https://github.com/subhashhhhhh/Velvet.git
cd Velvet
./install.sh
```

The script builds a Release version and puts `Velvet.app` in `/Applications`. With Xcode 26, the script first makes a project from `project.yml`.

You can do this procedure while Velvet runs. The new version starts when you start Velvet again.

A build that you make yourself installs updates only if it has the release signature (the maintainer's certificate). Other builds cannot install updates. They show the release page.

For information about the source code, refer to [CLAUDE.md](CLAUDE.md).

## 10. Acknowledgements

- [mpv](https://mpv.io), through [MPVKit](https://github.com/mpvkit/MPVKit), plays the video.
- [yt-dlp](https://github.com/yt-dlp/yt-dlp), with [Deno](https://deno.com), finds the streams.
- [SponsorBlock](https://sponsor.ajay.app) and [DeArrow](https://dearrow.ajay.app) supply segments, titles and thumbnails.
- [Return YouTube Dislike](https://returnyoutubedislike.com) supplies dislike counts.
- [AiSList](https://aisloplist.com) supplies the list of channels that post AI-generated videos.

## 11. License

MIT. Refer to [LICENSE](LICENSE).

YouTube is a trademark of Google LLC. Velvet is not related to, approved by or supported by Google or YouTube.

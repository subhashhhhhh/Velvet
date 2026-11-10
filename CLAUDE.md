# Velvet

<!-- Written in ASD-STE100 Simplified Technical English style:
     short sentences, active voice, one instruction in each sentence. -->

## 1. General

Velvet is a native YouTube client for macOS. It is free and open source (MIT). People install it from GitHub Releases and the Homebrew tap `subhashhhhhh/homebrew-velvet`, and it updates itself. Each change goes to real users, not only to the maintainer.

The primary goal is low memory usage. Each change must keep memory usage low.

Velvet uses these items:

- macOS 15 (Sequoia) or later, on Apple silicon and Intel. Do not use APIs that need a later macOS without an `#available` check. Do not add code or downloads that only work on one processor; use `#if arch(x86_64)` where they differ (as in `ToolManager` and `ReleaseFeed`).
- Two project files: `Velvet.xcodeproj` (Xcode 27 format) and `project.yml` (xcodegen, for Xcode 26). Keep the build settings the same in the two files. `install.sh` selects the correct one.
- Swift 6 and SwiftUI. The default actor isolation is the main actor.
- mpv (MPVKit 1.0.0) for playback.
- yt-dlp and a JavaScript runtime (deno) to get the stream URLs. ToolManager downloads and updates these tools.
- The InnerTube WEB API for feeds, the watch page, comments and account actions.


## 2. Source structure

All source files are in `Velvet/`.

| Folder | Contents |
|---|---|
| `App/` | `AppModel` (central state, navigation, PiP logic, debug hooks), app entry, memory relief. |
| `InnerTube/` | API client, JSON type, parsers for videos, the watch page, library, live chat. |
| `Auth/` | Google sign-in (cookie capture in a web view), session storage. |
| `Models/` | Value types: `Video`, `WatchDetails`, `Account`. |
| `Playback/` | mpv player, player view and controls, session, stream resolver, SponsorBlock, PiP, captions, Now Playing, live chat. |
| `Feeds/` | Home feed, topic chips, video cards, DeArrow. |
| `Library/` | History, Watch Later, Playlists, watch progress. |
| `Channels/` | Channel pages. |
| `Shorts/` | Vertical Shorts player. |
| `Settings/` | `Preferences` and the settings window. |
| `Tools/` | yt-dlp and runtime download, process runner. |
| `Downloads/` | Videos saved for offline viewing (`Downloads`): separate video and audio files that mpv plays together, so they play in Velvet only. |
| `Updates/` | Velvet's own updates: release feed, signature check, installer. Signing and releases: `docs/signing.md`, `scripts/release.sh`. |
| `Images/` | Image pipeline (downsampling, memory cache), animated images. |
| `Views/` | Root view, shared controls (`Controls.swift`: `Chip`, `SegmentedTabs`; use these, not the system segmented picker), the custom sidebar (`Sidebar.swift`) and top bar (`TopBar.swift`), window-level player layer. Pages put their Back button, title and actions in the top bar with `.topBarBack`, `.topBarTitle`, `.topBarActions` and `.topBarRefresh`, not with `.toolbar`. |

The website (velvet.subhashh.tech) is in `site/`: Astro, built by Cloudflare Pages (root `site`, command `npm run build`, output `dist`). It reads the version and download links from `updates/latest.json` at build time. Keep its text and its memory figures (`site/src/data.ts`) the same as the README.

## 3. Rules for code

1. Parse InnerTube responses with recursive searches. Do not use long fixed paths. YouTube changes its layouts frequently.
2. Do parsing and network work off the main actor. Use `nonisolated` types and `@concurrent` functions.
3. Do not keep large JSON trees in memory. Call `MemoryRelief.soon()` after a large parse.
4. Load images through `ImagePipeline`. Do not load full-size images.
5. Keep the mpv options in `MPVPlayer` that control memory and CPU. Do not increase the cache sizes without a measurement.
6. Use the private PIP.framework only through `PictureInPicture.swift`.
7. Add a setting to `Preferences` for each new optional behavior. Add the toggle to `SettingsView`.
8. Write a comment when the reason for code is not clear. Do not write comments that only repeat the code.
9. Do not add analytics, telemetry or crash reporting. Do not add a connection to a new service without a reason. List each service that Velvet connects to in README §3.
10. Keep `README.md` correct. When a change adds or removes a feature, a shortcut or a setting category, update the README in the same commit. The README uses ASD-STE100 Simplified Technical English.
11. Do not make user-visible text that says Velvet is a personal app. Write errors and help for users who are not the maintainer.

## 4. Build

To build a Debug version, do this command:

```sh
xcodebuild -project Velvet.xcodeproj -scheme Velvet -derivedDataPath <scratchpad>/dd \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Velvet Self-Signed" DEVELOPMENT_TEAM="" OTHER_CODE_SIGN_FLAGS="--timestamp=none" build
```

Show only the errors. Use `grep -E "error:|BUILD"` on the output.

Sign Debug builds with the release certificate, as above, so that they have the same identity as the installed app.

## 5. Install

After each change that builds, install the app. Do not ask the user before you install.

```sh
VELVET_DERIVED_DATA=<scratchpad>/dd-release ./install.sh
```

The script builds a Release version and replaces `/Applications/Velvet.app`.

CAUTION: Do not quit or kill the Velvet app that the user operates. The script is safe while that app runs. The user starts the new version.

## 6. Commits

1. Use the local git repository.
2. Make a commit after each small part of a feature. Do not make one large commit for a full feature.
3. Write a short subject line. Write the reason for the change in the body.
4. Push to `origin` (GitHub repository `subhashhhhhh/Velvet`) after each commit. The computer can stop without a warning. Unpushed work can be lost.
5. Commits use the identity `Subhash <79552953+subhashhhhhh@users.noreply.github.com>` (global git config). Do not commit with a different email, and do not rewrite or force-push published history.
6. Do not commit personal data: cookies, `-VelvetDumpJSON` output, logs, screenshots, or the signing certificate.

## 7. Releases

Ask the user before each release. A release goes to all users.

1. Increase `MARKETING_VERSION` in `Velvet.xcodeproj` and in `project.yml` (the same value; `1.2` or `1.2.3`). Commit and push.
2. Write the release notes in `docs/releases/<version>.md` and commit them: what changed, for users. Do not write install instructions; the script adds them.
3. Do `scripts/release.sh --publish`. It builds and signs the app for Apple silicon and for Intel, makes a DMG and a zip for each, creates the GitHub release, writes `updates/latest.json` (the in-app updater reads it) and updates the Homebrew cask.

The release signature is the "Velvet Self-Signed" certificate in the login keychain. Installed copies accept only updates with this signature. Do not make a new certificate. Refer to `docs/signing.md`.

## 8. Tests

### 8.1 Debug launch arguments

Start the Debug build with these arguments to test a feature:

| Argument | Result |
|---|---|
| `-VelvetPlay <videoId>` | Opens the video at launch. |
| `-VelvetShort <videoId>` | Opens the Short in the Shorts player at launch. Add `-VelvetShortsSwipeTest YES` to go to the next Short at 8 s and back at 14 s; `-VelvetSlowShorts YES` slows the slide to 3 s. |
| `-VelvetStart <seconds>` | Starts playback at this time. |
| `-VelvetSearch "<query>"` | Opens the search results. |
| `-VelvetChannel <channelId>` | Opens the channel page. Add `-VelvetChannelSearch "words"` to search inside it at 4 s and log the results. |
| `-VelvetChip <n>` | Selects home topic chip n, then tests the topic cache. |
| `-VelvetNavigateTest YES` | Goes to History (video moves to PiP), then opens the video again. |
| `-VelvetKeyTest "t,i,i"` | With `-VelvetPlay`: from 8 s, posts each key as a real key event, 4 s apart (`-VelvetKeyGap <seconds>` to change), and logs the page state and search text. Write `cmd+k` for ⌘K. |
| `-VelvetMinimizeTest YES` | Does what the I key does at 8 s: back to the previous page, video in PiP. |
| `-VelvetDumpJSON <videoId> -VelvetDumpDir <path>` | Saves raw signed-in responses (watch page, comments, replies, home) for parser work. Read-only. |
| `-VelvetQueue <id1,id2>` | Starts with these videos in the queue. Use a short `-VelvetPlay` video near its end to test auto-advance. |
| `-VelvetSidebarTest YES` | Collapses the sidebar to its rail at 8 s and expands it at 12 s, like the top bar button. Debug builds don't save the sidebar state or the window frame, because they share the installed app's defaults and saved state. Logs the grid layout (category `Layout`). Add `-VelvetSlowSidebar YES` for a 10× slower grid animation. |
| `-VelvetShortsBackTest <shortId>` | With `-VelvetPlay`: opens the Short at 8 s and goes Back at 16 s. The video must resume where it was. |
| `-VelvetInboxTest YES` | Opens the notifications popover at 6 s. `-VelvetInboxTab comments` opens it on the Comments tab. Reading the inbox marks it seen on YouTube. Add `-settings.uploadAlerts '<false/>'` in tests to avoid the macOS permission prompt. |
| `-VelvetMarkReadTest YES` | Marks the newest unread notification read, reloads the inbox and logs whether it stayed read. Changes that one notification's read state. |
| `-VelvetWindowWidth <points>` | Sets the window width. Use it for layout checks. |
| `-VelvetPiPTest YES`, `-VelvetPiPSkipTest YES` | Tests PiP and the PiP skip buttons. |
| `-VelvetScrollPiPTest YES` | Scrolls the watch page to start and stop PiP. `-VelvetScrollY <points>` sets the depth. A second later it clicks the search field and logs whether search opened (it must) and whether the video paused (it must not): with `-VelvetScrollY 250` the player is under the top bar. Bring the test window to the front for the click. The jump is an AppKit scroll, which can leave the lazy page layout stale; the page looks wrong in screenshots, but real scrolling is fine. |
| `-VelvetFullscreenTest YES`, `-VelvetResizeTest YES` | Tests fullscreen and window resize. |
| `-VelvetAccountTest YES` | Opens the account panel (top bar picture) at 6 s. |
| `-VelvetSettingsTest YES` | Opens the Settings window at 3 s. `-VelvetSettingsPane <pane>` (general, feed, playback, notifications, sponsorBlock, deArrow, account, advanced) picks the pane. Logs the window size and how far down the window buttons sit (26 pt, as in the main window). |
| `-VelvetAIFilterTest YES` | With `-settings.hideAIChannels '<true/>'`: logs the AiSList list sizes, how many home videos have a channel handle, and how many are hidden. |
| `-VelvetRelatedChipTest YES` | With `-VelvetPlay`: logs the related-video chips, selects the second, then All again, logging the list each time. |
| `-VelvetSubscriptionsTest YES` | Opens Subscriptions and logs its sections, video and Shorts counts. |
| `-VelvetSuggestTest YES` | Prints YouTube's signed-in search suggestions (raw) for an empty box and "s" to stderr. Your own past searches are the items without subtype 512. Then logs the dropdown's rows for an empty box and for "4k" (with the My Activity history merged in; reading My Activity is read-only). The key test also logs the dropdown's rows (`-VelvetKeyTest "cmd+k,s"`). |
| `-VelvetSearchClickTest YES` | Clicks the search field three times, then the page, and logs whether the suggestions show after each (expected: show, hide, show, hide). The test window must be frontmost: a background window uses the first click to activate. |
| `-VelvetResolveAccount YES` | Always resolves streams through the signed-in path (to compare stream speeds with the default visionos path). |
| `-VelvetHistoryTest YES` | Goes History → a video → a channel, then Back, Back, Forward, and logs the page and whether Back/Forward are available after each step. Trackpad swipes can't be sent from a script; the user must test them. |
| `-VelvetPlaylistTest YES` | Opens your first playlist (after Watch Later) when the sidebar has loaded them. Add `-VelvetPlaylistPlay YES` to then play its second video and log the queue it fills. |
| `-VelvetFullscreenAtLaunch YES` | Puts the window in macOS fullscreen as soon as it exists. Check with the window list that the toolbar window sits off screen (y = -52). It takes over the user's screen. |
| `-VelvetRenderControls <file.png>` | Draws the shared controls (`Views/Controls.swift`: tabs, chips) to an image. Use it when no window can be captured (for example while the user's Velvet is in fullscreen). |
| `-VelvetWindowFullscreenTest YES` | Puts the window in macOS fullscreen from 6 s to 12 s (the top bar and sidebar must fill the screen) and logs which view a click on the top bar reaches (it must be the SwiftUI hosting view). It takes over the user's screen for 6 s. |
| `-VelvetLeakTest YES`, `-VelvetNoRelief YES` | Memory tests. |
| `-settings.hasSeenWelcome '<false/>'` | Shows the first-run welcome flow. Add `-VelvetWelcomeStep <0–2>` to open a step (0 welcome, 1 sign in, 2 choices), and `-VelvetToolsDir` with an empty folder to see the downloads. The test never writes the flow's state to the shared defaults (only a real first install does). |
| `-VelvetScrollPerfTest YES` | At 12 s, scrolls the page like a trackpad (one event per display refresh, 2 s down and back; `-VelvetScrollStep` points per event, `-VelvetScrollFrames` events each way) and logs fps, hitches, memory and the watch page's list sizes (category `Test`). Alone for Home, with `-VelvetPlay` for the watch page, with `-VelvetFullscreenAtLaunch YES` for fullscreen. The pointer isn't over the window, so hover costs don't show; measure those by hand with `-VelvetFrameMonitor YES`, which logs frame regularity every 2 s. Measure on macOS 15: macOS 27 hides SwiftUI layout costs that 15 pays. |
| `-VelvetDownloadTest <videoId>` | Downloads the video at the quality setting (add `-settings.quality '<integer>360</integer>'` for a small file), logs progress, then opens it: the log must say "Playing the downloaded copy". Downloads go to the user's real folder; delete the test video's folder in `~/Library/Application Support/com.subhash.Velvet/Downloads` afterwards. |
| `-VelvetToolsDir <path>` | Uses this folder for yt-dlp and the runtime instead of the installed app's. Give an empty folder to test a first install (progress in the player, the welcome flow) without touching the user's tools. |
| `-VelvetUpdateTest YES` | With the `VELVET_UPDATE_FEED` environment variable: opens Settings › About, checks for an update at 3 s and installs it at 6 s, logging each state (category `Test`). Use a scratch copy of a Debug build signed with "Velvet Self-Signed" (docs/signing.md): the install replaces the running copy and relaunches it. |
| `open -a <Debug app> '<link>'` | Sends a YouTube or `velvet://` link to the test instance (category `Links` logs it). A link at launch: `open -n -a <app> '<link>' --args …`. The `velvet` scheme is in `Config/Info.plist`, merged with the generated plist. |
| `-settings.<key> <value>` | Overrides a preference. Use `'<true/>'` or `'<false/>'` for Bool values and `'<integer>3</integer>'` for numbers. |

### 8.2 Procedure

0. Always add `-ApplePersistenceIgnoreState YES`. The Debug app shares the installed app's saved window state, and some saved states open no window at all, so no test runs.

1. Use a 1080p video. A 4K video can hide scaling defects.
2. Test with the sidebar visible and with the sidebar hidden.
3. Read the logs with `/usr/bin/log stream`. In zsh, `log` is a different command. Debug-level messages show only in `log stream`.
4. Capture only the Velvet window. Use `screencapture -l <windowId>`. Use the largest window of the test process.
5. Delete the screenshots after you examine them.
6. Stop each test instance after the test: `pkill -f "Debug/Velvet.app"`.

WARNING: Do not capture the full screen. It shows the private data of the user.

WARNING: Do not capture windows of the "Picture in Picture" process. These windows can show content from other apps. Verify PiP through the logs.

CAUTION: The Debug app shares `~/Library/Application Support/Velvet` with the installed app. Opening a series episode in a test adds it to the user's Continue Watching (`series.json`); back the file up first and restore it after.

CAUTION: Do not do account actions (like, subscribe, Watch Later, playlists) in a test. These actions change the account of the user.

## 9. Known limits

- The system PiP window on macOS does not let you drag its timeline. The ±10 s buttons operate. IINA has the same limit.
- Command-line tools cannot send media keys or MediaRemote commands. The user must test media keys.
- The `visionos` yt-dlp client does not need cookies and has no stream delay. The account path uses cookies and has a delay of approximately 4 s.
- YouTube paces each client's stream links to its estimate of the viewer's bandwidth (the `initcwndbps` link parameter, signed, so it can't be raised). Different clients are paced separately, so `SplitStreamServer` downloads high-bitrate video (over 10 Mbit/s) from the `visionos` and `web_embedded` links at once through a local server on 127.0.0.1. Measured on a 29 Mbit/s line: about 15 Mbit/s from one link, about 20 from two. The player logs every stall with the buffered time and mpv's download rate.
- On macOS 27, mpv's Core Audio output fails for planar audio formats (mpv#18384) and mpv falls back to AVFoundation, which plays mute, volume and speed changes 3–4 s late. Keep `audio-format=float` and `audio-channels=stereo` in `MPVPlayer`.
- YouTube's suggestion service gives a web sign-in only a few past searches. The full search history comes from the Google My Activity page (`MyActivity.swift`), which is a web page, not an API. If it stops to work, the search box falls back to the suggestion service.
- Posted key and mouse events from a test reach the app only when its window is frontmost. When the user's own Velvet is frontmost, they go to the wrong app (macOS beeps). Ask the user to test typing and clicks.
- Do not keep the session in the keychain. Velvet is signed with a self-signed certificate (no Apple team ID), so macOS records each build's code hash in a keychain item's partition list: after every update, macOS asks for the login password before Velvet can read the item. The data-protection keychain needs a team ID. The session stays a 0600 file (`SessionStore`).

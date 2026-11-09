# Velvet

<!-- Written in ASD-STE100 Simplified Technical English style:
     short sentences, active voice, one instruction in each sentence. -->

## 1. General

Velvet is a native YouTube client for macOS. It is for personal use.

The primary goal is low memory usage. Each change must keep memory usage low.

Velvet uses these items:

- macOS 15 (Sequoia) or later. Do not use APIs that need a later macOS without an `#available` check.
- Two project files: `Velvet.xcodeproj` (Xcode 27 format) and `project.yml` (xcodegen, for Xcode 26). Keep the build settings the same in the two files. `install.sh` selects the correct one.
- Swift 6 and SwiftUI. The default actor isolation is the main actor.
- mpv (MPVKit 1.0.0) for playback.
- yt-dlp and a JavaScript runtime (deno) to get the stream URLs. ToolManager downloads and updates these tools.
- The InnerTube WEB API for feeds, the watch page, comments and account actions.

Velvet does not have a Subscriptions page. Do not add one.

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
| `Images/` | Image pipeline (downsampling, memory cache), animated images. |
| `Views/` | Root view, shared controls (`Controls.swift`: `Chip`, `SegmentedTabs`; use these, not the system segmented picker), the custom sidebar (`Sidebar.swift`) and top bar (`TopBar.swift`), window-level player layer. Pages put their Back button, title and actions in the top bar with `.topBarBack`, `.topBarTitle`, `.topBarActions` and `.topBarRefresh`, not with `.toolbar`. |

## 3. Rules for code

1. Parse InnerTube responses with recursive searches. Do not use long fixed paths. YouTube changes its layouts frequently.
2. Do parsing and network work off the main actor. Use `nonisolated` types and `@concurrent` functions.
3. Do not keep large JSON trees in memory. Call `MemoryRelief.soon()` after a large parse.
4. Load images through `ImagePipeline`. Do not load full-size images.
5. Keep the mpv options in `MPVPlayer` that control memory and CPU. Do not increase the cache sizes without a measurement.
6. Use the private PIP.framework only through `PictureInPicture.swift`.
7. Add a setting to `Preferences` for each new optional behavior. Add the toggle to `SettingsView`.
8. Write a comment when the reason for code is not clear. Do not write comments that only repeat the code.

## 4. Build

To build a Debug version, do this command:

```sh
xcodebuild -project Velvet.xcodeproj -scheme Velvet -derivedDataPath <scratchpad>/dd build
```

Show only the errors. Use `grep -E "error:|BUILD"` on the output.

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
4. Push to `origin` (private GitHub repository `subhashhhhhh/Velvet`) after each commit. The computer can stop without a warning. Unpushed work can be lost.

## 7. Tests

### 7.1 Debug launch arguments

Start the Debug build with these arguments to test a feature:

| Argument | Result |
|---|---|
| `-VelvetPlay <videoId>` | Opens the video at launch. |
| `-VelvetShort <videoId>` | Opens the Short in the Shorts player at launch. Add `-VelvetShortsSwipeTest YES` to go to the next Short at 8 s and back at 14 s; `-VelvetSlowShorts YES` slows the slide to 3 s. |
| `-VelvetStart <seconds>` | Starts playback at this time. |
| `-VelvetSearch "<query>"` | Opens the search results. |
| `-VelvetChannel <channelId>` | Opens the channel page. |
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
| `-VelvetScrollPiPTest YES` | Scrolls the watch page to start and stop PiP. `-VelvetScrollY <points>` sets the depth. |
| `-VelvetFullscreenTest YES`, `-VelvetResizeTest YES` | Tests fullscreen and window resize. |
| `-VelvetAccountTest YES` | Opens the account panel (top bar picture) at 6 s. |
| `-VelvetSettingsTest YES` | Opens the Settings window at 3 s. `-VelvetSettingsPane <pane>` (general, feed, playback, notifications, sponsorBlock, deArrow, account, advanced) picks the pane. Logs the window size and how far down the window buttons sit (26 pt, as in the main window). |
| `-VelvetHistoryTest YES` | Goes History → a video → a channel, then Back, Back, Forward, and logs the page and whether Back/Forward are available after each step. Trackpad swipes can't be sent from a script; the user must test them. |
| `-VelvetPlaylistTest YES` | Opens your first playlist (after Watch Later) when the sidebar has loaded them. Add `-VelvetPlaylistPlay YES` to then play its second video and log the queue it fills. |
| `-VelvetFullscreenAtLaunch YES` | Puts the window in macOS fullscreen as soon as it exists. Check with the window list that the toolbar window sits off screen (y = -52). It takes over the user's screen. |
| `-VelvetRenderControls <file.png>` | Draws the shared controls (`Views/Controls.swift`: tabs, chips) to an image. Use it when no window can be captured (for example while the user's Velvet is in fullscreen). |
| `-VelvetWindowFullscreenTest YES` | Puts the window in macOS fullscreen from 6 s to 12 s (the top bar and sidebar must fill the screen) and logs which view a click on the top bar reaches (it must be the SwiftUI hosting view). It takes over the user's screen for 6 s. |
| `-VelvetLeakTest YES`, `-VelvetNoRelief YES` | Memory tests. |
| `-settings.<key> <value>` | Overrides a preference. Use `'<true/>'` or `'<false/>'` for Bool values and `'<integer>3</integer>'` for numbers. |

### 7.2 Procedure

1. Use a 1080p video. A 4K video can hide scaling defects.
2. Test with the sidebar visible and with the sidebar hidden.
3. Read the logs with `/usr/bin/log stream`. In zsh, `log` is a different command. Debug-level messages show only in `log stream`.
4. Capture only the Velvet window. Use `screencapture -l <windowId>`. Use the largest window of the test process.
5. Delete the screenshots after you examine them.
6. Stop each test instance after the test: `pkill -f "Debug/Velvet.app"`.

WARNING: Do not capture the full screen. It shows the private data of the user.

WARNING: Do not capture windows of the "Picture in Picture" process. These windows can show content from other apps. Verify PiP through the logs.

CAUTION: Do not do account actions (like, subscribe, Watch Later, playlists) in a test. These actions change the account of the user.

## 8. Known limits

- The system PiP window on macOS does not let you drag its timeline. The ±10 s buttons operate. IINA has the same limit.
- Command-line tools cannot send media keys or MediaRemote commands. The user must test media keys.
- The `visionos` yt-dlp client does not need cookies and has no stream delay. The account path uses cookies and has a delay of approximately 4 s.

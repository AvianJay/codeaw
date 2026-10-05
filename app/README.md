# codeaw

Flutter client for Android, iOS, and mobile/desktop browsers. See the [project README](../README.md) for pairing and bridge hosting.

The workspace adapts to the window width in logical pixels: phones below 720 use page navigation, tablets from 720 use a navigation rail and a session drawer, and desktop windows from 1100 keep the session list visible. Chat content is limited to 960 pixels; files and Git changes use a list/preview split when the available workspace is at least 820 pixels wide. Terminal canvases use the full workspace width. Pairing and settings forms stay bounded, and larger screens use dialogs for session creation, host selection, and agent forms.

Unsent text is retained for recently opened conversations. Use Ctrl+Enter or Command+Enter to send; Enter inserts a new line.

The model chip offers the agent's model list and a “自訂模型名稱” action for entering a model ID directly. Custom IDs must be supported by the current agent; rejected changes show the agent's error and keep the previous selection.

Side gutters beside scrollable content also accept mouse-wheel scrolling while the content stays within its reading width.

The working indicator shows estimated average TPS beside the current activity. Each completed turn keeps its estimated TPS, total elapsed time, and buttons to copy the full response, reuse the prompt in the composer, or copy the turn and thought text from the overflow menu. TPS includes visible thought/response text over the whole turn, including tools and waits; `≈` marks the text-based estimate. Reusing a prompt preserves any existing draft and lets you edit it before sending.

For agents that accept images, Ctrl+V / Command+V in the message box pastes clipboard pictures as removable preview attachments. The image menu also offers “貼上剪貼簿圖片”. PNG, JPEG, WebP, and GIF are supported, along with Android keyboard image insertion. Ordinary text paste and undo keep their normal behavior. In browsers, use the keyboard shortcut if clipboard permission for the image-menu action is unavailable.

```sh
flutter test test/composer_paste_test.dart
flutter test --platform chrome test/image_clipboard_web_test.dart
```

```powershell
flutter test test/adaptive_layout_test.dart
# Optional visual previews in test/screenshots/:
$env:CODEAW_SCREENSHOTS = '1'
flutter test --update-goldens test/adaptive_layout_test.dart
```

Background progress (Settings → 背景進度, off by default) mirrors one running conversation into the system's live progress UI after the app leaves the foreground: the conversation on screen, or else the only running one. It is followed until its turn and queued prompts finish, or the app returns. `lib/data/live_activity.dart` arms the content over the `codeaw/live_activity` channel while the app is visible, because neither platform lets an app start these from the background:

- Android (`LiveUpdates.kt`) starts a `dataSync` foreground service when the activity stops. The service keeps the bridge connection alive and shows a `ProgressStyle` notification with one segment per plan entry; Android 16 promotes it to a Live Update with a status bar chip. Older versions show it as an ongoing notification.
- iOS 16.2+ (`LiveActivityChannel.swift` and the `CodeawLiveActivity` widget extension) requests a Live Activity for the Lock Screen and Dynamic Island as the scene resigns active. Updates continue while iOS lets the app run in the background (about 30 seconds). After that the activity is marked stale, and its elapsed timer keeps running until the app is opened.

```sh
flutter test test/live_activity_test.dart
```

```sh
flutter pub get
flutter build web --release --no-web-resources-cdn
# On macOS with Xcode:
flutter build ios --release --no-codesign
```

The build workflow packages the unsigned iOS app as `codeaw-ios-unsigned.ipa`. Sign it with your own sideloading tools before installing. The web build is hosted at `/` on the bridge; use Tailscale Serve for HTTPS outside localhost.

App updates are available from settings and the pairing screen, independently of the bridge connection. Android downloads the universal APK into private cache, checks its size and SHA-256, requests permission to install unknown apps when needed, and opens the system APK installer. iOS offers AltStore, SideStore, LiveContainer, LCSign (download then import), and browser download; unavailable installer links fall back to the browser. IPA signing and installation are completed in the selected tool. The URL formats follow the [AltStore handler](https://github.com/altstoreio/AltStore/blob/master/AltStore/AppDelegate.swift), [SideStore handler](https://github.com/SideStore/SideStore/blob/develop/SideStore/DeepLinks/URLHandler.swift), and [LiveContainer handler](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainerSwiftUI/Views/AppList/LCAppListView.swift).

Nightly CI builds default to the `nightly` channel; `vX.Y.Z` tag builds default to `release`. Users can switch channels, and their selection is saved separately for each installed build channel. Release builds compare semantic versions and build numbers, so newer nightlies with the same app version are detected. The manifest is `app-update.json` in the GitHub Release assets: nightly uses `releases/download/nightly`, release uses `releases/latest/download`. A channel without a published manifest shows a retryable message and a link to the release page. The same Android signing key must be used for both channels; Android can reject a switch to a lower version code.

CI uses a shared build number of `5000 + GITHUB_RUN_NUMBER` for all packages and update manifests. Universal and per-ABI APKs use the same exact Android version code; each ABI is built independently with `--target-platform`, because Flutter's `--split-per-abi` adds architecture offsets. Gradle filters native dependencies to the requested targets so each ABI package includes its matching Flutter engine. The reserved range lets older installations such as `0.1.0+2014` (arm64: run 14 + 2000) and `0.1.0+4014` (x86_64: run 14 + 4000) detect and install new builds without uninstalling. CI inspects every APK's actual package ID, version name, version code and native architectures with Android build-tools before publishing, so a mismatch fails the build.

For local builds, the default channel is `release`. To build a nightly client:

```sh
flutter build apk --release --dart-define=CODEAW_UPDATE_CHANNEL=nightly
# Forks can override the repository (owner/name):
flutter build ios --release --no-codesign --dart-define=CODEAW_UPDATE_CHANNEL=nightly --dart-define=CODEAW_UPDATE_REPOSITORY=AvianJay/codeaw
```

CI publishes the manifest after all build jobs pass. Stable releases are created by pushing a `vX.Y.Z` tag; that version is embedded in all Flutter packages and the manifest. No release is published by local checks.

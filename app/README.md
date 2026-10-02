# codeaw

Flutter client for Android, iOS, and mobile/desktop browsers. See the [project README](../README.md) for pairing and bridge hosting.

The workspace adapts to the window width in logical pixels: phones below 720 use page navigation, tablets from 720 use a navigation rail and a session drawer, and desktop windows from 1100 keep the session list visible. Chat content is limited to 960 pixels; files and Git changes use a list/preview split when the available workspace is at least 820 pixels wide. Terminal canvases use the full workspace width. Pairing and settings forms stay bounded, and larger screens use dialogs for session creation, host selection, and agent forms.

Unsent text is retained for recently opened conversations. Use Ctrl+Enter or Command+Enter to send; Enter inserts a new line.

Side gutters beside scrollable content also accept mouse-wheel scrolling while the content stays within its reading width.

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

```sh
flutter pub get
flutter build web --release --no-web-resources-cdn
# On macOS with Xcode:
flutter build ios --release --no-codesign
```

The nightly workflow packages the unsigned iOS app as `codeaw-ios-unsigned.ipa`. Sign it with your own sideloading tools before installing. The web build is hosted at `/` on the bridge; use Tailscale Serve for HTTPS outside localhost.

# codeaw

Flutter client for Android, iOS, and mobile/desktop browsers. See the [project README](../README.md) for pairing and bridge hosting.

The workspace adapts to the window width in logical pixels: phones below 720 use page navigation, tablets from 720 use a navigation rail and a session drawer, and desktop windows from 1100 keep the session list visible. Chat content is limited to 960 pixels; files and Git changes use a list/preview split when the available workspace is at least 820 pixels wide. Terminal canvases use the full workspace width. Pairing and settings forms stay bounded, and larger screens use dialogs for session creation, host selection, and agent forms.

Unsent text is retained for recently opened conversations. Use Ctrl+Enter or Command+Enter to send; Enter inserts a new line.

Side gutters beside scrollable content also accept mouse-wheel scrolling while the content stays within its reading width.

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

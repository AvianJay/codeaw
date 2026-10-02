# codeaw

Flutter client for Android, iOS, and mobile/desktop browsers. See the [project README](../README.md) for pairing and bridge hosting.

```sh
flutter pub get
flutter build web --release --no-web-resources-cdn
# On macOS with Xcode:
flutter build ios --release --no-codesign
```

The nightly workflow packages the unsigned iOS app as `codeaw-ios-unsigned.ipa`. Sign it with your own sideloading tools before installing. The web build is hosted at `/` on the bridge; use Tailscale Serve for HTTPS outside localhost.

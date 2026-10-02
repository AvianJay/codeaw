# Bridge icon

`codeaw.ico` uses the Flutter app's icon from
`app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png`.
It contains 16, 20, 24, 32, 40, 48, 64, 128 and 256 px images for Windows.
The 256 px image is first because Bun currently embeds only the first ICO image;
this keeps standalone executable icons sharp when Windows resizes them.

The build copies this asset to `dist/assets` for Node/npm installations.
Bun embeds it in Windows executables; the tray extracts that embedded icon.
NSIS uses the same asset for the installer and uninstaller.
Windows executable builds must run on Windows to use Bun's `--windows-icon`.

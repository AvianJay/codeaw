"""Verify the built unsigned app includes a version-matched native Widget extension."""
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
widget = app / "PlugIns" / "CodeawLiveActivity.appex"
with (app / "Info.plist").open("rb") as file:
    main = plistlib.load(file)
with (widget / "Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert main.get("NSSupportsLiveActivities") is True
assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
assert info["CFBundleIdentifier"].startswith(main["CFBundleIdentifier"] + ".")
for key in ("CFBundleVersion", "CFBundleShortVersionString"):
    assert main[key] == info[key], (key, main[key], info[key])
binary = widget / info["CFBundleExecutable"]
assert binary.is_file() and binary.stat().st_size > 0
print(f"Live Activity verified: {info['CFBundleIdentifier']} {info['CFBundleShortVersionString']}+{info['CFBundleVersion']}")

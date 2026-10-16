#!/bin/bash
# Builds DeskSwitch.app from Sources/, code-signs it, installs it to
# ~/Applications, links the CLI into ~/.local/bin, and (re)installs the
# LaunchAgent so the menu-bar agent starts at login.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/DeskSwitch.app"
BIN="$HOME/.local/bin/desk-switch"
LABEL="com.anton.deskswitch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# macOS ties the Input Monitoring grant to the exact (ad-hoc signed) binary, and
# swiftc output differs on every build. So rebuild only when the sources changed,
# and then clear the stale grant so macOS asks again instead of silently refusing.
SOURCE_HASH="$(cat "$DIR"/Sources/*.swift "$0" | shasum -a 256 | cut -d' ' -f1)"
HASH_FILE="$APP/Contents/Resources/source.sha256"
if [[ -f "$HASH_FILE" && "$(cat "$HASH_FILE")" == "$SOURCE_HASH" ]]; then
	echo "==> Sources unchanged, keeping the installed app (and its permissions)"
	REBUILT=0
else
	REBUILT=1
fi

if (( REBUILT )); then
echo "==> Compiling"
xcrun swiftc -O "$DIR"/Sources/*.swift -o "$DIR/.build-deskswitch"

echo "==> Packaging app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$DIR/.build-deskswitch" "$APP/Contents/MacOS/DeskSwitch"
echo "$SOURCE_HASH" > "$HASH_FILE"

cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>DeskSwitch</string>
	<key>CFBundleIdentifier</key>
	<string>$LABEL</string>
	<key>CFBundleName</key>
	<string>DeskSwitch</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
</dict>
</plist>
EOF

echo "==> Code-signing (ad-hoc)"
codesign --force --sign - --identifier "$LABEL" "$APP"

echo "==> Clearing the old Input Monitoring grant (macOS will ask again)"
tccutil reset ListenEvent "$LABEL" >/dev/null 2>&1 || true
fi

echo "==> Linking CLI to $BIN"
mkdir -p "$(dirname "$BIN")"
ln -sf "$APP/Contents/MacOS/DeskSwitch" "$BIN"

echo "==> Installing LaunchAgent"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/DeskSwitch</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/desk-switch.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/desk-switch.log</string>
</dict>
</plist>
EOF

echo "==> (Re)starting"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Done. Try: desk-switch status    Logs: tail -f ~/Library/Logs/desk-switch.log"

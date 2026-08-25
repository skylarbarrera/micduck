#!/usr/bin/env bash
# Build micduck and install it to ~/.local/bin. With --launchagent, also start it at login.
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LABEL="com.skylarbarrera.micduck"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WANT_AGENT=0

for arg in "$@"; do
  case "$arg" in
    --launchagent) WANT_AGENT=1 ;;
    --uninstall)
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      rm -f "$PLIST" "$BIN_DIR/micduck" "$HOME/.cache/micduck.restore"
      echo "uninstalled. Remove the stale Accessibility entry in System Settings if you like."
      exit 0 ;;
    *) echo "usage: $0 [--launchagent] [--uninstall]" >&2; exit 2 ;;
  esac
done

command -v swiftc >/dev/null || { echo "swiftc not found. Install the Xcode command line tools: xcode-select --install" >&2; exit 1; }

echo "building..."
( cd "$SRC_DIR" && swiftc -O -o micduck micduck.swift )

# Sign with a stable identity if one exists. Without it the binary is ad-hoc signed, which ties
# the Accessibility grant to this exact build, so the next rebuild silently revokes it.
SIGN_ID="${SIGN_ID:-micduck-selfsigned}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --identifier micduck "$SRC_DIR/micduck"
  echo "  signed with $SIGN_ID"
else
  echo "  note: no '$SIGN_ID' identity found, falling back to an ad-hoc signature."
  echo "        the Accessibility grant will break on every rebuild. run ./sign-setup.sh once to fix."
fi

echo "verifying..."
"$SRC_DIR/micduck" --selftest >/dev/null || { echo "selftest FAILED, not installing" >&2; exit 1; }
echo "  selftest ok"

mkdir -p "$BIN_DIR"
# Replace rather than write in place, so a running copy isn't corrupted mid-execution.
rm -f "$BIN_DIR/micduck"
cp "$SRC_DIR/micduck" "$BIN_DIR/micduck"
echo "installed -> $BIN_DIR/micduck"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH" ;;
esac

if [ "$WANT_AGENT" = "1" ]; then
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/micduck</string>
    <string>--verbose</string>
    <string>--gate-key</string>
    <string>${MICDUCK_GATE_KEYS:-61,54}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/micduck.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/micduck.log</string>
</dict>
</plist>
PLIST_EOF

  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "launchagent loaded -> $PLIST"
  echo "logs -> $HOME/Library/Logs/micduck.log"
  echo
  echo "REQUIRED: launchd can't inherit a terminal's Accessibility grant, so add this path:"
  echo "  System Settings > Privacy & Security > Accessibility > +"
  echo "  $BIN_DIR/micduck"
  echo "Until you do, it will exit at login with a permission error."
else
  echo
  echo "run it:   $BIN_DIR/micduck --verbose"
  echo "at login: $0 --launchagent"
fi

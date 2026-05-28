#!/usr/bin/env bash
# Install blocker as a launchd service.
#
# Two modes:
#   user (default): blocks apps only. Runs as you, no sudo needed.
#   root:           also blocks websites via /etc/hosts. Requires sudo.
#
# Usage:
#   ./install.sh           # user mode (apps only)
#   sudo ./install.sh root # root mode (apps + websites)
#
# Uninstall:
#   ./install.sh uninstall
#   sudo ./install.sh uninstall-root

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/blocker"
USER_TARGET="$HOME/Library/LaunchAgents/com.user.blocker.plist"
ROOT_TARGET="/Library/LaunchDaemons/com.user.blocker.plist"

build() {
  local owner="${SUDO_USER:-$USER}"
  sudo -u "$owner" swiftc "$DIR/blocker.swift" -o "$BIN"
  # First run? Copy the example so the binary has something to read.
  if [ ! -f "$DIR/config.json" ]; then
    sudo -u "$owner" cp "$DIR/config.example.json" "$DIR/config.json"
    echo "Created config.json from example — edit it to set your schedule."
  fi
}

# Emit a launchd plist. $1=path, $2=stdout log, $3=stderr log.
write_plist() {
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.blocker</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$2</string>
    <key>StandardErrorPath</key>
    <string>$3</string>
</dict>
</plist>
EOF
}

case "${1:-user}" in
  user)
    build
    mkdir -p "$HOME/Library/LaunchAgents"
    write_plist "$USER_TARGET" "/tmp/blocker.user.log" "/tmp/blocker.user.err"
    launchctl bootout "gui/$(id -u)/com.user.blocker" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$USER_TARGET"
    echo "Installed user LaunchAgent. Apps will be blocked; websites will NOT."
    echo "Log: /tmp/blocker.user.log"
    ;;
  root)
    if [ "$EUID" -ne 0 ]; then echo "run with: sudo $0 root"; exit 1; fi
    build
    # Root LaunchDaemon: handles /etc/hosts. Can't see GUI apps.
    write_plist "$ROOT_TARGET" "/tmp/blocker.log" "/tmp/blocker.err"
    chown root:wheel "$ROOT_TARGET"
    chmod 644 "$ROOT_TARGET"
    launchctl unload "$ROOT_TARGET" 2>/dev/null || true
    launchctl load "$ROOT_TARGET"
    # User LaunchAgent: handles app killing. Installed as $SUDO_USER.
    owner="${SUDO_USER:-$USER}"
    owner_uid=$(id -u "$owner")
    owner_home=$(eval echo "~$owner")
    agent_target="$owner_home/Library/LaunchAgents/com.user.blocker.plist"
    sudo -u "$owner" mkdir -p "$owner_home/Library/LaunchAgents"
    write_plist "$agent_target" "/tmp/blocker.user.log" "/tmp/blocker.user.err"
    chown "$owner" "$agent_target"
    launchctl bootout "gui/$owner_uid/com.user.blocker" 2>/dev/null || true
    launchctl bootstrap "gui/$owner_uid" "$agent_target"
    echo "Installed root LaunchDaemon (/etc/hosts) + user LaunchAgent (apps)."
    echo "Logs: /tmp/blocker.log (root) and /tmp/blocker.user.log (user agent)"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/com.user.blocker" 2>/dev/null || true
    rm -f "$USER_TARGET"
    echo "User agent removed."
    ;;
  uninstall-root)
    if [ "$EUID" -ne 0 ]; then echo "run with: sudo $0 uninstall-root"; exit 1; fi
    launchctl unload "$ROOT_TARGET" 2>/dev/null || true
    rm -f "$ROOT_TARGET"
    owner="${SUDO_USER:-$USER}"
    owner_uid=$(id -u "$owner")
    owner_home=$(eval echo "~$owner")
    agent_target="$owner_home/Library/LaunchAgents/com.user.blocker.plist"
    launchctl bootout "gui/$owner_uid/com.user.blocker" 2>/dev/null || true
    rm -f "$agent_target"
    python3 -c "
from pathlib import Path
p = Path('/etc/hosts'); t = p.read_text()
b, e = '# >>> blocker managed >>>', '# <<< blocker managed <<<'
if b in t and e in t:
    p.write_text(t.split(b)[0].rstrip() + '\n' + t.split(e)[1].lstrip())
"
    echo "Root daemon removed; /etc/hosts cleaned."
    ;;
  *)
    echo "usage: $0 [user|root|uninstall|uninstall-root]"; exit 1;;
esac

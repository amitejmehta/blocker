# blocker

A ~250-line Swift daemon that blocks Mac apps and websites on a schedule. Menu bar item shows today's kill count.

## What it does

- **Blocks Mac apps** — kills any listed app within ~0.3s of launch via `pkill -9` against the app bundle's executable path. Session-independent, so it works on Electron apps, helpers, anything.
- **Blocks websites across all browsers** — rewrites a managed section of `/etc/hosts` to null-route listed domains. Works for Safari, Chrome, Firefox, Arc — anything that uses system DNS. (Caveat: browsers with DNS-over-HTTPS enabled bypass `/etc/hosts`. Turn off "Secure DNS" in browser settings for the block to bite.)
- **Schedule** — per-weekday time windows in a JSON file. Hot-reloaded every 0.3s, no restart needed.
- **Kill log** — every block event appended to `~/blocker/kills.log` (TSV: ISO timestamp, bundle ID).

## How it works

Two `launchd` jobs split the work, because macOS scopes each one's capabilities differently:

- **User LaunchAgent** (runs as you) — polls every 0.3s, `pkill`s any blocked app. Hosts the menu bar item. Can't touch `/etc/hosts`.
- **Root LaunchDaemon** (runs as root) — manages the `/etc/hosts` section. Can't see GUI apps from its session, so it doesn't try.

## Install

```bash
git clone https://github.com/amitejmehta/blocker.git ~/blocker && cd ~/blocker
sudo ./install.sh root
```

Or, apps only (no sudo, no website blocking):

```bash
./install.sh
```

First run copies `config.example.json` to `config.json`. Edit `config.json` to set your schedule — changes apply within 0.3s.

## Config schema

```json
{
  "schedules": [
    {
      "name": "...",
      "start": "09:00",       // local time, 24h
      "end":   "13:00",       // same-day windows only (start < end)
      "days":  [0,1,2,3,4],   // 0=Mon..6=Sun
      "apps":  ["com.tinyspeck.slackmacgap"],
      "domains": ["twitter.com"]
    }
  ]
}
```

Find an app's bundle ID with `osascript -e 'id of app "Slack"'`.

Or paste this prompt into Claude Code / Codex and fill in the blanks:

```
Add a new schedule to ~/blocker/config.json matching the format in
~/blocker/config.example.json. Block <apps and/or domains> from <start>
to <end> on <days>. For each app, get its bundle ID by running
`osascript -e 'id of app "<name>"'` and use that in the apps array.
```

## Stats

Every block fires once per app launch (deduped across ticks) and is appended to `~/blocker/kills.log`. Quick views:

```bash
wc -l ~/blocker/kills.log                                        # total blocks ever
awk '{print substr($1,1,10)}' ~/blocker/kills.log | sort | uniq -c   # per day
awk '{print $2}' ~/blocker/kills.log | sort | uniq -c | sort -rn     # per app
```

Or paste this prompt into Claude Code / Codex:

```
Analyze ~/blocker/kills.log (TSV: ISO-timestamp, bundle-id). Tell me
which apps I try to open most, which days/times I most fight the
block, and any patterns worth knowing.
```

## Uninstall

```bash
sudo ./install.sh uninstall-root   # both daemons + cleans /etc/hosts
./install.sh uninstall             # user-mode only
```

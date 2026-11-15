#!/usr/bin/env bash
# claude-keeper installer. Safe to run again at any time: it only changes what
# differs, never restarts a running tmux server, and `claude-keeper update`
# is just "git pull, then this script with --update".
#
#   ./install.sh              install, or bring an install up to date
#   ./install.sh --dry-run    print what would change, change nothing
#   ./install.sh --no-start   don't start the tmux server unit now
#
# Runs as your normal user (no sudo), from a checkout of this repository.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "$SRC/VERSION")"
DRY=0 UPDATE=0 NO_START=0
NO_SYSTEMD="${CLAUDE_KEEPER_NO_SYSTEMD:-0}"   # tests only: skip systemctl/loginctl

for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --update) UPDATE=1 ;;
    --no-start) NO_START=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $a" >&2; exit 2 ;;
  esac
done

BIN="$HOME/.local/bin"
CFG="$HOME/.config"
UNITS="$CFG/systemd/user"
STATE="$HOME/.local/state/claude-keeper"
PLUGINS="$HOME/.tmux/plugins"
TMUX_CONF="$HOME/.tmux.conf"
SOURCE_LINE='source-file ~/.config/tmux/keeper.conf'
UNIT_FILES=(tmux-server.service tmux-keeper-save.service tmux-keeper-save.timer tmux-keeper-bg.service)

warnings=() changed=() units_changed=0 conf_changed=0
say()  { printf '%s\n' "$*"; }
warn() { warnings+=("$*"); printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'claude-keeper: %s\n' "$*" >&2; exit 1; }
act()  { if [ "$DRY" = 1 ]; then say "  would run: $*"; else "$@"; fi; }
# The default tmux socket, even when this runs inside some other tmux.
tmuxd() { env -u TMUX tmux "$@"; }
sysd()  { [ "$NO_SYSTEMD" = 1 ] || systemctl --user "$@"; }

# place SRC DST MODE: install if different; returns 0 when it changed something.
place() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then return 1; fi
  act install -Dm"$3" "$1" "$2"
  changed+=("$2")
  return 0
}

# --- prerequisites ---------------------------------------------------------
say "claude-keeper $VERSION ($([ "$UPDATE" = 1 ] && echo update || echo install)$([ "$DRY" = 1 ] && echo ', dry run'))"
command -v git >/dev/null || die "git is required"
command -v python3 >/dev/null || die "python3 is required"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "python3 3.8 or newer is required"
command -v tmux >/dev/null || die "tmux is required (3.4 or newer recommended)"
tv="$(tmux -V | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [ -z "$tv" ]; then
  warn "could not read the tmux version ($(tmux -V)); assuming it is recent"
elif python3 -c "import sys; sys.exit(tuple(map(int,'$tv'.split('.'))) >= (3, 2))"; then
  die "tmux $tv is too old: 3.2 or newer is needed (3.4+ tested)"
fi
if [ "$NO_SYSTEMD" != 1 ]; then
  systemctl --user show-environment >/dev/null 2>&1 ||
    die "no systemd user manager: claude-keeper needs Linux with systemd (systemctl --user)"
fi
claude=""
if [ -x "$BIN/claude" ]; then claude="$BIN/claude"; elif command -v claude >/dev/null; then claude="$(command -v claude)"; fi
[ -n "$claude" ] || warn "Claude Code (claude) not found; tmux layouts will still be restored"

# Without linger, user services only start when you log in, which defeats the point.
if [ "$NO_SYSTEMD" != 1 ]; then
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != yes ]; then
    if [ "$DRY" = 1 ]; then
      say "  would run: loginctl enable-linger $USER"
    elif ! loginctl enable-linger "$USER" 2>/dev/null; then
      warn "linger is off, so nothing starts at boot until you log in. Fix: sudo loginctl enable-linger $USER"
    fi
  fi
fi

# --- tmux plugins (TPM, resurrect, continuum) ------------------------------
for p in tpm tmux-resurrect tmux-continuum; do
  if [ ! -d "$PLUGINS/$p" ]; then
    act git clone -q --depth 1 "https://github.com/tmux-plugins/$p" "$PLUGINS/$p"
    changed+=("$PLUGINS/$p")
  fi
done

# --- scripts, tmux config, units -------------------------------------------
for f in tmux-keeper claude-mgr claude-keeper; do place "$SRC/bin/$f" "$BIN/$f" 755 || true; done
place "$SRC/tmux/keeper.conf" "$CFG/tmux/keeper.conf" 644 && conf_changed=1
for u in "${UNIT_FILES[@]}"; do place "$SRC/systemd/$u" "$UNITS/$u" 644 && units_changed=1; done
place "$SRC/systemd/tmux-spawn-scope.conf" "$UNITS/tmux-spawn-.scope.d/50-tmux-keeper.conf" 644 && units_changed=1

# ~/.tmux.conf: append the source-file line once, at the end (TPM's run must be last).
if [ -f "$TMUX_CONF" ] && grep -qxF "$SOURCE_LINE" "$TMUX_CONF"; then
  last="$(grep -vE '^[[:space:]]*(#|$)' "$TMUX_CONF" | tail -1)"
  [ "$last" = "$SOURCE_LINE" ] ||
    warn "~/.tmux.conf has lines after '$SOURCE_LINE'; keep it last so TPM loads after your settings"
else
  if [ -f "$TMUX_CONF" ]; then
    act cp -p "$TMUX_CONF" "$TMUX_CONF.bak-$(date +%Y%m%d-%H%M%S)-claude-keeper"
  fi
  if [ "$DRY" = 1 ]; then say "  would append to ~/.tmux.conf: $SOURCE_LINE"
  else printf '\n# claude-keeper (keep this last)\n%s\n' "$SOURCE_LINE" >> "$TMUX_CONF"; fi
  changed+=("$TMUX_CONF")
  conf_changed=1
fi
if [ -f "$TMUX_CONF" ] && grep -E "^[[:space:]]*run(-shell)?[[:space:]].*tpm/tpm" "$TMUX_CONF" >/dev/null; then
  warn "~/.tmux.conf already runs TPM itself; remove that line, keeper.conf runs it"
fi

# --- systemd ---------------------------------------------------------------
if [ "$units_changed" = 1 ]; then act sysd daemon-reload; fi
if [ "$DRY" = 1 ]; then
  say "  would enable: tmux-server.service tmux-keeper-bg.service tmux-keeper-save.timer"
else
  sysd enable --quiet tmux-server.service tmux-keeper-bg.service tmux-keeper-save.timer
  sysd start tmux-keeper-save.timer
fi

server_up=0
tmuxd ls >/dev/null 2>&1 && server_up=1
if [ "$server_up" = 1 ]; then
  if [ "$NO_SYSTEMD" != 1 ] && ! systemctl --user -q is-active tmux-server.service; then
    say "A tmux server is already running outside tmux-server.service. It is left alone:"
    say "it is saved every 2 minutes, and runs under the unit from the next boot."
  fi
  if [ "$conf_changed" = 1 ]; then
    act tmuxd source-file "$TMUX_CONF"
  fi
elif [ "$UPDATE" = 0 ] && [ "$NO_START" = 0 ] && [ "$NO_SYSTEMD" != 1 ]; then
  act systemctl --user start tmux-server.service
fi
if [ "$units_changed" = 1 ] && [ "$UPDATE" = 1 ]; then
  say "Unit files changed. They apply at the next boot; restarting tmux-server.service"
  say "now would end every tmux session, so this script never does it."
fi

# --- record what is installed ----------------------------------------------
commit="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || true)"
dirty="$( [ -n "$commit" ] && [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ] && echo true || echo false)"
if [ "$DRY" = 0 ]; then
  mkdir -p "$STATE"
  python3 - "$STATE/installed.json" "$VERSION" "$commit" "$dirty" "$SRC" <<'PY'
import json, sys, time
path, version, commit, dirty, src = sys.argv[1:]
json.dump({"version": version, "commit": commit or None, "dirty": dirty == "true", "source": src,
           "installedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, open(path, "w"), indent=1)
PY
  if [ "$server_up" = 1 ]; then "$BIN/tmux-keeper" tick || warn "first save failed; see: tmux-keeper tick"; fi
fi

# --- summary ---------------------------------------------------------------
if [ "${#changed[@]}" = 0 ]; then say "Already up to date."
else say "Changed:"; for c in "${changed[@]}"; do say "  ${c/#$HOME/~}"; done; fi
case ":$PATH:" in *":$BIN:"*) ;; *) warn "$BIN is not on PATH in this shell; add it in your shell profile" ;; esac
if [ "${#warnings[@]}" -gt 0 ]; then say "${#warnings[@]} warning(s), see above."; fi
[ "$DRY" = 1 ] || say "Check it with: claude-keeper status"

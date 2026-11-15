#!/usr/bin/env bash
# Install, re-run, use and uninstall claude-keeper in a throwaway HOME with a
# private tmux socket and a stub `claude`. Doesn't touch systemd or your tmux.
# Needs network access to clone the tmux plugins.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
export HOME="$T/home" TMUX_TMPDIR="$T/tmux" CLAUDE_KEEPER_NO_SYSTEMD=1
export PATH="$HOME/.local/bin:/usr/bin:/bin"
unset TMUX
mkdir -p "$HOME/.local/bin" "$TMUX_TMPDIR"
pass=0 failn=0
ok()   { pass=$((pass + 1)); echo "ok   $*"; }
bad()  { failn=$((failn + 1)); echo "FAIL $*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

# A stub claude: no sessions.
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/bin/sh
case "$1" in
  agents) echo '[]' ;;
  --version) echo '0.0.0 (stub)' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$HOME/.local/bin/claude"
printf 'set -g history-limit 5000\n' > "$HOME/.tmux.conf"

out="$("$REPO/install.sh" --dry-run 2>&1)"
check "dry run changes nothing" test ! -e "$HOME/.local/bin/tmux-keeper"
check "dry run lists actions" grep -q "would" <<<"$out"

"$REPO/install.sh" > "$T/first.log" 2>&1 || { cat "$T/first.log"; bad "install"; }
for f in .local/bin/tmux-keeper .local/bin/claude-mgr .local/bin/claude-keeper .config/tmux/keeper.conf \
         .config/systemd/user/tmux-server.service .config/systemd/user/tmux-spawn-.scope.d/50-tmux-keeper.conf \
         .tmux/plugins/tpm/tpm .tmux/plugins/tmux-resurrect/scripts/save.sh .local/state/claude-keeper/installed.json; do
  check "installed $f" test -e "$HOME/$f"
done
check "own tmux.conf kept" grep -qx 'set -g history-limit 5000' "$HOME/.tmux.conf"
check "tmux.conf backed up" compgen -G "$HOME/.tmux.conf.bak-*-claude-keeper"
check "source line is last" test "$(grep -vE '^[[:space:]]*(#|$)' "$HOME/.tmux.conf" | tail -1)" = 'source-file ~/.config/tmux/keeper.conf'

"$REPO/install.sh" --update > "$T/second.log" 2>&1
check "second run: already up to date" grep -q "Already up to date" "$T/second.log"
check "source line added once" test "$(grep -cxF 'source-file ~/.config/tmux/keeper.conf' "$HOME/.tmux.conf")" = 1

# A real (sandboxed) tmux server with the config loaded: save must work.
tmux new-session -d -s alpha -c "$HOME"
tmux new-session -d -s beta
sleep 1
"$REPO/install.sh" --update > "$T/third.log" 2>&1
check "tick saved the layout" test -e "$HOME/.local/share/tmux/resurrect/last"
check "layout has both sessions" sh -c "grep -q alpha '$HOME/.local/share/tmux/resurrect/last' && grep -q beta '$HOME/.local/share/tmux/resurrect/last'"
check "tmux-keeper show runs" tmux-keeper show

# claude-mgr
check "status ok" sh -c 'claude-mgr status | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"ok\"] and d[\"keeperVersion\"]"'
check "forced: shell syntax rejected" sh -c '! SSH_ORIGINAL_COMMAND="stop x; id" claude-mgr'
check "forced: unknown verb rejected" sh -c '! SSH_ORIGINAL_COMMAND="rm -rf /" claude-mgr'
check "forced: bad id rejected" sh -c 'SSH_ORIGINAL_COMMAND="stop ../../x" claude-mgr | grep -q "bad session id"'
check "forced: status allowed" sh -c 'SSH_ORIGINAL_COMMAND="claude-mgr status" claude-mgr | grep -q "\"ok\": true"'
check "create: bad folder rejected" sh -c "echo '{\"folder\":\"../x\"}' | claude-mgr create | grep -q folder"

# Dashboard keys
K='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGBV1h1j9pQ9oZ8d1cOq0Yt6m0yJ2n5X7hYv0sZr1aB7 test-dash@box'
check "add-key: unrestricted key refused" sh -c "! claude-keeper add-key '$K'"
check "add-key: forced key added" claude-keeper add-key "command=\"~/.local/bin/claude-mgr\",restrict $K"
check "add-key: second add is a no-op" sh -c "claude-keeper add-key 'command=\"~/.local/bin/claude-mgr\",restrict $K' | grep -q already"
check "list-keys shows it" sh -c 'claude-keeper list-keys | grep -q test-dash@box'
check "remove-key" claude-keeper remove-key test-dash@box
check "key gone" sh -c '! grep -q test-dash "$HOME/.ssh/authorized_keys"'

check "status shows install time and updates" sh -c 'claude-keeper status | grep -q "^installed:" && claude-keeper status | grep -q "^updates:"'

# update from a git checkout without upstream: reinstalls what is there
check "update without upstream" sh -c 'claude-keeper update 2>&1 | grep -q "no upstream\|up to date"'

# uninstall
claude-keeper uninstall > "$T/un.log" 2>&1 || true
check "uninstall removed scripts" test ! -e "$HOME/.local/bin/tmux-keeper"
check "uninstall removed tmux.conf line" sh -c "! grep -qF keeper.conf '$HOME/.tmux.conf'"
check "uninstall kept own settings" grep -qx 'set -g history-limit 5000' "$HOME/.tmux.conf"
check "tmux sessions still running" tmux has-session -t alpha

echo "$pass passed, $failn failed"
[ "$failn" = 0 ]

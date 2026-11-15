# How it works

## Saving

- **tmux layout**: tmux-resurrect's `save.sh`, run by `tmux-keeper tick` every
  2 minutes (`tmux-keeper-save.timer`) and by continuum every 5 minutes while
  a client is attached. Files: `~/.local/share/tmux/resurrect/`.
- **Claude panes**: resurrect's post-save hook runs `tmux-keeper save`. It
  matches each live Claude process's `~/.claude/sessions/<pid>.json` (session
  id, cwd, tmux pane) to the pane list and writes
  `~/.local/state/tmux-keeper/claude.json` (previous one kept as
  `claude.prev.json`). Each entry also keeps the process's Claude flags:
  positional prompts and one-shot flags (`-c`, `-r`, `--session-id`, `-p`,
  `--fork-session`, `--bg`) are dropped, everything else is replayed, and a
  name you set comes back with `--name`.
- **Background sessions**: `tick` also runs `tmux-keeper save-bg`, which writes
  the running ones from `claude agents --json` to `bg.json`, and pins new ones
  (auto-pin, below).

## Restoring at boot

1. Linger starts your user manager at boot, which starts `tmux-server.service`
   (`tmux new-session -d`).
2. The server loads `~/.tmux.conf`, TPM loads continuum, and continuum
   restores the last save. Resurrect then kills the unnamed boot session `0`.
3. Resurrect's post-restore hook runs `tmux-keeper resume`. It waits up to
   20 s for panes to settle, then types `claude --resume <id> <flags>` into
   each saved pane that is a plain shell in the saved cwd and not already
   running Claude. For 3 minutes afterwards `save` does nothing, so the
   resumed sessions can register before the map is overwritten.
4. `tmux-keeper-bg.service` runs `claude respawn <id>` for each background
   session in `bg.json`. `claude respawn --all` only covers sessions that are
   running, so after a reboot it finds nothing; per-id respawn works. The
   Claude supervisor it starts lives in that unit's cgroup, which is why the
   unit stays "active (exited)" and must not be restarted.

## Shutdown

`tmux-server.service` runs `tmux-keeper tick` in `ExecStop`, before
`tmux kill-server`, so the final save sees every pane and Claude process.
Since tmux 3.4, every pane runs in its own transient
`tmux-spawn-<uuid>.scope`. Without ordering, systemd stops those scopes at the
same time as the server unit: the panes die first, the server exits with its
last pane, and `ExecStop` finds no server, so the last save is up to 2 minutes
old. The prefix drop-in `tmux-spawn-.scope.d/50-tmux-keeper.conf` sets
`Before=tmux-server.service` on every such scope, so systemd stops the server
unit (and runs its save) first.

`save` never replaces the map with a smaller one while the system is stopping,
and `save-bg` changes nothing in the first 5 minutes after boot or while
stopping, because sessions are still coming up or already going down.

## Auto-pin

Claude stops unpinned background sessions after they have been idle for a
while (8 h observed with 2.1.32x), and a stopped session isn't respawned after a
reboot. `save-bg` pins each background session once, the first time it sees it
running, by adding its short id to `~/.claude/jobs/pins.json`, the same list
agent view's Ctrl+T edits. The ids it has seen go in `autopin-seen.json`, so
a session you unpin stays unpinned. To turn it off on a machine:
`touch ~/.config/tmux-keeper/no-autopin`.

## Odd-looking choices

- **The unit is `tmux-server.service`, not `tmux.service`.** With
  `@continuum-boot` off, continuum runs `systemctl --user disable tmux.service`
  every time the config loads.
- **The boot session is unnamed.** Resurrect kills session `0` after a restore
  from scratch; a named boot session would be left behind empty.
- **tmux before 3.5 escapes control characters in `-F` output.** The field
  separator `\x1f` comes out as the text `\037`; `tmux-keeper` maps it back.
- **The installer reloads a running server instead of restarting it.** A
  restart ends every session. A server started before the install is saved
  by the timer, and moves under the unit at the next boot.

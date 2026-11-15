# claude-keeper

Keeps long-running Claude Code sessions alive across reboots on a Linux
machine you use for development, and lets a dashboard of your own see and
control them.

- **tmux comes back after a reboot**: sessions, windows, panes, layouts,
  working directories and pane contents (tmux-resurrect + tmux-continuum).
- **The Claude conversations in those panes come back too**: each pane gets
  `claude --resume <the same session id>` with its original flags and name.
- **Claude background sessions** (`claude --bg`, `/bg`, agent view) that were
  running before the reboot are respawned; ones you stopped stay stopped. New
  background sessions are pinned automatically so Claude doesn't stop them
  when idle (turn off with `touch ~/.config/tmux-keeper/no-autopin`).
- **`claude-mgr`**: one JSON command (`status`, `stop`, `pin`, `unpin`,
  `respawn`, `create`) that a dashboard or phone app can call over SSH with a
  key that can run nothing else. See [docs/INTEGRATING.md](docs/INTEGRATING.md).

Per user, no root, no daemon of its own: a few systemd user units and two
Python scripts.

## Recommended workflow

**Why use it:**

- A reboot, a kernel update or a power cut no longer costs you your place.
  Every project comes back in its own window, with its conversation open.
- You keep using plain tmux and Claude Code. There is nothing new to learn
  and nothing to remember to save.
- Long jobs can run in the background unattended, and they come back after a
  reboot too.
- One restricted SSH key lets your phone or dashboard list, start, pin and
  stop sessions, and do nothing else.

**How to manage your sessions:**

1. **Run Claude inside tmux, one tmux session per project**, started in the
   project folder (`tmux new -s myproj -c ~/code/myproj`, then `claude`).
   Name your Claude sessions (`claude -n myproj` or `/rename`) so they are
   easy to find later.
2. **Use background sessions (`claude --bg`, `/bg`) for work that should keep
   going without a terminal.** They are pinned automatically so they don't
   stop when idle.
3. **Stop what you're finished with**: exit Claude or close the pane. Only
   what was running at the last save comes back.
4. **Detach, don't kill**: leave with `Ctrl-b d`. To reboot, just reboot; a
   normal shutdown saves first. Without a clean shutdown, up to the last
   2 minutes of changes can be lost.
5. **Check and update now and then**: `claude-keeper status`, then
   `claude-keeper update`.

## Requirements

- Linux with systemd (user services) and lingering allowed for your user.
- tmux 3.2 or newer (tested on 3.4 and 3.6), git, Python 3.8+.
- Claude Code (tested on 2.1.323 to 2.1.325). Without it you still get the
  tmux restore.

## Install

```bash
git clone https://github.com/formless63/claude-keeper ~/.local/src/claude-keeper
~/.local/src/claude-keeper/install.sh --dry-run   # see what it will change
~/.local/src/claude-keeper/install.sh
claude-keeper status
```

Keep the checkout: `claude-keeper update` pulls it. The installer:

- clones TPM, tmux-resurrect and tmux-continuum into `~/.tmux/plugins` if missing;
- installs `tmux-keeper`, `claude-mgr` and `claude-keeper` into `~/.local/bin`;
- installs `~/.config/tmux/keeper.conf` and appends one line to `~/.tmux.conf`
  (after a backup): `source-file ~/.config/tmux/keeper.conf`. It must stay the
  last line, because TPM has to load after your own settings. If your config
  already runs TPM, remove that `run` line; keeper.conf runs it;
- installs and enables the user units (below), and turns on linger if it can
  (otherwise it tells you to run `sudo loginctl enable-linger $USER`);
- **never restarts a running tmux server.** If you already have tmux running,
  it is reloaded in place, saved every 2 minutes from now on, and comes up
  under `tmux-server.service` from the next boot. If no tmux is running, it
  starts one under the unit.

## Update

```bash
claude-keeper update --dry-run   # commits that would come in
claude-keeper update
```

That is `git pull --ff-only` in the checkout followed by `install.sh --update`.
Only files that differ are touched. Script changes apply immediately. Unit
changes apply at the next boot, because restarting `tmux-server.service` would
end every tmux session; the installer never does it.

Several machines: `for h in host1 host2; do ssh "$h" claude-keeper update; done`.
A checkout with no upstream branch is installed as it is, which is handy while
you change things locally.

## Everyday use

Nothing changes: use tmux and Claude as usual. Things worth knowing:

- `claude-keeper status`: installed commit and date, whether updates exist,
  units, last save, what would come back.
- `tmux-keeper show`: the saved pane → session map and the background list.
- To start clean after a reboot on purpose: `tmux kill-server`, then delete
  `~/.local/share/tmux/resurrect/last`.
- Ending your last tmux session stops the server; the next boot restores the
  last snapshot anyway (plain resurrect does the same).
- Don't `systemctl --user restart tmux-server` (ends every tmux session) or
  `restart tmux-keeper-bg` (stops every background session). Neither is
  ever needed.

## Pieces

| Piece | Job |
|---|---|
| TPM + tmux-resurrect + tmux-continuum | Save and restore the tmux layout. Continuum restores when the server starts. |
| `tmux-keeper` | The Claude layer: records pane → Claude session (resurrect post-save hook) and resumes them (post-restore hook); records and respawns background sessions; auto-pin. |
| `tmux-server.service` | Detached tmux server at boot, which triggers the restore. Saves on shutdown while Claude is still alive. |
| `tmux-keeper-save.timer` | Saves every 2 minutes (continuum's own autosave only runs while a client is attached). |
| `tmux-keeper-bg.service` | At boot, respawns the background sessions that were running. |
| `tmux-spawn-.scope.d/50-tmux-keeper.conf` | Makes systemd stop tmux before its panes at shutdown, so the last save sees them. |
| `claude-mgr` | JSON control surface for dashboards ([docs/PROTOCOL.md](docs/PROTOCOL.md)). |
| `claude-keeper` | status, update, dashboard keys, uninstall. |

Details and the reasons behind the odd-looking choices:
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Connect a dashboard

`claude-mgr` is meant to be the only thing a dashboard can run on your
machine. Your app makes an SSH key, you add its public half restricted to
`claude-mgr`:

```bash
claude-keeper add-key 'command="~/.local/bin/claude-mgr",restrict ssh-ed25519 AAAA… my-dashboard@host'
claude-keeper list-keys
claude-keeper remove-key my-dashboard@host
```

[docs/INTEGRATING.md](docs/INTEGRATING.md) describes how to build the app side
(it is written so you can hand it to a coding agent), and
[docs/PROTOCOL.md](docs/PROTOCOL.md) is the exact JSON contract.

`claude-mgr create` writes a starter `AGENTS.md` into each new project. Put
your own in `~/.config/claude-mgr/new-project.md` (example in
[templates/new-project.md](templates/new-project.md)) and the first prompt in
`~/.config/claude-mgr/new-project-prompt.txt`.

## Uninstall

```bash
claude-keeper uninstall           # keeps saved state
claude-keeper uninstall --purge   # deletes it too
```

Your running tmux sessions are not touched. The TPM plugins and any
authorized keys stay (the keys stop working, since `claude-mgr` is gone).

## Caveats

- tmux-keeper and claude-mgr read Claude Code files that are internal and
  undocumented: `~/.claude/sessions/<pid>.json`, `~/.claude/jobs/pins.json` and
  `~/.claude.json` (folder trust, for `create`). A Claude Code update can
  change them. Then saves record no Claude panes and the layout still restores;
  `claude-mgr status` loses the pin flag and Remote Control link but keeps
  working as long as `claude agents --json` does.
- Resume types a command into a restored pane. It only does that when the pane
  is a plain shell in the saved directory and not already running Claude.
- Linux and systemd only. macOS (launchd) is not supported.

## License

MIT, see [LICENSE](LICENSE).

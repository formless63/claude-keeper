# Changelog

## 1.0.0 (2026-11-15)

First packaged release of tools that ran on four machines from 2026-11-14:

- tmux-keeper: Claude pane resume, background session respawn, auto-pin,
  shutdown save (scope ordering drop-in), tmux 3.4 separator fix.
- claude-mgr: status/stop/pin/unpin/respawn/create; `create` template and
  first prompt configurable in `~/.config/claude-mgr/`; `status` reports
  `keeperVersion`.
- install.sh (idempotent, never restarts a running tmux server) and the
  `claude-keeper` command: status, update, add-key/list-keys/remove-key,
  uninstall.

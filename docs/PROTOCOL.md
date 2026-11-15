# claude-mgr protocol

`claude-mgr` is one command with a fixed set of verbs. Each call prints exactly
one JSON object on stdout and exits.

- Exit 0: `"ok": true`.
- Exit 1: the request was understood but failed: `{"ok": false, "error": "<message>", ...}`.
  Extra keys (`id`, `path`, `detail`, `stderr`) give context. `detail` and `stderr`
  are at most the last 300 characters of Claude's own output.
- Exit 2: bad usage (unknown verb, wrong number of arguments), with the same
  error shape.

Treat a non-JSON stdout or any other exit code as a transport failure.

## Calling it

Locally: `claude-mgr <verb> [arg]`.

Over SSH with a forced-command key (see [INTEGRATING.md](INTEGRATING.md)): the
command you send arrives as `SSH_ORIGINAL_COMMAND` and is parsed with Python's
`shlex`, never run by a shell. Send `status`, `stop 1a2b3c4d`, and so on; a
leading `claude-mgr` is accepted and ignored. Anything else, including shell
syntax like `stop x; id`, is rejected.

## Ids

`<id>` is either a background session's short id (8 lowercase hex, `1a2b3c4d`)
or any session's full session id (a UUID). Anything else gets
`"bad session id"`; a valid id that matches nothing gets `"no such session"`.

## status

```
claude-mgr status
```

```json
{
 "ok": true,
 "host": "devbox",
 "user": "alice",
 "time": 1794700000000,
 "claudeVersion": "2.1.325 (Claude Code)",
 "keeperVersion": "1.0.0",
 "projectsDir": "/home/alice/projects",
 "sessions": [
  {
   "id": "1a2b3c4d",
   "shortId": "1a2b3c4d",
   "sessionId": "1a2b3c4d-....-....-....-............",
   "kind": "background",
   "name": "refactor-auth",
   "cwd": "/home/alice/code/app",
   "status": "idle",
   "turnState": "blocked",
   "running": true,
   "pid": 12345,
   "pinned": true,
   "startedAt": 1794690000000,
   "tmux": null,
   "remoteControlUrl": "https://claude.ai/code/session_...",
   "claudeVersion": "2.1.325"
  }
 ]
}
```

| Field | Meaning |
|---|---|
| `time`, `startedAt` | Milliseconds since the epoch. |
| `keeperVersion` | The installed claude-keeper version, or `null` when claude-mgr was installed by hand. |
| `projectsDir` | Where `create` makes folders (`$CLAUDE_MGR_PROJECTS`, default `~/projects`). |
| `id` | Short id when there is one, else the session id. Use it for the other verbs. |
| `shortId` | Background sessions only; `null` for interactive ones. |
| `kind` | As reported by `claude agents --json`: `"background"` or an interactive kind. |
| `status` | Claude's own status for a running session (for example `"working"`, `"idle"`); `"stopped"` when not running. |
| `turnState` | Claude's turn state when it reports one, for example `"blocked"` when it waits for input. |
| `running`, `pid` | Whether a process is alive, and its pid. |
| `pinned` | In `~/.claude/jobs/pins.json`. Only background sessions can be pinned. |
| `tmux` | `"session:@window.%pane"`-style location for sessions running in tmux, else `null`. |
| `remoteControlUrl` | Opens the session in Claude's web/mobile Remote Control, when it is connected. |

Sorted: running first, background before interactive, newest first. `status`,
`turnState` and `kind` values come straight from Claude Code; show them, don't
switch on an exhaustive list. Fields may be added; ignore ones you don't know.

## stop

```
claude-mgr stop <id>
```

Background: `claude stop <short id>`. Interactive: SIGTERM to the session's
process after checking it is a `claude` executable (the tmux pane stays open,
back at a shell). Already stopped: ok with `"result": "already stopped"`.

`{"ok": true, "id": "1a2b3c4d", "result": "..."}`

A stopped background session is left out of the next reboot's respawn.

## pin / unpin

```
claude-mgr pin <id>
claude-mgr unpin <id>
```

Background sessions only. Pinned sessions are not stopped when idle and so
come back after a reboot. `{"ok": true, "id": "1a2b3c4d", "pinned": true}`

## respawn

```
claude-mgr respawn <id>
```

Restarts a stopped background session with the same id and conversation:
`claude respawn <short id>`. `{"ok": true, "id": "1a2b3c4d", "result": "..."}`

## create

```
claude-mgr create   < request.json
```

stdin is one JSON object:

| Key | Required | Rule |
|---|---|---|
| `folder` | yes | `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`: one path segment, created under `projectsDir`; must not exist yet. |
| `name` | no (default: `folder`) | `^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$`, the session name. |
| `notes` | no | Up to 20,000 characters, written into `AGENTS.md`. |
| `prompt` | no | Up to 8,000 characters, the first message. Default: read AGENTS.md and ask before building. |
| `pin` | no (default `true`) | Pin the new session. |

It creates the folder, writes `AGENTS.md` (from
`~/.config/claude-mgr/new-project.md` if present; placeholders `{name}`,
`{date}`, `{host}`, `{path}`, `{notes}`) and `CLAUDE.md` (`@AGENTS.md`), runs
`git init`, marks that one folder as trusted in `~/.claude.json` (otherwise
`claude --bg` refuses with "Workspace not trusted"), and starts
`claude --bg --name <name> <prompt>` in it.

`{"ok": true, "path": "/home/alice/projects/idea", "id": "1a2b3c4d", "name": "idea", "pinned": true}`

`id` can be `null` if the new session couldn't be identified; it will still
show in the next `status`. Not idempotent: retrying after a timeout fails with
`"folder already exists"`. Allow about 2 minutes for it.

## Limits to set on the client

The reference client (the dashboard this was built for) uses an 8 s connect
deadline, 20 s per command (120 s for `create`) and caps stdout at 2 MiB.
`status` on a busy host is a few kilobytes.

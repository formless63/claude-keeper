# Building a dashboard on claude-mgr

This is how to give your own app (a web dashboard, a phone app, a bot) a
"Claude sessions" page: see every Claude Code session on each of your
machines, and stop, pin, unpin, respawn or start them. It describes the
design that the original dashboard uses; the app side is yours to build. You
can hand this file and [PROTOCOL.md](PROTOCOL.md) to a coding agent working in
your app's repository.

## The shape

```
your app ──SSH (its own key, forced command)──▶ host: claude-mgr ──▶ claude agents / stop / respawn …
          ◀──────────── one JSON object ─────────────
```

- Each host runs claude-keeper, which installs `~/.local/bin/claude-mgr`.
- Your app holds one SSH key per host. On the host, that key's
  `authorized_keys` line forces `claude-mgr`, so the key can call its verbs and
  nothing else: no shell, no port forwarding, no file access.
- Your app keeps no copy of the session list. It asks each host when the page
  is open.

## Host side (once per host)

1. Install claude-keeper on the host (see the README).
2. Get the host's SSH host key fingerprint out of band, from the host itself
   or a trusted network:
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` (on the host), or
   `ssh-keyscan -t ed25519 HOST | ssh-keygen -lf -`.
3. Have the app generate a key pair for this host (below) and show the
   `authorized_keys` line. On the host:
   `claude-keeper add-key 'command="~/.local/bin/claude-mgr",restrict ssh-ed25519 AAAA… myapp@host'`.
   You can limit where it may connect from by adding `,from="192.0.2.10"`
   after `restrict`.
4. Revoke at any time: `claude-keeper remove-key myapp@host`.

## App side: what to build

### 1. A host record

Store per host: label, address, port (22), SSH user, the pinned host key
fingerprint (`SHA256:…`), and the private key. Encrypt the private key at
rest, and keep it out of logs, API responses and the browser.

Generate the key inside the app (Ed25519) so no copy exists anywhere else, and
show only the public half as the ready-made line
`command="~/.local/bin/claude-mgr",restrict ssh-ed25519 <public key> <app>@<label>`.
Offer "rotate key" (new pair, new line to install, old line removed) and
"re-pin host key" for a reinstalled machine.

### 2. One SSH exec per request

Use an SSH library in your server process (for Node, `ssh2`; Python,
`paramiko` or `asyncssh`; Go, `golang.org/x/crypto/ssh`), not a shell-out to
`ssh` with a key file on disk.

- **Pin the host key.** Compare the presented host key's SHA256 with the stored
  fingerprint during the handshake and refuse a mismatch before
  authenticating. Don't trust on first use and don't use `known_hosts`. Show
  both fingerprints in the error.
- Key from memory; no agent, no password or keyboard-interactive auth.
- Send the verb line as the exec command (`status`, `stop 1a2b3c4d`). For
  `create`, write the JSON to the channel's stdin and close it.
- Deadlines: about 8 s to connect, 20 s per command, 120 s for `create`. Cap
  stdout (2 MiB is plenty) and keep a little stderr for diagnostics.
- Parse exactly one JSON object. Exit 0 with `"ok": true` is success; exit 1 or
  2 with `"ok": false` is a clean failure whose `error` you can show; anything
  else is a transport error.
- **Validate on your side too**: ids are 8 lowercase hex or a UUID; folder,
  name and size rules for `create` are in PROTOCOL.md. Build the verb line
  only from validated values. claude-mgr validates again; it is the last line
  of defense, not the only one.

### 3. The page

- Ask every host in parallel, about every 15 seconds while the page is open.
  One unreachable host shows as an error on that host's section and never
  breaks the page.
- Group by host. Per session: name, folder, kind (background or interactive,
  and the tmux location when there is one), status and turn state (call out
  "waiting for input"), pinned, age.
- Row actions: **Stop** (ask for confirmation), **Pin / Unpin** and **Respawn**
  (background sessions only, as PROTOCOL.md says), and **Open** when
  `remoteControlUrl` is set. That link opens the session in Claude on the
  phone or web, which is how you actually talk to it.
- **New session** form: host, folder, optional name, notes and first prompt,
  pin (on by default). Don't retry `create` automatically: it isn't
  idempotent.
- Show names and folders only. claude-mgr never returns transcripts, and the
  page shouldn't try to get them.

### 4. Access and audit

- Only the owner (admins) may use the page and its server endpoints.
- Record every action (stop, pin, unpin, respawn, create, success or failure)
  with who, when, which host and session, and the outcome. For `create`
  record the folder and the lengths of notes and prompt, not their text.
  Reads don't need auditing.

## What this does and doesn't give the app

- It can: list sessions; stop one; pin, unpin or respawn background ones; make
  a project folder under `~/projects` and start a pinned background session
  there with a prompt.
- It can't: run a shell or any other program, read or write other files,
  forward ports, or use the host as a jump box.
- Be clear about the remaining power: someone who takes over the app (with its
  key store) can start Claude sessions with prompts of their choosing on every
  connected host. That is the feature. Protect the app like the hosts it
  controls, audit actions, and revoke a host by removing its line.

## A prompt for your coding agent

> Add a "Claude sessions" page to this app, following
> `claude-keeper/docs/INTEGRATING.md` and the JSON contract in
> `claude-keeper/docs/PROTOCOL.md`. Use this app's existing patterns for
> admin-only pages, encrypted credentials, background polling and audit logs.
> Server side: a host record (label, address, port, user, pinned host key
> fingerprint, encrypted private key generated in-app, Ed25519); an SSH client
> that pins the host key during the handshake, runs one claude-mgr verb per
> request with the deadlines and output cap from INTEGRATING.md, and parses
> the single JSON reply; input validation matching PROTOCOL.md. A setup command
> or form that creates a host record and prints the `authorized_keys` line.
> Client side: per-host sections polled every ~15 s, actions with confirm on
> Stop, an Open link from `remoteControlUrl`, and a New session form.
> Include tests with a fake transport: host key mismatch, timeout, oversized
> output, `ok:false` replies, and rejection of invalid ids before sending.

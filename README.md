# ha-manager

Scripts, docs and conventions for managing two Home Assistant OS instances
from one laptop. Nothing here is secret and none of it is Home Assistant
configuration — the config directories stay on the instances and are covered
by HA's own backups. This repo is safe to publish.

## Layout

```
bin/
  _common.sh        instance resolution, protection guard, HTTP helper (sourced by the rest)
  ha-api            REST wrapper:  ha-api -i NAME [--yes] METHOD PATH [JSON|@file|-]
  ha-ws             websocket wrapper (registries, helpers, zwave_js/*):  ha-ws -i NAME TYPE [key=value ...]
  ha-ssh            ssh wrapper:   ha-ssh -i NAME [--yes] [COMMAND...]
  ha-ls             configured instances and whether each is reachable right now
  ha-detect         install type over the API → HA_INSTALL_TYPE line for the .env
instances/
  example.env       committed template; copy to <name>.env per instance (gitignored)
.claude/settings.json   Claude Code permissions: no raw curl/ssh, no reading tokens/secrets
CLAUDE.md           project memory for Claude Code: channels, endpoints, safety rules
SETUP-HAOS.md       per-instance setup: SSH add-on, keys, jq, Samba mount
```

## Setup

1. **On each instance**, follow [SETUP-HAOS.md](SETUP-HAOS.md): Advanced Mode,
   the Terminal & SSH add-on with a host port and your public key, jq, the
   Samba share. Create a dedicated HA user for this tooling and generate a
   long-lived token as that user.
2. **ssh alias** per instance in `~/.ssh/config` (hostname, port, user, key).
   The instance file references the alias only.
3. **Mount** each instance's `config` share at its own path
   (both shares are called `config`, so `~/mnt/ha` and `~/mnt/25e`).
4. **Instance files:**
   ```
   cp instances/example.env instances/ha.env
   cp instances/example.env instances/25e.env
   chmod 600 instances/*.env
   ```
   Fill in label, URL, token, ssh alias, mount path, protected flag.
5. **Check:** `bin/ha-ls` should show both instances and `up` for whichever
   answers from where you are. Then `bin/ha-detect -i ha` confirms the
   install type.
6. Optionally put `bin/` on your `PATH`.

Requirements on the laptop: bash 3.2+ (macOS default is fine), curl, ssh;
jq is optional but used for pretty-printing when present. `ha-ws` needs
python3 with the `websockets` package (`pip3 install websockets`).

## Selecting an instance

There is deliberately no default instance. Each script resolves its target
from, in order:

1. `-i NAME` / `--instance NAME` on the command line
2. `$HA_INSTANCE` in the environment
3. a `.ha-instance` file at the repo root containing the name (gitignored)

If none of those is set, the script exits with the list of configured
instances. Every run prints `[ha] instance: NAME — label — url` on stderr so
you always see where a command is going. Use `.ha-instance` or
`export HA_INSTANCE=ha` for a session where you're only working on one
instance; use `-i` when you're switching between them.

### Protected instances

`HA_PROTECTED="true"` in an instance file makes the scripts refuse anything
state-changing — REST writes, and ssh commands that restart, reload, stop,
update, delete or overwrite — unless the same command is run with `--yes`.
Read-only operations, template rendering, config checks and backup creation
are always allowed.

## Networks

- **`ha`** (house, Shore Rd) — this laptop is always on the homelab LAN over
  WireGuard, so `http://ha.lan:8123`, the SSH add-on and the Samba share are
  all reachable directly, from anywhere the laptop has internet. The public
  name `https://ha.danieljy.com` (behind Cloudflare) also works and is the
  fallback if the tunnel is down.
- **`25e`** (apartment, Manhattan) — `https://25e.danieljy.com` (behind
  Cloudflare) reaches the API from anywhere. SSH and the Samba mount need a
  path onto that LAN, which doesn't exist from the laptop yet; until it does,
  `25e` is API-only.

`bin/ha-ls` is the quick answer to "which one answers from here right now?".

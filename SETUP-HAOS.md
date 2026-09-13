# Per-instance setup (Home Assistant OS)

Do this once on each instance. Everything here is done in the HA web UI plus
a couple of commands on the laptop. Nothing in this file involves the repo's
instance files except the very last step.

## 0. Advanced Mode

Click your user (bottom-left) → **Advanced mode** → on.

Without it the SSH add-ons don't appear in the add-on store at all, which
looks like they don't exist for your platform.

## 1. Dedicated user + token

Settings → People → **Add person** → enable *Allow login*, make it an
**Administrator** (the Supervisor API needs it). Name it something obvious
like `ha-manager`.

Sign in as that user (a private window is easiest), open its **Profile →
Security → Long-lived access tokens → Create token**. Copy it straight into
the instance file (step 7) and nowhere else.

A separate user means the token can be revoked without logging you out, and
the logbook shows the agent's changes under that user's name.

## 2. Terminal & SSH add-on

Settings → Add-ons → Add-on store → **Terminal & SSH** (the official one,
by Home Assistant). Install it.

It provides:
- a web terminal (via the sidebar) that works immediately
- `/config` as the HA config directory (newer versions also mount it at
  `/homeassistant`)
- the `ha` CLI for Supervisor, Core, host, backups and add-ons

That's all this tooling needs. Leave *Protection mode* on.

**Upgrade path:** if you later need a non-root login user, sftp, or access
to host hardware/Docker, the community **Advanced SSH & Web Terminal**
add-on (hassio-addons) is the one to switch to. Not needed now.

### 2a. Remote SSH is disabled by default — read this

After installing, the **web terminal works right away**, which makes the
add-on look fully configured. It isn't: **nothing can SSH in until you
assign a host port.**

Add-on page → **Network** section → find `22/tcp`, which shows as *Disabled*
→ type a host port (e.g. `22`; the HA OS host itself doesn't use 22) → Save
→ restart the add-on.

Until that box is filled in, `ssh` from the laptop fails with connection
refused and it is easy to spend a while blaming keys or Tailscale.

### 2b. Authorized keys

On the laptop, if you don't already have a key:

```
ssh-keygen -t ed25519 -C "ha-manager"
cat ~/.ssh/id_ed25519.pub
```

Add-on → **Configuration** tab:

```yaml
authorized_keys:
  - ssh-ed25519 AAAA... ha-manager
password: ""
```

Leave `password` empty so keys are the only way in. Save, restart the
add-on. (The add-on refuses to start with no key *and* no password.)

### 2c. jq

Same Configuration tab — the add-on installs Alpine packages on every start:

```yaml
apks:
  - jq
```

Useful with `ha ... --raw-json`. (It's `packages:` instead of `apks:` on the
community add-on.)

### 2d. Port 22222 is something else

HA OS also has a **host-level debug SSH on port 22222**. It is part of the
operating system, not the add-on, and is enabled by putting an
`authorized_keys` file on the `CONFIG` USB / boot partition and importing
it. It gives a root shell on the host OS for debugging HAOS itself. You
don't need it; the add-on's port is the one this tooling uses. If you see
22222 in a guide, that's the other thing.

## 3. ssh alias on the laptop

`~/.ssh/config`:

```
Host ha-prox
    HostName prox.your-tailnet.ts.net    # or the LAN IP / homeassistant.local
    Port 22                              # the host port from step 2a
    User root                            # the official add-on logs in as root
    IdentityFile ~/.ssh/id_ed25519

Host ha-pi
    HostName pi.your-tailnet.ts.net
    Port 22
    User root
    IdentityFile ~/.ssh/id_ed25519
```

Test: `ssh ha-prox ha core info`. The instance file will reference the
alias (`HA_SSH_HOST="ha-prox"`) and nothing else about the connection.

## 4. Samba share

Add-on store → **Samba share** (official). Configuration:

```yaml
workgroup: WORKGROUP
username: homeassistant
password: <something>
allow_hosts:
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16
  - 100.64.0.0/10        # Tailscale addresses — without this the pi's share
                         # is unreachable over Tailscale
  - fe80::/10
  - fc00::/7
veto_files:
  - "._*"
  - ".DS_Store"
  - Thumbs.db
  - icon?
  - .Trashes
compatibility_mode: false
```

The add-on exports several shares; the one you want is **`config`**.

### 4a. Both shares are named `config` — use distinct mount points

Each instance's share is called `config`. If you mount them from Finder you
get `/Volumes/config` and `/Volumes/config-1`, and which is which depends on
the order you connected. Mount explicitly instead:

```
mkdir -p ~/mnt/ha-prox ~/mnt/ha-pi
mount_smbfs //homeassistant@prox.your-tailnet.ts.net/config ~/mnt/ha-prox
mount_smbfs //homeassistant@pi.your-tailnet.ts.net/config   ~/mnt/ha-pi
```

(`umount ~/mnt/ha-prox` to detach.) Put those paths in the instance files
as `HA_MOUNT`. Those directories are what Claude edits YAML in; they are
gitignored if you ever put them under the repo.

## 5. Tailscale (optional but recommended on both)

Add-on store → **Tailscale**. Once both instances are on the tailnet with
MagicDNS, use the `*.ts.net` names in `HA_URL`, the ssh `HostName`, and the
mount commands, and everything works the same from any network.

## 6. Verify from the laptop

```
ssh ha-prox ha core info          # SSH + ha CLI
ls ~/mnt/ha-prox/configuration.yaml   # mount
```

## 7. Instance file

```
cp instances/example.env instances/prox.env
chmod 600 instances/prox.env
```

Fill in the label, URL, token from step 1, ssh alias from step 3, mount from
step 4a. Then:

```
bin/ha-ls                  # should show "up"
bin/ha-detect -i prox      # should say os; paste the line it prints
```

Repeat for `pi`, and set `HA_PROTECTED="true"` on whichever instance you
can't easily walk over to.

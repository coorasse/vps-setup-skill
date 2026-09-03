---
name: setup-vps
description: >
  Guide a Rails app to a deployed production server. Starting from a
  fresh Ubuntu VPS the user has already created (you only need its IP and a
  working SSH key), it provisions and hardens the server over SSH (non-root
  deploy user, UFW firewall, fail2ban, unattended-upgrades, swap, Docker),
  configures Kamal (registry, servers, secrets), points DNS at the server
  (Cloudflare optional), runs the first deploy, and sets up off-server backups
  (Litestream + Hetzner snapshots). Use when the user says "set up a production
  server", "deploy to a VPS", "provision a Hetzner server", "set up Kamal
  deploy", or "go live / release this app".
---

# Set up a production VPS and deploy with Kamal

This skill takes a Kamal-based Rails app live in production on an Ubuntu VPS
(Hetzner or any provider). It is **interactive and incremental**: you guide the
user, run what can be automated over SSH, and stop to confirm before anything
destructive or hard to reverse (locking down SSH, the first deploy).

**The skill does NOT create cloud servers.** You never log into the cloud
provider, never use provider CLIs/APIs (no `hcloud`), and never create, select,
modify, or delete servers or projects. The user creates the server themselves
(you give them instructions in Phase 2). The skill begins once the user provides
a **public IP address** and you can confirm **SSH-as-root works** with their key.

The provisioning scripts live next to this file in `scripts/`: `provision.sh`
(server setup + deploy user), `harden-ssh.sh` (SSH lockdown), and
`check-hardening.sh` (a read-only audit that verifies both took effect).
Reference them by their absolute path inside the skill directory.

## Track progress with your task list

At the start, create one task per phase using your task-list tool
(`TaskCreate`), and keep it current: mark a phase `in_progress` when you start it
and `completed` when it's verified (`TaskUpdate`). This gives the user a live
view of where they are. Suggested tasks:

1. Pre-flight checks
2. Inspect the server and confirm the checklist (multi-select)
3. User creates the VPS (collect IP, confirm SSH)
4. Provision & harden the server (incl. fail2ban whitelist, automatic-reboot
   window), then verify with `check-hardening.sh`
5. Configure Kamal
6. Point DNS at the server (Cloudflare optional)
7. First deploy & verify
8. Set up backups (Litestream + Hetzner snapshots)
9. Wrap up

## Guardrails

- **Never touch cloud infrastructure.** Don't create, list, select, modify, or
  delete servers/projects, and don't use provider CLIs or APIs. The user owns
  that step. You start from an IP they give you. This avoids any chance of
  acting on the wrong account or destroying someone else's production.
- **Never run a destructive or billable command without explicit OK.** That
  includes `bin/kamal setup`/`deploy`. Show the exact command first and wait.
- **Never run a step the user hasn't seen.** Show the command (or the
  destructive part of it) and what it does before running it.
- **Order is safety-critical.** Create and verify the deploy user *before*
  hardening SSH. Make DNS resolve *before* the first deploy so Let's Encrypt can
  issue a cert. Don't reorder.
- Treat the server IP, domain, registry credentials, and `RAILS_MASTER_KEY` as
  values the user supplies — ask, don't invent.
- This skill is app-agnostic. It reads the current app's `config/deploy.yml`;
  it does not assume any particular app name.

## Phase 0 — Pre-flight

Run these checks (in parallel) and read the results before talking to the user:

1. Rails + Kamal present: `Gemfile` contains `rails` and `kamal`; `bin/kamal`,
   `Dockerfile`, and `config/deploy.yml` all exist. If Kamal isn't set up, tell
   the user to run `bin/rails new` defaults or `bundle add kamal && bin/kamal init`
   first, then stop.
2. Read `config/deploy.yml` and `.kamal/secrets` to see what's already filled
   in (service name, image, registry, proxy host, env secrets).
3. Confirm the user has a local SSH key: `ls ~/.ssh/*.pub`. If none, offer to
   create one: `ssh-keygen -t ed25519 -C "<user-email>"`. They'll attach its
   public key to the server when they create it.

Then summarise the current state and the plan, and ask the user for the things
you'll need throughout:

- **Domain** they'll deploy to (e.g. `rubygrids.app`).
- **Container registry** to use — see Phase 4. Recommend GitHub Container
  Registry (`ghcr.io`) or Docker Hub.
- **Deploy username** (default `deploy`).
- Whether they want to use **Cloudflare** for DNS, or another provider/registrar
  (Phase 5). Either is fine.

## Phase 1 — Inspect the server and confirm the checklist

**Never start work on the server before the user has seen the concrete list of
what you would do and picked from it.** This phase always runs. It is
especially important because the skill is often pointed at a server that is
**already provisioned and serving traffic** — reusing a box for a second app —
not only at a fresh VPS.

If the user has no server yet, do Phase 2 first and come back here as soon as
SSH works.

### Step 1a — Inspect the current state

The checklist must reflect reality, so look before you propose. Run one block
(as `root` on a fresh box, as `<DEPLOY_USER>` on an existing one) and read the
output:

```bash
ssh <USER>@<SERVER_IP> '
  echo "== docker ==";      docker --version 2>/dev/null || echo "not installed"
  echo "== containers ==";  docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null
  echo "== ufw ==";         sudo ufw status verbose 2>/dev/null | head -20
  echo "== fail2ban ==";    systemctl is-active fail2ban; sudo fail2ban-client status sshd 2>/dev/null
  echo "== upgrades ==";    systemctl is-active unattended-upgrades; cat /etc/apt/apt.conf.d/51auto-reboot 2>/dev/null
  echo "== swap ==";        swapon --show || echo "none"
  echo "== users ==";       awk -F: "\$3>=1000 && \$3<65534 {print \$1}" /etc/passwd
  echo "== sshd ==";        sudo sshd -T | grep -E "^(permitrootlogin|passwordauthentication)"
  echo "== reboot ==";      test -f /var/run/reboot-required && echo required || echo none
  echo "== timezone ==";    timedatectl | grep "Time zone"
  echo "== disk ==";        df -h /
'
```

Report what you found compactly — Docker version and running containers, UFW,
fail2ban, unattended-upgrades, swap, existing non-root users, the *effective*
SSH config, pending reboot, timezone, disk.

### Step 1b — Present the checklist and confirm (multi-select)

Show the proposed actions with their current state, as a table or bullet list:

| Action | Current state | Proposal |
| --- | --- | --- |
| Docker + base tooling | installed 27.x | already done |
| UFW firewall (22/80/443) | active | already done |
| fail2ban | active, sshd jail | already done |
| Whitelist your IP in fail2ban | not set | offer |
| Swap file | none | offer 2G |
| Deploy user `<DEPLOY_USER>` | missing | offer |
| SSH hardening | root login still allowed | offer |
| Automatic security reboots | not configured | offer |
| Configure Kamal / DNS / deploy | — | offer |

Then ask for confirmation with the `AskUserQuestion` tool using
`multiSelect: true`, offering **only the items that still need doing**. Items
already satisfied are shown as already-done in the table and are not re-offered,
so the user only picks among real work.

- The selection governs what runs. Anything not selected is **skipped**, not
  quietly done anyway — and the wrap-up (Phase 8) must list what was skipped.
- Destructive or hard-to-reverse items (SSH hardening, the first deploy) still
  get their own explicit confirmation at the moment they run, even when
  selected here.

## Phase 2 — The user creates the server (you only instruct)

You do **not** create the server. Give the user a clear checklist and wait for
them to come back with the **public IPv4 address**. For Hetzner Cloud:

1. Log in at <https://console.hetzner.cloud>. Pick an existing **Project** or
   create a new one (e.g. **+ New Project**). A separate project is the cleanest
   way to keep this app isolated from anything else.
2. **Project → Security → SSH Keys → Add SSH Key**: paste the contents of their
   local public key. Print it for them to copy: `cat ~/.ssh/id_ed25519.pub`
   (use whichever key they chose in Phase 0).
3. **Servers → Add Server**:
   - Location: closest to their users (e.g. Nuremberg/Falkenstein for EU).
   - Image: a current **Ubuntu LTS** (e.g. 24.04).
   - Type: **Shared vCPU** — `CX22` (2 vCPU / 4 GB) is a good single-app default;
     `CPX11` (2 vCPU / 2 GB) works too since Kamal builds the image locally and
     the server gets a swap file. Size up for heavier load.
   - **SSH keys**: select the key from step 2 (so no root password is emailed).
   - Name: something memorable (e.g. the app name).
4. Create it and copy the **public IPv4 address** back to you.

(Any other provider works too — all the skill needs is an Ubuntu host with the
user's SSH key authorized for root and the public IP.)

### Confirm connectivity (where the skill takes over)

Once you have the IP, confirm SSH-as-root works with their key:

```bash
ssh -o StrictHostKeyChecking=accept-new root@<SERVER_IP> 'echo ok && . /etc/os-release && echo "$PRETTY_NAME"'
```

If this fails, the SSH key probably wasn't attached at create time, or they need
to pass `-i <key>` — help them fix it before continuing. Do not proceed until
this succeeds.

## Phase 3 — Provision and harden the server

This is the part the skill automates. Two steps, with a verification gate
between them.

### Step 3a — Provision (safe, idempotent)

Pipe `scripts/provision.sh` to the server as root. Pass the deploy username and
optionally a swap size:

```bash
ssh root@<SERVER_IP> 'bash -s' -- <DEPLOY_USER> 2G < <SKILL_DIR>/scripts/provision.sh
```

This installs Docker + tooling, enables unattended security upgrades, fail2ban,
and UFW (22/80/443), creates a 2 GB swap file, and creates the non-root deploy
user — copying the root account's authorized SSH key to it and granting
passwordless sudo + docker group membership. Stream the output to the user.

### Step 3b — Verify the deploy user (GATE)

Before locking anything down, prove the new user can log in and use Docker:

```bash
ssh <DEPLOY_USER>@<SERVER_IP> 'whoami && docker ps'
```

If this fails, **do not proceed to 3d** — debug (wrong key, group membership)
while root login still works.

### Step 3c — Whitelist your current IP in fail2ban (always ask)

`provision.sh` installs a fail2ban sshd jail with `maxretry = 5`. An SSH client
that offers many keys (a 1Password agent holding ~20 keys, say) produces several
failed auths *per connection attempt*, so a couple of ordinary logins can ban
the administrator's own IP for the whole `bantime` (1h) — the app keeps serving,
but SSH is refused.

Detect the current public IP and confirm the server sees the same address (no
NAT surprise):

```bash
curl -s https://api.ipify.org
ssh <DEPLOY_USER>@<SERVER_IP> 'echo $SSH_CLIENT | awk "{print \$1}"'
```

**Ask the user** whether to whitelist it. The trade-off: a shared/corporate VPN
exit IP exempts everyone behind it from fail2ban, while a residential IP may
change over time and the exemption then protects nothing. It's a
convenience/safety trade — declining is fine.

If they accept:

```bash
ssh <DEPLOY_USER>@<SERVER_IP> "sudo tee /etc/fail2ban/jail.d/ignoreip.local >/dev/null <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <CURRENT_IP>
EOF
sudo fail2ban-client reload"
```

Verify with `sudo fail2ban-client get sshd ignoreip` and
`sudo fail2ban-client status sshd`.

To recover from an existing ban: `sudo fail2ban-client set sshd unbanip <IP>`.
Note that if you are *already* banned you cannot SSH in to run it — wait out the
`bantime` or use the provider's web console.

Prevention, either way: pass `-o IdentitiesOnly=yes -i <key>` when testing SSH
(`-i` alone does **not** stop the agent from enumerating every key), and set
`keys_only: true` alongside `keys:` in the Kamal `ssh:` block in
`config/deploy.yml` (Phase 4).

### Step 3d — Harden SSH (only after 3b passes)

Tell the user this disables password authentication and root login, then run:

```bash
ssh root@<SERVER_IP> 'bash -s' < <SKILL_DIR>/scripts/harden-ssh.sh
```

From now on, connect as `<DEPLOY_USER>@<SERVER_IP>`. If a reboot was flagged as
required, suggest `ssh <DEPLOY_USER>@<SERVER_IP> 'sudo reboot'` at a convenient
time.

When checking that root login is really disabled: a `Too many authentication
failures` error is **not** proof — it only means the client offered too many
keys. Verify with `ssh -o IdentitiesOnly=yes -i <key> root@<SERVER_IP>` or
`ssh <DEPLOY_USER>@<SERVER_IP> 'sudo sshd -T | grep permitrootlogin'`.

### Step 3e — Automatic security reboots (ask the user)

`unattended-upgrades` installs security updates but does **not** reboot when a
kernel/library update needs it — the box just sits with `/var/run/reboot-required`
until someone acts. Offer to enable an automatic reboot in a quiet window.

First check the server's timezone, since the reboot time is in **server local
time**:

```bash
ssh <DEPLOY_USER>@<SERVER_IP> 'timedatectl | grep "Time zone"'
```

**Ask the user** (a) which timezone the server should use (default UTC is fine
for servers; offer to set theirs) and (b) what local time they want reboots to
happen (e.g. `04:00`). If they want a non-UTC zone, set it:

```bash
ssh <DEPLOY_USER>@<SERVER_IP> 'sudo timedatectl set-timezone <TZ>'   # e.g. Europe/Zurich
```

Then enable the automatic reboot at the chosen time:

```bash
ssh <DEPLOY_USER>@<SERVER_IP> "sudo tee /etc/apt/apt.conf.d/51auto-reboot >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"<HH:MM>\";
EOF"
```

If the user declines, skip this — it's optional. Mention that a reboot will
briefly interrupt the app (a few seconds), which is why the quiet window matters.

### Step 3f — Verify the hardening (automated audit)

Don't eyeball whether the protections took effect — run the read-only auditor and
read its exit code. It checks the effective SSH config (`sshd -T`), UFW
(active, default-deny, 22/80/443), fail2ban + its `sshd` jail, unattended-upgrades,
swap + swappiness, the deploy user (docker group, sudoers, authorized_keys),
Docker, and flags any unexpected publicly-bound port:

```bash
ssh <DEPLOY_USER>@<SERVER_IP> 'sudo bash -s' -- <DEPLOY_USER> < <SKILL_DIR>/scripts/check-hardening.sh
```

It changes nothing and is re-runnable anytime. **Exit 0** means every required
check passed; a non-zero exit means at least one `FAIL` — investigate and fix it
before moving on (a `FAIL` here usually means a provisioning/hardening step didn't
apply). `WARN` lines are advisory (e.g. auto-reboot not configured, a pending
reboot, an extra open port) and don't fail the audit. Offer this same command to
the user as a day-2 check.

## Phase 4 — Configure Kamal

Edit `config/deploy.yml` and `.kamal/secrets` in the app repo with targeted
`Edit`s (don't rewrite the files). Set:

- `servers.web` → the server's public IPv4.
- `proxy.host` → the user's domain. Keep `proxy.ssl: true` so kamal-proxy gets a
  Let's Encrypt cert automatically.
- `ssh.user` → the deploy user (Kamal defaults to root, which we just disabled).
  Add a top-level block if absent:

  ```yaml
  ssh:
    user: <DEPLOY_USER>
    keys: [ "~/.ssh/id_ed25519" ]
    keys_only: true
  ```

  `keys_only: true` stops Kamal's SSH from offering every key in the agent,
  which is what trips the fail2ban jail (Step 3c).

- `registry` → the chosen registry. For **GHCR**: `server: ghcr.io`,
  `username: <github-user>`, and `image: <github-user>/<app>` (lowercase). For
  **Docker Hub**: drop `server`, set `username: <dockerhub-user>` and
  `image: <dockerhub-user>/<app>`. The password comes from `.kamal/secrets` as
  `KAMAL_REGISTRY_PASSWORD`.

Confirm production secrets are wired:

- `RAILS_MASTER_KEY` — must resolve in `.kamal/secrets` (the generated file
  reads it from `config/master.key`). Verify `config/master.key` exists.
- `KAMAL_REGISTRY_PASSWORD` — for GHCR a GitHub token with `write:packages` (the
  local `gh` CLI token works after `gh auth refresh -h github.com -s
  write:packages`; reference it as `$(gh auth token)`); for Docker Hub an access
  token. **Never commit a raw token** — `.kamal/secrets` must read it from env /
  a command / a password manager.

Also confirm `config.assume_ssl` and `config.force_ssl` are on in
`config/environments/production.rb` (Rails 8 default) so SSL terminates cleanly
behind kamal-proxy.

Then validate config without deploying: `bin/kamal config` and eyeball the
resolved repository, host, and ssh user.

## Phase 5 — Point DNS at the server (before deploying)

Let's Encrypt validates over HTTP on port 80, so the domain must resolve to the
server's IP *before* the first deploy — **regardless of which DNS provider** the
user uses. The goal of this phase is simply: `dig +short <DOMAIN>` returns
`<SERVER_IP>`.

Find out where the domain's DNS is managed (`dig +short <DOMAIN> NS`) and guide
accordingly:

- **Existing provider / registrar (alwaysdata, Namecheap, Route53, etc.)** — add
  an `A` record: name `@` (apex) → `<SERVER_IP>`, low TTL (e.g. 300) for fast
  propagation. Optionally a `CNAME` `www` → the apex. Fastest path to live.
- **Cloudflare (optional)** — only if the user wants Cloudflare's CDN/WAF/dash.
  Add the domain at <https://dash.cloudflare.com>, set the two Cloudflare
  nameservers at the registrar (propagation can take a while), then add the `A`
  record. **Set proxy status to "DNS only" (grey cloud) for the first deploy** so
  Let's Encrypt can reach the origin.

Confirm before deploying: `dig +short <DOMAIN> A @1.1.1.1` returns the server IP.

If the user opted out of Cloudflare, that's completely fine — skip it. If they
chose Cloudflare: after a successful deploy with a valid origin cert (Phase 6),
they *may* switch the record to **Proxied (orange cloud)** and set **SSL/TLS →
Overview → Full (strict)**. Explain the trade-off: proxied adds Cloudflare's
CDN/WAF but Cloudflare then terminates TLS; "Full (strict)" keeps it encrypted to
the origin's Let's Encrypt cert. Leaving it DNS-only is perfectly fine too.

## Phase 6 — First deploy

1. Make sure the local Docker daemon is running (Kamal builds the image
   locally): `docker info` succeeds. If the user's Mac is arm64 and the builder
   targets `amd64`, the build is emulated — slower, but works.
2. Note that Kamal builds from a **git clone of committed code**, so any
   uncommitted changes won't be in the image. Tell the user if `git status`
   shows relevant uncommitted work.
3. Run the first-time setup, which bootstraps the server and deploys:

   ```bash
   bin/kamal setup
   ```

   This can take several minutes (image build/push, then kamal-proxy requesting
   the TLS cert). Run it in the background and stream progress. If the cert step
   hangs, the usual causes are: DNS not resolving yet, a Cloudflare-proxied
   (orange) record instead of DNS-only, or port 80 blocked.
4. Verify it's live: `curl -I https://<DOMAIN>` returns `200`/`301`, and check
   the cert issuer is Let's Encrypt. `bin/kamal app details` shows the container.

For subsequent releases the command is just `bin/kamal deploy`. Mention this.

## Phase 7 — Set up backups

Getting "live" is not the same as "durable". A single-server SQLite app keeps its
database (and Solid Queue/Cache/Cable) on **one Docker volume on one VM** — if the
disk or VM dies, the data is gone. Set up **two complementary layers**, and
recommend doing **both**:

- **Litestream** — continuous, point-in-time replication of the SQLite database
  to S3-compatible object storage. Recovers data with seconds of loss.
- **Hetzner backups** — daily whole-VM snapshots. Recovers the entire machine
  (OS, config, volumes) if the server itself is lost.

### 7a — Litestream (via the `litestream` gem)

This app already runs Solid Queue inside Puma, so run Litestream the same way —
the gem ships a **Puma plugin**, no extra Kamal role or container needed.

1. **Pick a replica target** (S3-compatible). Recommend **Hetzner Object Storage**
   (same provider, cheap, EU), or Cloudflare R2 / Backblaze B2 / AWS S3. The user
   creates a bucket and an access key (key id + secret) — guide them; you don't
   create cloud resources.
2. **Add the gem** and run the installer:

   ```bash
   bundle add litestream
   bin/rails generate litestream:install
   ```

   This creates `config/litestream.yml` and `config/initializers/litestream.rb`.
3. **Enable the Puma plugin** in `config/puma.rb` (only in production):

   ```ruby
   plugin :litestream if ENV.fetch("RAILS_ENV", "development") == "production"
   ```

4. **Point `config/litestream.yml` at the production DB and the replica.** The
   default Rails 8 SQLite path is `storage/production.sqlite3` (mounted at
   `/rails/storage` in the container). Use env vars for the replica so no secrets
   are committed:

   ```yaml
   dbs:
     - path: storage/production.sqlite3
       replicas:
         - type: s3
           bucket: $LITESTREAM_REPLICA_BUCKET
           path: rubygrids/production
           endpoint: $LITESTREAM_REPLICA_ENDPOINT   # set for non-AWS (Hetzner/R2/B2)
           region: $LITESTREAM_REPLICA_REGION
           access-key-id: $LITESTREAM_ACCESS_KEY_ID
           secret-access-key: $LITESTREAM_SECRET_ACCESS_KEY
   ```

5. **Wire the env vars into Kamal.** In `config/deploy.yml` add the non-secret
   ones under `env.clear` (bucket/endpoint/region) and the credentials under
   `env.secret`:

   ```yaml
   env:
     clear:
       LITESTREAM_REPLICA_BUCKET: <bucket>
       LITESTREAM_REPLICA_ENDPOINT: <endpoint>   # omit for AWS S3
       LITESTREAM_REPLICA_REGION: <region>
     secret:
       - RAILS_MASTER_KEY
       - LITESTREAM_ACCESS_KEY_ID
       - LITESTREAM_SECRET_ACCESS_KEY
   ```

   And in `.kamal/secrets`, read the credentials from the environment / a password
   manager — never literals:

   ```bash
   LITESTREAM_ACCESS_KEY_ID=$LITESTREAM_ACCESS_KEY_ID
   LITESTREAM_SECRET_ACCESS_KEY=$LITESTREAM_SECRET_ACCESS_KEY
   ```

6. **Deploy and verify.** `bin/kamal deploy`, then confirm replication is healthy:

   ```bash
   bin/kamal app exec -i 'bin/rails runner "Litestream.verify!(\"storage/production.sqlite3\")"'
   ```

   Explain that **restore** (for a real recovery) is `bin/rails litestream:restore
   -- --database=storage/production.sqlite3` after stopping the app — but don't run
   it now; it's destructive to the current DB.

### 7b — Hetzner backups (whole-VM snapshots)

The user enables these in the console (you don't touch the provider): **Server →
Backups → Enable Backups**. It's ~20% of the server price, runs daily, and keeps
7 rolling snapshots. Explain this complements Litestream: Litestream gives
near-zero-loss DB recovery; Hetzner backups rebuild the whole box.

## Phase 8 — Wrap up

Give the user a short summary:

- Server IP, deploy user, and the one-liner to SSH in.
- What hardening was applied (firewall ports, fail2ban and whether the user's IP
  is whitelisted, auto-updates, auto-reboot window if set, no root / no password
  SSH).
- **What was skipped** — every item the user didn't select in the Phase 1
  multi-select, and how to come back to it later.
- Registry in use and where the token lives.
- DNS provider used and whether Cloudflare is in front.
- Backups: Litestream replica target + that Hetzner backups are on.
- The live URL and the day-2 operations toolkit:

  ```bash
  bin/kamal deploy            # ship a new release
  bin/kamal rollback          # revert to the previous version
  bin/kamal app logs -f       # tail application logs
  bin/kamal proxy logs -f     # kamal-proxy / TLS logs
  bin/kamal app exec -i "bin/rails console"   # production console
  bin/kamal app details       # container status
  ssh <DEPLOY_USER>@<SERVER_IP>               # get on the box

  # re-audit the server's hardening anytime (read-only, exit 0 = all good):
  ssh <DEPLOY_USER>@<SERVER_IP> 'sudo bash -s' -- <DEPLOY_USER> < <SKILL_DIR>/scripts/check-hardening.sh
  ```

- A reminder: this skill works for future apps too — run it from any Kamal app
  and reuse the same server (add it to `servers.web`) or use a new one.

Offer to commit the `config/deploy.yml` / `.kamal/secrets` changes (secrets file
should reference env vars / commands, never literal tokens) on a branch.

## Things to NOT do

- **Never create, modify, or delete cloud servers/projects, or use provider
  CLIs/APIs.** The user creates the server; you start from the IP they give you.
- Don't touch the server before the user has confirmed the Phase 1 checklist in
  the multi-select — and don't re-offer or redo what the inspection showed is
  already in place.
- Don't skip the fail2ban whitelist question, and don't read a `Too many
  authentication failures` error as proof that hardening worked — it usually
  just means the client offered too many keys.
- Don't disable root login (Phase 3d) before the deploy user is verified (3b).
- Don't deploy before DNS resolves — the Let's Encrypt cert will fail.
- Don't put the apex record on Cloudflare's proxy (orange cloud) during the
  first deploy.
- Don't write registry tokens or the master key as literals into any file —
  `.kamal/secrets` reads them from the environment / a command.
- Don't set `ssh.user` to root after hardening; it will lock Kamal out.
- Don't run `bin/kamal setup` without showing the user first — it has
  real-world effect.
- Don't run `litestream:restore` or `db:drop` as part of *setting up* backups —
  those are recovery operations that overwrite the live database. Only verify.

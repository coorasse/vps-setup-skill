# vps-setup-skill

A [Claude Code](https://claude.com/claude-code) skill that takes a
[Kamal](https://kamal-deploy.org)-based Rails app from a bare Ubuntu VPS to a
live, hardened production server — interactively, one phase at a time.

You bring a fresh server's IP and an SSH key; the skill provisions and hardens
the box, configures Kamal, points DNS at it, runs the first deploy, and sets up
off-server backups.

## What it does

| Phase | What happens |
|------|--------------|
| 0 | Pre-flight: checks the repo is a Kamal Rails app, reads `deploy.yml`/secrets, confirms an SSH key |
| 1 | Inspects the server's current state and confirms a checklist of proposed actions with you (multi-select) — already-satisfied items aren't re-offered |
| 2 | **You** create the VPS (Hetzner instructions provided); the skill starts from the IP |
| 3 | Provisions & hardens the box over SSH, then verifies it with a read-only audit — see [How the server is hardened](#how-the-server-is-hardened) |
| 4 | Configures Kamal: servers, registry, `ssh.user`, secrets |
| 5 | Points DNS at the server (any provider; Cloudflare optional) |
| 6 | First deploy (`kamal setup`) with Let's Encrypt TLS, then verifies the site is live |
| 7 | Backups: Litestream (continuous SQLite replication) + Hetzner VM snapshots |
| 8 | Wrap-up + day-2 operations toolkit (including what was skipped) |

It **never** creates, selects, or deletes cloud servers/projects, and never runs
provider CLIs/APIs — you own that step, so there's no risk of it touching the
wrong account.

## How the server is hardened

Phase 3 runs `scripts/provision.sh` (idempotent, safe to re-run) and then, only
once the new deploy user is proven to work, `scripts/harden-ssh.sh`. Each
protection and why it's there:

**Access**

- **A non-root `deploy` user** — created with its own home and shell, with
  root's `authorized_keys` copied across so your existing key keeps working. It
  gets `docker` group membership and passwordless sudo through a dedicated
  `/etc/sudoers.d/<user>` file (validated with `visudo -c` before it counts).
  Kamal then deploys as this user instead of root, so a compromised deploy
  credential isn't automatically root.
- **Key-only SSH** — `PasswordAuthentication no` and
  `KbdInteractiveAuthentication no`, so password guessing is off the table
  entirely no matter how weak an account password is.
- **Root login disabled** — `PermitRootLogin no`. Attackers must first guess a
  valid username, and every privileged action goes through a named account.
  Both SSH changes land as `sshd_config.d` drop-ins and are applied only after
  `sshd -t` validates the config, so a typo can't lock you out of the box.

**Network exposure**

- **UFW firewall** — default *deny* incoming, allow outgoing, with only `22`
  (SSH), `80` and `443` (HTTP/S for kamal-proxy and Let's Encrypt) opened, and
  logging on. Everything else a package might start listening on is unreachable
  from the internet.
- **fail2ban with an `sshd` jail** — systemd backend, `maxretry = 5`,
  `findtime = 10m`, `bantime = 1h`, enabled at boot. Repeated failed logins get
  the source IP dropped, which cuts off SSH brute-forcing before it becomes a
  problem.
- **An optional whitelist for your own IP** — the skill always offers to add
  your current public IP to fail2ban's `ignoreip`. This matters more than it
  sounds: an SSH agent that offers many keys (1Password with ~20 keys, say)
  burns several failed auths *per connection*, so a couple of ordinary logins
  can ban **you** for the full hour. The app keeps serving; you just can't get
  in.

**Staying patched**

- **Unattended security upgrades** — APT refreshes package lists and installs
  security updates automatically, so the box doesn't drift months behind on
  known CVEs between deploys.
- **An optional automatic-reboot window** — `unattended-upgrades` never reboots
  on its own, so a kernel or libc update can sit unapplied indefinitely. The
  skill offers to set a reboot time in the server's local timezone (it checks
  and can set the timezone too), trading a few seconds of downtime in a quiet
  hour for updates that actually take effect.

**Stability**

- **A swap file** — sized on request (2 GB default), persisted in `/etc/fstab`
  with `vm.swappiness=20` in `/etc/sysctl.d/`. It gives a small VM headroom so
  a memory spike degrades performance instead of triggering the OOM killer.
- **Docker** — installed and enabled at boot, ready for Kamal.

A caveat the skill is explicit about: Docker manipulates iptables directly and
can bypass UFW for *published* container ports. Kamal only publishes 80/443,
which are open anyway, so the two stay consistent — but anything else you
publish by hand will be reachable regardless of UFW.

## Verifying the hardening

`scripts/check-hardening.sh` is a **read-only** auditor: it changes nothing,
re-runs safely anytime, and exits `0` only when every required check passes
(`1` if any `FAIL`). `WARN`s are advisory and never affect the exit code, so an
agent — or a cron job — can confirm the server's posture deterministically
instead of eyeballing scrollback.

```bash
ssh deploy@SERVER_IP 'sudo bash -s' -- deploy < scripts/check-hardening.sh
```

What it checks, and how each result is graded:

| Group | Checks | Grading |
|-------|--------|---------|
| SSH hardening | `PasswordAuthentication no`, `PermitRootLogin no`, `KbdInteractiveAuthentication no` | first two `FAIL`, third `WARN` |
| Firewall | UFW active; default incoming policy is deny; ports 22/80/443 allowed | first two `FAIL`, missing ports `WARN` |
| fail2ban | service running; enabled at boot; the `sshd` jail actually active | running + jail `FAIL`, boot-enable `WARN` |
| Security updates | `unattended-upgrades` installed; `20auto-upgrades` enables both list refresh and unattended installs | `FAIL` |
| Reboot window | auto-reboot configured (reports the time and timezone); flags a currently pending reboot | `WARN` — it's optional |
| Swap | swap active (reports device and size); `vm.swappiness <= 20` | `WARN` |
| Deploy user | user exists; in the `docker` group; has `/etc/sudoers.d/<user>`; has a non-empty `authorized_keys` | existence + keys `FAIL`, rest `WARN` |
| Docker | daemon running | `FAIL` |
| Public listeners | enumerates every TCP socket bound to all interfaces; 22/80/443 are expected, anything else is called out for review | `WARN` |

Two details worth knowing. The SSH checks read the **effective** config via
`sshd -T` rather than grepping files, so an override in an include, a stale
drop-in, or a config that never got reloaded can't hide a mistake. And the
public-listener sweep is what catches the classic accident — a database or
admin port published to `0.0.0.0` by a container, which UFW won't stop.

It ends with a `PASS/WARN/FAIL` summary. Any `FAIL` almost always means a
provisioning or hardening step didn't apply, and is worth fixing before you
deploy.

## Install

Clone into your Claude Code skills directory. The skill's name (from the
`SKILL.md` frontmatter) is `setup-vps`, so use that as the folder name:

```bash
git clone https://github.com/coorasse/vps-setup-skill.git ~/.claude/skills/setup-vps
```

Or add it to a project instead of globally:

```bash
git clone https://github.com/coorasse/vps-setup-skill.git .claude/skills/setup-vps
```

## Use

In Claude Code, run `/setup-vps`, or just ask: *"set up a production server"*,
*"deploy this app to a VPS"*, *"go live"*. The skill is interactive and will
prompt you for the domain, registry, deploy user, DNS choice, and so on.

## Requirements

- A Rails app already set up for Kamal (`bin/kamal`, `Dockerfile`,
  `config/deploy.yml`). `bin/rails new` on Rails 8 gives you this by default.
- Local Docker (Kamal builds the image locally).
- An SSH key, and a fresh Ubuntu VPS you've created with that key authorized.

## Contents

- `SKILL.md` — the skill definition and step-by-step procedure.
- `scripts/provision.sh` — idempotent server setup + `deploy` user (run as root).
  Installs Docker and base tooling, unattended security upgrades, the fail2ban
  `sshd` jail, the UFW ruleset, and a swap file. It deliberately does *not*
  touch SSH access, so a mistake here can't lock you out.
- `scripts/harden-ssh.sh` — disables password auth and root login (run only
  after verifying the deploy user works). Validates with `sshd -t` before
  restarting the daemon.
- `scripts/check-hardening.sh` — the read-only auditor described in
  [Verifying the hardening](#verifying-the-hardening). Exits non-zero on any
  failure; re-runnable anytime as a day-2 check.

## License

[MIT](LICENSE)

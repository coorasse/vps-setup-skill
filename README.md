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
| 3 | Provisions & hardens over SSH: Docker, UFW, fail2ban (with an optional whitelist for your own IP), unattended-upgrades, swap, a non-root `deploy` user, then disables root/password SSH. Optional automatic-reboot window, then a read-only audit that verifies every protection |
| 4 | Configures Kamal: servers, registry, `ssh.user`, secrets |
| 5 | Points DNS at the server (any provider; Cloudflare optional) |
| 6 | First deploy (`kamal setup`) with Let's Encrypt TLS, then verifies the site is live |
| 7 | Backups: Litestream (continuous SQLite replication) + Hetzner VM snapshots |
| 8 | Wrap-up + day-2 operations toolkit (including what was skipped) |

It **never** creates, selects, or deletes cloud servers/projects, and never runs
provider CLIs/APIs — you own that step, so there's no risk of it touching the
wrong account.

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
- `scripts/harden-ssh.sh` — disables password auth and root login (run after
  verifying the deploy user works).
- `scripts/check-hardening.sh` — read-only audit that verifies the protections
  applied by the other two scripts (SSH lockdown, UFW, fail2ban, auto-updates,
  swap, deploy user, Docker). Exits non-zero on any failure, so an agent or human
  can confirm hardening deterministically instead of eyeballing it. Re-runnable
  anytime as a day-2 check.

## License

[MIT](LICENSE)

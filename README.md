# Sentinel Control Node Installation

This document describes how to bootstrap a fresh RHEL-family host
(Rocky Linux 9, CentOS Stream 9, Alma 9) into a working Sentinel
control node. The procedure runs in a single shell session and
produces a host with Docker, the unprivileged `ansible` service
account, and the orchestration repository cloned and ready to use.

The installer (`install.sh`) is a thin launcher that downloads and
runs a more substantial `bootstrap.sh` script from the orchestration
repository. The two scripts together perform the actual
provisioning.

## Prerequisites

- A freshly provisioned RHEL-family host with network access to
  `github.com` and `download.docker.com`.

- Root access on that host (either direct login or `sudo -i`).

- A GitHub Personal Access Token (PAT) with at least `repo` scope on
  the `hostpapa/puppet-migration` private repository. Generate one
  at <https://github.com/settings/tokens> if you do not already have
  one. Fine-grained PATs work as well as classic.

- If you want the control node to be able to SSH to itself (which
  Ansible needs when the `puppetmaster` host is in its own
  inventory), the host's SSH key must be present at
  `/root/.ssh/<name>` before running the installer. On HostPapa
  infrastructure these keys are typically pre-placed by the OS
  provisioning system (Cobbler / cloud-init), so no manual step is
  required — verify with `ls /root/.ssh/`.

## Quick start

```bash
sudo -i
curl -sSL https://raw.githubusercontent.com/hostpapa/puppet-migration-install/main/install.sh \
    -o /usr/local/sbin/install.sh
chmod +x /usr/local/sbin/install.sh

# Provision, with the host's existing SSH key authorized for self-SSH:
/usr/local/sbin/install.sh --token ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
                           -- --priv-key id_ed25519
```

Replace `ghp_xxx...` with your PAT and `id_ed25519` with the actual
filename of the private key in `/root/.ssh/`. The installer will:

1. Validate the PAT against the GitHub API.
2. Download `bootstrap.sh` from the private repository.
3. Hand off to `bootstrap.sh` under `sudo`, which performs the
   actual host provisioning (Docker install, user creation,
   `authorized_keys` provisioning, repository clone).

On success, you will see `Sentinel Host Provisioning Complete`
followed by next-step instructions. Total runtime is typically 1–3
minutes depending on network and disk speed.

## Command-line reference

The installer separates **its own options** from **options
forwarded to bootstrap.sh** with a `--` delimiter. Everything
before `--` is for the installer; everything after is passed
verbatim to `bootstrap.sh`.

### Installer options (before `--`)

| Option | Description |
|---|---|
| `--token <pat>` | GitHub PAT. Overrides positional argument and `GITHUB_TOKEN` env var. |
| `<pat>` (positional) | Same as `--token`, but bare. Overrides env, not `--token`. |
| `--dry-run` | Download and validate the bootstrap payload, then print the command that would run it. Does not execute. |
| `--secrets` | In dry-run mode, render the PAT inline in the printed command. By default the PAT is referenced as `"$GITHUB_TOKEN"`. Use with care. |
| `-h`, `--help` | Show inline help. |

Token resolution precedence, highest to lowest: `--token` →
positional → `GITHUB_TOKEN` environment variable.

### Bootstrap options (after `--`)

These are options of the **downloaded** `bootstrap.sh`. The
installer does not interpret them; it forwards them through `sudo`
unchanged.

| Option | Description |
|---|---|
| `--priv-key <name>` | Filename in `/root/.ssh/`. The public component is derived via `ssh-keygen -y` and appended to `/root/.ssh/authorized_keys`, enabling SSH-to-self. The file `<name>` must exist as a private key; passphrase-protected keys are rejected. The bootstrap recomputes the public component from the private key every run rather than trusting any neighbouring `<name>.pub` on disk. |
| `--save` | Persist the PAT to `/var/ansible/.bashrc.d/github_token.sh` (mode `0600`, owner `ansible`). Useful if Day-2 operations need API access before GitHub Apps are provisioned. Omitted by default — the PAT is never written to disk unless this flag is given. |

### Common invocations

Minimum required — just provision the host, no SSH self-auth, no
saved token:

```bash
/usr/local/sbin/install.sh --token ghp_xxx
```

Standard — with self-SSH (matches HostPapa control-node usage):

```bash
/usr/local/sbin/install.sh --token ghp_xxx -- --priv-key id_ed25519
```

Dry-run to inspect what would happen, without executing:

```bash
/usr/local/sbin/install.sh --token ghp_xxx --dry-run -- --priv-key id_ed25519
```

Persist PAT to disk (only if you understand the trade-off):

```bash
/usr/local/sbin/install.sh --token ghp_xxx -- --save --priv-key id_ed25519
```

## Verification

After `install.sh` completes, switch to the `ansible` user and
confirm the workspace is in place:

```bash
sudo -iu ansible
cd /var/ansible/workspace
ls
docker --version
```

You should see the repository contents and a working Docker CLI.
From here, continue with the workspace initialization steps
documented in `SETUP.md`.

## Security notes

- **PAT handling.** The installer never writes the PAT to disk
  unless `--save` is explicitly passed. The PAT is passed to
  `bootstrap.sh` through the environment (not argv), so it does
  not appear in `ps`, `/proc/<pid>/cmdline`, or sudo logs. During
  `git clone`, the PAT is fed to git via `GIT_CONFIG_*` environment
  variables (not `-c` command-line flags and not the URL), keeping
  it out of `.git/config` and the process table.

- **Git authentication.** The bootstrap clones the orchestration
  repository over HTTPS using HTTP Basic auth (`git:<PAT>`). This
  is the only scheme GitHub's git-over-HTTPS endpoint accepts
  reliably — `Bearer` and `token` schemes work against the REST
  API but are rejected for git operations.

- **SSH self-authorization (`--priv-key`).** The public component
  is derived from the private key on disk using `ssh-keygen -y`.
  Any pre-existing `<name>.pub` file alongside the private key is
  ignored, because the private key is the only artifact the
  bootstrap is willing to trust (it has been demonstrated to
  authenticate against real infrastructure; a neighbouring `.pub`
  file has no such guarantee). Re-running the installer with the
  same key is idempotent — `authorized_keys` is checked for an
  exact match before appending.

- **Network reachability.** The bootstrap performs an explicit
  reachability check against `github.com` before installing
  packages, so air-gapped or proxy-misconfigured hosts fail fast
  rather than after multi-minute `dnf install` operations.

## Troubleshooting

**`Critical: Token validation failed (HTTP 401)`** — the PAT was
rejected by `api.github.com/user`. Either the PAT is invalid,
expired, or revoked. Check at <https://github.com/settings/tokens>.

**`Critical: Token validation failed (HTTP 403)`** — the PAT is
valid but lacks the required scopes. For classic PATs, the `repo`
scope is required. For fine-grained PATs, ensure
`hostpapa/puppet-migration` is in the resource list with
`Contents: Read` permission.

**`Critical: --priv-key requested but /root/.ssh/<name> does not
exist`** — the file is missing from `/root/.ssh/`. List the
directory (`ls /root/.ssh/`) and confirm the name. The argument is
the **filename** only, not a path.

**`Critical: Failed to derive public component from <path>
(passphrase-protected key not supported here)`** — the private key
is encrypted with a passphrase. The installer cannot prompt for
the passphrase non-interactively. Either decrypt the key
(`ssh-keygen -p -f <key> -P 'old' -N ''`) or use a different key.

**Clone fails with `fatal: could not read Username for
'https://github.com': terminal prompts disabled`** — GitHub
returned HTTP 401 on the git-over-HTTPS endpoint. The PAT
authenticated against the REST API (otherwise the installer would
have aborted earlier) but failed on the git endpoint. The most
common cause is SAML SSO for the `hostpapa` organization: the PAT
needs to be explicitly authorized for `hostpapa` org via the
"Configure SSO" button on the token settings page.

## Source and updates

This installer is distributed from
<https://github.com/hostpapa/puppet-migration-install>, which is
**automatically synchronized** from the upstream private repository
<https://github.com/hostpapa/puppet-migration> on every change to
`install.sh` or `INSTALL.md`. **Do not commit changes directly to
the public installer repository** — they will be overwritten on
the next sync. All edits must go through the upstream repository.

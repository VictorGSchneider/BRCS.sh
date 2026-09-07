# BRCS.sh - Linux System Maintenance CLI

A command-line tool to back up and restore Linux system configurations, clean up unnecessary files, and schedule automatic maintenance at system startup. Works on any major Linux distribution.

BRCS is an acronym for **B**ackup, **R**estoration, **C**leaner and **S**chedule.

## Features

### Backup
- Configuration files under `/etc/` (`.conf`, `.ini`, `.rules`)
- User dotfiles (`.bashrc`, `.zshrc`, `.vimrc`, `.gitconfig`, `.tmux.conf`, etc.)
- Crontabs and `/etc/cron.d`
- Systemd custom units (`.service`, `.timer`, `.mount`, `.socket`)
- SSH configs (`config`, `authorized_keys`, `sshd_config`)
- Firewall rules (iptables, nftables, ufw, firewalld)
- Network configs (NetworkManager, netplan, systemd-networkd)
- System files (`/etc/fstab`, `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`, etc.)
- Package repo configs (detected per distro)
- Shell scripts in `$HOME`

### Restore
- Interactive mode: review diffs and choose per file
- Bulk mode: restore everything at once
- Validates zip integrity before restoring
- Creates a safety backup of existing files before overwriting
- List backup contents without restoring (`--list`)

### Cleanup

Eleven steps, reporting the disk space freed at the end:

| # | Step | Notes |
|---|------|-------|
| 1 | Update and upgrade every package | changes what is installed |
| 2 | Trim the package manager cache | |
| 3 | Remove orphaned packages | changes what is installed |
| 4 | Drop disabled Snap revisions | |
| 5 | Uninstall unused Flatpak runtimes | |
| 6 | Vacuum the systemd journal to 7 days / 100 MB | |
| 7 | Remove old kernels | apt and dnf only |
| 8 | `docker system prune` | drops stopped containers |
| 9 | Clear the Steam **shader** cache | |
| 10 | Regenerable user caches: thumbnails, pip, npm, yarn | see below |
| 11 | Whole caches idle 90+ days — programs you no longer use | see below |
| 12 | Leftovers: keep the 2 newest archives of each kind; sweep `.log`/`.bak` older than 30 days | see below |
| 13 | Clear `/tmp` and `/var/tmp` | skips files in use |

Step 10 clears only caches that come back on their own — the cost of
deleting them is the time to rebuild, nothing more. It deliberately does
**not** clear `~/.cache` wholesale (applications keep real state there,
not just cache), the trash (you may still want those files), or the Go
module cache (regenerable, but gigabytes of re-download).

Step 11 removes whole directories under `~/.cache` that nothing has
written to in `BRCS_STALE_CACHE_DAYS` (default 90) — a program you stopped
using, or removed and whose cache outlived it. Age is the only honest
signal here: a directory name under `~/.cache` rarely matches a binary
name, so "is this program still installed" cannot be asked reliably, but
"has anything written here since April" can.

Age is read from **the newest file anywhere inside**, not the directory's
own timestamp — a directory's mtime only moves when entries are added or
removed at its top level, so a cache written four levels down would look
untouched for years.

These are kept however old they are, because they are regenerable as
gigabytes of re-download rather than seconds of rebuild: `huggingface`,
`torch`, `ms-playwright`, `pre-commit`, `go-build`, `bazel`, `ccache`.
Only directories are candidates; a loose file at the top of `~/.cache` is
never touched. Preview it first with `--dry-run`, which names each cache
and its size.

Step 12 sweeps `.log` and `.bak` from the top level of `$HOME` and from
`~/.cache`, and `.bak` only from `~/.config` and `~/.local/share` — a
`.log` under those two may well be an application's real log. `/var/log`
is never touched: those files belong to services that hold them open, and
step 6 covers the journal.

Steam `compatdata` is never deleted. It sits next to `shadercache` and
holds the Proton prefixes, so unless a game uses Steam Cloud its saves
live in there. Releases up to 2.0.0 wiped it as "compat cache"; 2.1.0
does not.

- Dry-run mode (`--dry-run`) previews every step without making changes
- Unattended mode (`--unattended`) runs only steps 2, 5, 6, 12 and 13
- User mode (`--user`) never calls sudo at all — see below

### Cleanup without sudo (`--user`)

For a machine you do not administer — a work laptop, a shared server, a
university cluster. It runs **seven steps and never invokes sudo once**:

| Step | Unprivileged because |
|------|----------------------|
| Unused flatpak runtimes | `--user` confines it to your per-user installation |
| Your journal, vacuumed to 7d / 100M | `journalctl --user` — your own journal |
| `docker system prune` | needs no sudo if you are in the `docker` group |
| Steam shader cache | lives in `$HOME` |
| Regenerable caches (thumbnails, pip, npm, yarn) | live in `$HOME` |
| Whole caches idle 90+ days | live in `$HOME` |
| Leftovers | lives in `$HOME` |
| `/tmp` and `/var/tmp` | **restricted to files you own** — the rest is not yours to delete |

```bash
./BRCS.sh --cleanup --user
./BRCS.sh --cleanup --user --dry-run    # preview first
```

The package manager, snap, old kernels and the system journal are skipped
rather than attempted: they cannot be cleaned without root. The run says
so once at the start, so a short run is never a mystery.

Space freed is measured on the filesystem holding `$HOME`, not `/` — on a
managed machine those are very often different mounts, and measuring `/`
would report "no measurable space freed" every time.

If you run a privileged mode on a machine with no sudo, the error points
you here.

Set `BRCS_TMP_DIRS` to change which scratch directories step 13 sweeps
(default `/tmp /var/tmp`), and `BRCS_STALE_CACHE_DAYS` to change step 11's
idle threshold.

#### Scheduling it without root

```bash
./BRCS.sh --schedule --user
```

Installs a **systemd `--user` timer** running `--cleanup --user` five
minutes after you log in, then weekly. Undo with:

```bash
systemctl --user disable --now brcs-cleanup.timer
```

A `--user` timer only runs while you have a session — it is not a boot
timer, because a user manager does not exist before you log in. Making it
survive logout needs `loginctl enable-linger`, which is privileged; the
whole premise here is that you do not have that, so it is mentioned and
never attempted.

With no systemd user manager, it falls back to **your own crontab**
(`@daily`). That is the right place for this job and not a repeat of the
2.0.0 bug: what made the old `@reboot` line dangerous was that the job it
scheduled needed `sudo` with no terminal to authenticate on. This one
calls no sudo at all, so there is nothing to authenticate and nothing for
`pam_faillock` to count. The legacy sweep that removes the old entries is
careful to leave this one alone.

### Unattended cleanup and scheduling

`--schedule` installs a **root-owned systemd timer** that runs
`--cleanup --unattended` two minutes after each boot. To undo it:

```bash
sudo systemctl disable --now brcs-cleanup.timer
```

The scheduled job deliberately runs the safe subset: it deletes garbage
and changes nothing else. No upgrade, no package removal, no kernel
removal, no `docker system prune`, and no Steam step — a shader cache is
regenerable, but rebuilding it costs a stuttering first launch per game,
so wiping it on every boot is worse than useless.

On a host with no systemd the job goes into **root's** crontab, not
yours. Releases up to 2.0.0 put a `@reboot` line in the invoking user's
crontab, where it ran unprivileged with no terminal: every `sudo` inside
became a PAM "conversation failed", `pam_faillock` counted each one, and
after three the account was locked — at the login screen, on the next
boot. `--schedule` now removes that entry wherever it finds it.

### General
- Full CLI interface for scripting and automation
- Interactive terminal menu for manual use
- Timestamped color-coded logging (INFO, WARN, ERROR)
- Terminal progress bar for all operations
- Signal trapping for safe temp file cleanup
- Refuses to run privileged work with no terminal to authenticate on,
  rather than tripping `pam_faillock` (see *Unattended cleanup* above)

## Supported Distributions

| Package Manager | Distributions |
|----------------|---------------|
| `apt` | Debian, Ubuntu, Linux Mint, Zorin OS, Pop!_OS |
| `dnf` | Fedora, RHEL 9+, CentOS Stream |
| `yum` | CentOS 7, RHEL 7/8 |
| `pacman` | Arch Linux, Manjaro, EndeavourOS |
| `zypper` | openSUSE Tumbleweed/Leap, SLES |
| `apk` | Alpine Linux |

## Requirements

- `bash` (version 3.2+)
- `zip` and `unzip`

Optional tools (used automatically if available):
- `locate` or `mlocate`/`plocate` (faster file search; falls back to `find`)
- `deborphan`, `localepurge` (Debian-based cleanup)
- `paccache` (Arch cache cleanup)
- `flatpak`, `snap`, `docker` (cleaned if present)
- `lsof` or `fuser` (safe temp file cleanup)
- `diff` (interactive restore diffs)

### Install on Debian/Ubuntu
```bash
sudo apt install zip unzip mlocate
```

### Install on Fedora
```bash
sudo dnf install zip unzip mlocate
```

### Install on Arch
```bash
sudo pacman -S zip unzip mlocate
```

## Usage

### Interactive menu

```bash
chmod +x BRCS.sh
./BRCS.sh
```

```
=== BRCS v2.3.0 - System Maintenance ===
1) Backup configurations
2) Restore configurations
3) Full system cleanup
4) Full system cleanup (dry-run)
5) Safe cleanup only (what the boot job runs)
6) Cleanup without sudo (your own files only)
7) List backup contents
8) Schedule cleanup at boot
9) Exit
```

### CLI (non-interactive)

```bash
# Backup all configurations
./BRCS.sh --backup

# Restore all from a backup file
./BRCS.sh --restore backup.zip

# Restore interactively (review each file)
./BRCS.sh --restore-interactive backup.zip

# List contents of a backup
./BRCS.sh --list backup.zip

# Run full system cleanup
./BRCS.sh --cleanup

# Preview cleanup without making changes
./BRCS.sh --dry-run --cleanup

# Run only the steps that are safe without someone watching
./BRCS.sh --cleanup --unattended

# Clean without sudo, on a machine where you have no permission
./BRCS.sh --cleanup --user

# Schedule the unattended cleanup at boot (root-owned systemd timer)
./BRCS.sh --schedule

# Schedule the unprivileged cleanup, no root (systemd --user timer)
./BRCS.sh --schedule --user

# Show help
./BRCS.sh --help
```

## Backups

Backup files are saved to `$HOME` as `hostname.confs.YYYYMMDD.zip`. Set
`BRCS_BACKUP_DIR` to put them somewhere else:

```bash
BRCS_BACKUP_DIR=/mnt/backups ./BRCS.sh --backup
```

Before overwriting anything, a restore first saves what it is about to
replace, to `pre_restore_YYYYMMDD_HHMMSS.zip` in the same directory.

Logs are saved to: `~/backup_YYYYMMDD.log`

Up to 2.0.0 the archive path was relative, so it landed in whatever
directory you happened to be standing in and `--list` could not find it
again. It is anchored from 2.1.0 on.

## License

This project is licensed under the terms of the [GNU General Public License v3.0](LICENSE).

## Contributing

To run the test suite you need the [Bats](https://github.com/bats-core/bats-core)
framework and [ShellCheck](https://www.shellcheck.net/). Install them via your
package manager (e.g. `sudo apt install bats shellcheck`) and then run what CI
runs:

```bash
bash -n BRCS.sh
shellcheck -S warning BRCS.sh test/*.bats
bats test/
```

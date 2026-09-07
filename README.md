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
| 10 | Leftovers: keep the 2 newest archives of each kind; sweep `.log`/`.bak` older than 30 days | see below |
| 11 | Clear `/tmp` and `/var/tmp` | skips files in use |

Step 10 sweeps `.log` and `.bak` from the top level of `$HOME` and from
`~/.cache`, and `.bak` only from `~/.config` and `~/.local/share` — a
`.log` under those two may well be an application's real log. `/var/log`
is never touched: those files belong to services that hold them open, and
step 6 covers the journal.

Steam `compatdata` is never deleted. It sits next to `shadercache` and
holds the Proton prefixes, so unless a game uses Steam Cloud its saves
live in there. Releases up to 2.0.0 wiped it as "compat cache"; 2.1.0
does not.

- Dry-run mode (`--dry-run`) previews every step without making changes
- Unattended mode (`--unattended`) runs only steps 2, 5, 6, 10 and 11

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
=== BRCS v2.1.0 - System Maintenance ===
1) Backup configurations
2) Restore configurations
3) Full system cleanup
4) Full system cleanup (dry-run)
5) Safe cleanup only (what the boot job runs)
6) List backup contents
7) Schedule cleanup at boot
8) Exit
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

# Schedule the unattended cleanup at boot (root-owned systemd timer)
./BRCS.sh --schedule

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

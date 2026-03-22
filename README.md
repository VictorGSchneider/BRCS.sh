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
- Update and upgrade system packages
- Clean package manager cache
- Remove orphaned/unused packages
- Clean systemd journal logs (vacuum to 7d / 100MB)
- Remove old kernels (apt, dnf)
- Clean disabled Snap revisions
- Remove unused Flatpak runtimes
- Prune Docker resources
- Clear Steam shader/compat cache
- Clean `/tmp` and `/var/tmp` (skips files in use)
- Reports disk space freed at the end
- Dry-run mode to preview without making changes

### General
- Full CLI interface for scripting and automation
- Interactive terminal menu for manual use
- Timestamped color-coded logging (INFO, WARN, ERROR)
- Terminal progress bar for all operations
- Signal trapping for safe temp file cleanup
- Root/sudo check before privileged operations

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
=== BRCS v2.0.0 - System Maintenance ===
1) Backup configurations
2) Restore configurations
3) Full system cleanup
4) Full system cleanup (dry-run)
5) List backup contents
6) Schedule cleanup at boot
7) Exit
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

# Schedule cleanup at boot
./BRCS.sh --schedule

# Show help
./BRCS.sh --help
```

## Backups

Backup files are saved as: `hostname.confs.YYYYMMDD.zip`

Logs are saved to: `~/backup_YYYYMMDD.log`

## License

This project is licensed under the terms of the [GNU General Public License v3.0](LICENSE).

## Contributing

To run the test suite you need the [Bats](https://github.com/bats-core/bats-core) framework.
Install it via your package manager (e.g. `sudo apt install bats`) and then execute:

```bash
bats test
```

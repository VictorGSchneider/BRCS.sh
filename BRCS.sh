#!/bin/bash

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

VERSION="2.0.0"

# Hostname fallback and date for backup filename
MY_HOSTNAME="${HOSTNAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)}"
TODAY=$(date +%Y%m%d)
arq="$MY_HOSTNAME.confs.$TODAY.zip"
log="$HOME/backup_$TODAY.log"
USER_DIR="$HOME"
DRY_RUN=0

# --- Helper functions ---

log_msg() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    local reset="\e[0m"
    case "$level" in
        INFO)  color="\e[1;32m" ;;
        WARN)  color="\e[1;33m" ;;
        ERROR) color="\e[1;31m" ;;
    esac
    printf "${color}[%s] [%s]${reset} %s\n" "$ts" "$level" "$*"
    echo "[$ts] [$level] $*" >> "$log" 2>/dev/null
}

run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_msg INFO "[DRY-RUN] Would execute: $*"
        return 0
    else
        "$@"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        log_msg WARN "Not running as root and sudo not found. Some operations may fail."
        return 1
    fi
    return 0
}

# Detect the system package manager
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "unknown"
    fi
}

PKG_MANAGER=$(detect_pkg_manager)

# Signal trap for temp file cleanup
_BRCS_TEMPFILES=()
_brcs_cleanup() {
    for f in "${_BRCS_TEMPFILES[@]}"; do
        [ -e "$f" ] && rm -rf "$f"
    done
}

# Collect files into an array from find (compatible with bash 3+)
collect_files() {
    local dir="$1"
    _collected_files=()
    while IFS= read -r -d '' f; do
        _collected_files+=("$f")
    done < <(find "$dir" -type f -print0 2>/dev/null)
}

# Function: Show terminal progress bar with color
progress_bar() {
    local total=$1
    local current=$2
    local bar_length=30

    if [ "$total" -eq 0 ]; then
        percent=100
        filled=$bar_length
        empty=0
    else
        percent=$((current * 100 / total))
        filled=$((bar_length * percent / 100))
        empty=$((bar_length - filled))
    fi

    local bar_fill="" bar_empty=""
    local i
    for ((i = 0; i < filled; i++)); do bar_fill+="█"; done
    for ((i = 0; i < empty; i++)); do bar_empty+="░"; done

    printf "\r[\e[1;32m%s\e[0m%s] %3d%%" "$bar_fill" "$bar_empty" "$percent"
    [ "$current" -eq "$total" ] && echo
}

# Search for files using locate (if available) or find as fallback
search_files() {
    local pattern="$1"
    if command -v locate >/dev/null 2>&1; then
        locate "$pattern" 2>/dev/null
    else
        find / -name "*${pattern}" -type f 2>/dev/null
    fi
}

# Get distro-specific repo config patterns
get_repo_patterns() {
    case "$PKG_MANAGER" in
        apt)    echo "/etc/apt/sources.list /etc/apt/sources.list.d" ;;
        dnf|yum) echo "/etc/yum.repos.d" ;;
        pacman) echo "/etc/pacman.conf /etc/pacman.d" ;;
        zypper) echo "/etc/zypp/repos.d" ;;
        apk)    echo "/etc/apk/repositories" ;;
        *)      echo "" ;;
    esac
}

# Get disk usage of root filesystem in KB
get_disk_used_kb() {
    df / | awk 'NR==2{print $3}'
}

# --- Backup ---

backup_configs() {
    log_msg INFO "Starting backup..."

    if ! command -v zip >/dev/null 2>&1; then
        log_msg ERROR "'zip' is not installed. Please install it first."
        return 1
    fi

    local repo_patterns
    repo_patterns=$(get_repo_patterns)

    local total=0 count=0
    local all_files=""

    # Config files under /etc/
    for ext in .conf .ini .rules; do
        local found
        found=$(search_files "$ext" | grep '/etc/')
        [ -n "$found" ] && all_files+="$found"$'\n'
    done

    # Shell scripts in user home
    local found_sh
    found_sh=$(search_files ".sh" | grep '\.sh$' | grep "$USER_DIR")
    [ -n "$found_sh" ] && all_files+="$found_sh"$'\n'

    # System files
    for sysfile in /etc/fstab /etc/default/grub /etc/hostname /etc/resolv.conf /etc/hosts /etc/locale.conf /etc/vconsole.conf /etc/environment; do
        [ -f "$sysfile" ] && all_files+="$sysfile"$'\n'
    done

    # Repo config files
    for repo_path in $repo_patterns; do
        if [ -f "$repo_path" ]; then
            all_files+="$repo_path"$'\n'
        elif [ -d "$repo_path" ]; then
            local repo_files
            repo_files=$(find "$repo_path" -type f 2>/dev/null)
            [ -n "$repo_files" ] && all_files+="$repo_files"$'\n'
        fi
    done

    # User dotfiles
    for dotfile in .bashrc .bash_profile .bash_aliases .profile .zshrc .zprofile .vimrc .nanorc .gitconfig .tmux.conf .inputrc .wgetrc .curlrc; do
        [ -f "$USER_DIR/$dotfile" ] && all_files+="$USER_DIR/$dotfile"$'\n'
    done

    # User config directory (shallow scan for config files)
    if [ -d "$USER_DIR/.config" ]; then
        local cfg_files
        cfg_files=$(find "$USER_DIR/.config" -maxdepth 3 -type f \( -name '*.conf' -o -name '*.ini' -o -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)
        [ -n "$cfg_files" ] && all_files+="$cfg_files"$'\n'
    fi

    # Crontabs
    for crontab_path in "/var/spool/cron/crontabs/$(whoami)" "/var/spool/cron/$(whoami)" /etc/crontab; do
        [ -f "$crontab_path" ] && all_files+="$crontab_path"$'\n'
    done
    if [ -d /etc/cron.d ]; then
        local cron_files
        cron_files=$(find /etc/cron.d -type f 2>/dev/null)
        [ -n "$cron_files" ] && all_files+="$cron_files"$'\n'
    fi

    # Systemd custom units
    for unit_dir in /etc/systemd/system /etc/systemd/user "$USER_DIR/.config/systemd/user"; do
        if [ -d "$unit_dir" ]; then
            local unit_files
            unit_files=$(find "$unit_dir" -maxdepth 2 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.mount' -o -name '*.target' -o -name '*.socket' \) 2>/dev/null)
            [ -n "$unit_files" ] && all_files+="$unit_files"$'\n'
        fi
    done

    # SSH config (never backup private keys)
    for ssh_file in "$USER_DIR/.ssh/config" "$USER_DIR/.ssh/authorized_keys" /etc/ssh/sshd_config /etc/ssh/ssh_config; do
        [ -f "$ssh_file" ] && all_files+="$ssh_file"$'\n'
    done

    # Firewall rules
    for fw_file in /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/nftables.conf /etc/firewalld/firewalld.conf /etc/ufw/ufw.conf; do
        [ -f "$fw_file" ] && all_files+="$fw_file"$'\n'
    done
    if [ -d /etc/firewalld/zones ]; then
        local fwz
        fwz=$(find /etc/firewalld/zones -type f 2>/dev/null)
        [ -n "$fwz" ] && all_files+="$fwz"$'\n'
    fi

    # Network configs
    for net_dir in /etc/NetworkManager/system-connections /etc/netplan /etc/sysconfig/network-scripts /etc/systemd/network; do
        if [ -d "$net_dir" ]; then
            local net_files
            net_files=$(find "$net_dir" -type f 2>/dev/null)
            [ -n "$net_files" ] && all_files+="$net_files"$'\n'
        fi
    done

    # Remove empty lines and duplicates
    all_files=$(echo "$all_files" | sort -u | sed '/^$/d')

    if [ -z "$all_files" ]; then
        log_msg WARN "No configuration files found."
        return 1
    fi

    local line_count
    line_count=$(echo "$all_files" | wc -l)
    total=$line_count

    echo "$all_files" | while IFS= read -r filepath; do
        echo "$filepath"
        count=$((count + 1))
        progress_bar "$total" "$count" >&2
    done | zip "$arq" -r -9 -@ >> "$log" 2>&1

    local file_count
    file_count=$(echo "$all_files" | wc -l)
    local archive_size
    archive_size=$(du -h "$arq" 2>/dev/null | cut -f1)

    log_msg INFO "Backup saved as: $arq ($file_count files, $archive_size)"
}

# --- List backup contents ---

list_backup_contents() {
    local backup_file="${1:-}"
    [ -z "$backup_file" ] && read -r -p "Enter the path to the backup file (.zip): " backup_file
    [ ! -f "$backup_file" ] && log_msg ERROR "File not found: $backup_file" && return 1

    if ! unzip -t "$backup_file" >/dev/null 2>&1; then
        log_msg ERROR "Invalid or corrupted zip file: $backup_file"
        return 1
    fi

    log_msg INFO "Contents of: $backup_file"
    unzip -l "$backup_file"
}

# --- Restore (interactive) ---

restore_interactive() {
    check_root

    local backup_file="${1:-}"
    [ -z "$backup_file" ] && read -r -p "Enter the path to the backup file (.zip): " backup_file
    [ ! -f "$backup_file" ] && log_msg ERROR "File not found." && return 1

    if ! command -v unzip >/dev/null 2>&1; then
        log_msg ERROR "'unzip' is not installed. Please install it first."
        return 1
    fi

    if ! unzip -t "$backup_file" >/dev/null 2>&1; then
        log_msg ERROR "Invalid or corrupted zip file."
        return 1
    fi

    local TMPDIR_RESTORE
    TMPDIR_RESTORE=$(mktemp -d)
    _BRCS_TEMPFILES+=("$TMPDIR_RESTORE")
    unzip -o "$backup_file" -d "$TMPDIR_RESTORE" >/dev/null

    collect_files "$TMPDIR_RESTORE"
    local files=("${_collected_files[@]}")
    local total=${#files[@]}
    local count=0

    # Safety backup of files that will be overwritten
    local pre_restore_backup="$HOME/pre_restore_$(date +%Y%m%d_%H%M%S).zip"
    local existing_targets=()
    for FILE in "${files[@]}"; do
        local DEST="/${FILE#"$TMPDIR_RESTORE"/}"
        [ -f "$DEST" ] && existing_targets+=("$DEST")
    done
    if [ ${#existing_targets[@]} -gt 0 ] && command -v zip >/dev/null 2>&1; then
        log_msg INFO "Creating safety backup: $pre_restore_backup"
        zip -q "$pre_restore_backup" "${existing_targets[@]}" 2>/dev/null || true
    fi

    log_msg INFO "Restoring files (interactive)..."
    for FILE in "${files[@]}"; do
        DEST="/${FILE#"$TMPDIR_RESTORE"/}"

        # Show diff if destination exists
        if [ -f "$DEST" ]; then
            echo "--- Changes for $DEST ---"
            diff --color=auto "$DEST" "$FILE" 2>/dev/null && echo "(no changes)" || true
            echo "---"
        else
            echo "--- New file: $DEST ---"
        fi

        echo "Restore $DEST? [y/N]"
        read -r CONF
        if [[ "$CONF" =~ ^[Yy]$ ]]; then
            sudo mkdir -p "$(dirname "$DEST")"
            sudo cp "$FILE" "$DEST"
            log_msg INFO "Restored: $DEST"
        else
            log_msg INFO "Skipped: $DEST"
        fi
        count=$((count+1))
        progress_bar "$total" "$count"
    done
    rm -rf "$TMPDIR_RESTORE"
    log_msg INFO "Restore complete."
}

# Backward-compatible alias
restaurar_configs() { restore_interactive "$@"; }

# --- Restore all (no prompt) ---

restore_all() {
    check_root

    local backup_file="${1:-}"
    [ -z "$backup_file" ] && read -r -p "Enter the path to the backup file (.zip): " backup_file
    [ ! -f "$backup_file" ] && log_msg ERROR "File not found." && return 1

    if ! command -v unzip >/dev/null 2>&1; then
        log_msg ERROR "'unzip' is not installed. Please install it first."
        return 1
    fi

    if ! unzip -t "$backup_file" >/dev/null 2>&1; then
        log_msg ERROR "Invalid or corrupted zip file."
        return 1
    fi

    local TMPDIR_RESTORE
    TMPDIR_RESTORE=$(mktemp -d)
    _BRCS_TEMPFILES+=("$TMPDIR_RESTORE")
    unzip -o "$backup_file" -d "$TMPDIR_RESTORE" >/dev/null

    collect_files "$TMPDIR_RESTORE"
    local files=("${_collected_files[@]}")
    local total=${#files[@]}
    local count=0

    # Safety backup of files that will be overwritten
    local pre_restore_backup="$HOME/pre_restore_$(date +%Y%m%d_%H%M%S).zip"
    local existing_targets=()
    for FILE in "${files[@]}"; do
        local DEST="/${FILE#"$TMPDIR_RESTORE"/}"
        [ -f "$DEST" ] && existing_targets+=("$DEST")
    done
    if [ ${#existing_targets[@]} -gt 0 ] && command -v zip >/dev/null 2>&1; then
        log_msg INFO "Creating safety backup: $pre_restore_backup"
        zip -q "$pre_restore_backup" "${existing_targets[@]}" 2>/dev/null || true
    fi

    log_msg INFO "Restoring all files..."
    for FILE in "${files[@]}"; do
        DEST="/${FILE#"$TMPDIR_RESTORE"/}"
        sudo mkdir -p "$(dirname "$DEST")"
        sudo cp "$FILE" "$DEST"
        log_msg INFO "Restored: $DEST"
        count=$((count+1))
        progress_bar "$total" "$count"
    done
    rm -rf "$TMPDIR_RESTORE"
    log_msg INFO "Full restore complete."
}

# Backward-compatible alias
restaurar_tudo() { restore_all "$@"; }

# --- Package manager wrappers ---

pkg_update() {
    case "$PKG_MANAGER" in
        apt)    run_cmd sudo apt-get update && run_cmd sudo apt-get upgrade -y ;;
        dnf)    run_cmd sudo dnf upgrade --refresh -y ;;
        yum)    run_cmd sudo yum update -y ;;
        pacman) run_cmd sudo pacman -Syu --noconfirm ;;
        zypper) run_cmd sudo zypper refresh && run_cmd sudo zypper update -y ;;
        apk)    run_cmd sudo apk update && run_cmd sudo apk upgrade ;;
        *)      log_msg WARN "Unknown package manager, skipping update." ;;
    esac
}

pkg_clean() {
    case "$PKG_MANAGER" in
        apt)
            run_cmd sudo apt-get clean
            run_cmd sudo apt-get autoclean
            ;;
        dnf)    run_cmd sudo dnf clean all ;;
        yum)    run_cmd sudo yum clean all ;;
        pacman)
            if command -v paccache >/dev/null 2>&1; then
                run_cmd sudo paccache -rk1
            else
                run_cmd sudo pacman -Sc --noconfirm
            fi
            ;;
        zypper) run_cmd sudo zypper clean --all ;;
        apk)    run_cmd sudo apk cache clean 2>/dev/null ;;
        *)      log_msg WARN "Unknown package manager, skipping clean." ;;
    esac
}

pkg_autoremove() {
    case "$PKG_MANAGER" in
        apt)
            run_cmd sudo apt-get autoremove -y
            if command -v deborphan >/dev/null 2>&1; then
                deborphan | xargs run_cmd sudo apt-get -y remove --purge 2>/dev/null
                deborphan --guess-data | xargs run_cmd sudo apt-get -y remove --purge 2>/dev/null
            fi
            if command -v localepurge >/dev/null 2>&1; then
                run_cmd sudo localepurge
            fi
            ;;
        dnf)    run_cmd sudo dnf autoremove -y ;;
        yum)    run_cmd sudo yum autoremove -y 2>/dev/null || run_cmd sudo package-cleanup --leaves -y 2>/dev/null ;;
        pacman)
            local orphans
            orphans=$(pacman -Qdtq 2>/dev/null)
            if [ -n "$orphans" ]; then
                echo "$orphans" | run_cmd sudo pacman -Rns --noconfirm - 2>/dev/null
            fi
            ;;
        zypper) zypper packages --unneeded 2>/dev/null | awk -F'|' 'NR>4{print $3}' | xargs run_cmd sudo zypper remove -y 2>/dev/null ;;
        apk)    : ;; # apk has no autoremove
        *)      log_msg WARN "Unknown package manager, skipping autoremove." ;;
    esac
}

# --- Full cleanup ---

full_cleanup() {
    check_root
    log_msg INFO "Starting full cleanup..."

    local space_before
    space_before=$(get_disk_used_kb)

    local steps=("update" "clean" "autoremove" "snap" "flatpak" "journal" "kernels" "docker" "steam" "tmp")
    local total=${#steps[@]}
    local count=0

    # 1. Update & upgrade
    pkg_update
    count=$((count+1)); progress_bar "$total" "$count"

    # 2. Clean package cache
    pkg_clean
    count=$((count+1)); progress_bar "$total" "$count"

    # 3. Remove orphan packages
    pkg_autoremove
    count=$((count+1)); progress_bar "$total" "$count"

    # 4. Snap cleanup
    if command -v snap >/dev/null 2>&1; then
        run_cmd sudo snap set system refresh.retain=2 2>/dev/null
        if [ "$DRY_RUN" -eq 0 ]; then
            snap list --all 2>/dev/null | awk '/disabled/{print $1, $2}' | while read -r snapname revision; do
                sudo snap remove "$snapname" --revision="$revision" --purge 2>/dev/null || \
                sudo snap remove "$snapname" --purge 2>/dev/null
            done
        else
            log_msg INFO "[DRY-RUN] Would clean disabled snap revisions"
        fi
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # 5. Flatpak cleanup
    if command -v flatpak >/dev/null 2>&1; then
        run_cmd flatpak uninstall --unused -y 2>/dev/null
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # 6. Journal log cleanup
    if command -v journalctl >/dev/null 2>&1; then
        run_cmd sudo journalctl --vacuum-time=7d 2>/dev/null
        run_cmd sudo journalctl --vacuum-size=100M 2>/dev/null
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # 7. Old kernel cleanup
    if [ "$PKG_MANAGER" = "apt" ]; then
        local current_kernel
        current_kernel=$(uname -r)
        if [ "$DRY_RUN" -eq 0 ]; then
            dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v "$current_kernel" | grep -v 'linux-image-generic' | while read -r pkg; do
                sudo apt-get remove -y "$pkg" 2>/dev/null
            done
        else
            local old_kernels
            old_kernels=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v "$current_kernel" | grep -v 'linux-image-generic')
            [ -n "$old_kernels" ] && log_msg INFO "[DRY-RUN] Would remove old kernels: $old_kernels"
        fi
    elif [ "$PKG_MANAGER" = "dnf" ]; then
        run_cmd sudo dnf remove --oldinstallonly -y 2>/dev/null
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # 8. Docker cleanup
    if command -v docker >/dev/null 2>&1; then
        run_cmd docker system prune -f 2>/dev/null
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # 9. Steam shader cache cleanup
    if [ -d "$HOME/.steam/steam/steamapps" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -rf "$HOME/.steam/steam/steamapps/shadercache/"* 2>/dev/null
            rm -rf "$HOME/.steam/steam/steamapps/compatdata/"* 2>/dev/null
        else
            log_msg INFO "[DRY-RUN] Would clean Steam shader/compat cache"
        fi
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # 10. Clean temporary files
    log_msg INFO "Cleaning temporary files in /tmp and /var/tmp..."
    if [ "$DRY_RUN" -eq 0 ]; then
        collect_files "/tmp"
        local tmp1=("${_collected_files[@]}")
        collect_files "/var/tmp"
        local tmp2=("${_collected_files[@]}")
        local tmp_files=("${tmp1[@]}" "${tmp2[@]}")
        local total_tmp=${#tmp_files[@]}

        for file in "${tmp_files[@]}"; do
            if command -v lsof >/dev/null 2>&1; then
                lsof "$file" >/dev/null 2>&1 || rm -f "$file" 2>/dev/null
            elif command -v fuser >/dev/null 2>&1; then
                fuser "$file" >/dev/null 2>&1 || rm -f "$file" 2>/dev/null
            else
                rm -f "$file" 2>/dev/null
            fi
        done
        [ "$total_tmp" -gt 0 ] && progress_bar "$total_tmp" "$total_tmp"
    else
        log_msg INFO "[DRY-RUN] Would clean temporary files in /tmp and /var/tmp"
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # Report disk space freed
    local space_after freed_kb
    space_after=$(get_disk_used_kb)
    freed_kb=$((space_before - space_after))
    if [ "$freed_kb" -gt 0 ] 2>/dev/null; then
        if command -v numfmt >/dev/null 2>&1; then
            log_msg INFO "Disk space freed: $(numfmt --to=iec --suffix=B $((freed_kb * 1024)))"
        else
            log_msg INFO "Disk space freed: ${freed_kb} KB"
        fi
    else
        log_msg INFO "Cleanup complete (no measurable space freed or running in dry-run mode)."
    fi

    log_msg INFO "Full cleanup completed."
}

# Backward-compatible alias
limpeza_completa() { full_cleanup "$@"; }

# --- Schedule cleanup at boot ---

schedule_cleanup() {
    log_msg INFO "Scheduling cleanup at boot..."
    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

    if command -v crontab >/dev/null 2>&1; then
        local CRON_CMD="@reboot bash $script_path --cleanup"
        (crontab -l 2>/dev/null | grep -v "$script_path" ; echo "$CRON_CMD") | crontab -
        log_msg INFO "Cleanup scheduled at boot via crontab."
    elif command -v systemctl >/dev/null 2>&1; then
        local unit_dir="/etc/systemd/system"
        check_root

        sudo tee "$unit_dir/brcs-cleanup.service" >/dev/null <<EOF
[Unit]
Description=BRCS system cleanup at boot
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $script_path --cleanup
EOF

        sudo tee "$unit_dir/brcs-cleanup.timer" >/dev/null <<EOF
[Unit]
Description=Run BRCS cleanup on boot

[Timer]
OnBootSec=2min

[Install]
WantedBy=timers.target
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable brcs-cleanup.timer
        log_msg INFO "Cleanup scheduled at boot via systemd timer."
    else
        log_msg ERROR "Neither crontab nor systemctl found. Cannot schedule cleanup."
        return 1
    fi
}

# --- Skip menu when sourced by tests or other scripts ---
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return

# Register signal trap only when executed directly
trap _brcs_cleanup EXIT INT TERM HUP

# --- CLI argument parser ---

show_help() {
    cat <<USAGE
BRCS.sh v${VERSION} - Backup, Restore, Cleanup System

Usage: $(basename "$0") [OPTIONS]

Options:
  --backup              Backup system and user configurations
  --restore FILE        Restore all configs from backup FILE
  --restore-interactive FILE  Restore configs interactively (choose per file)
  --cleanup             Run full system cleanup
  --dry-run             Show what cleanup would do (use with --cleanup)
  --list FILE           List contents of a backup file
  --schedule            Schedule cleanup to run at boot
  --help, -h            Show this help message

Examples:
  $(basename "$0")                          # Interactive menu
  $(basename "$0") --backup                 # Backup all configs
  $(basename "$0") --restore backup.zip     # Restore all from backup
  $(basename "$0") --dry-run --cleanup      # Preview cleanup actions
  $(basename "$0") --list backup.zip        # Show backup contents

Detected package manager: $PKG_MANAGER
USAGE
}

ACTION=""
CLI_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --backup)               ACTION="backup"; shift ;;
        --restore)              ACTION="restore"; CLI_FILE="${2:-}"; shift; [ -n "$CLI_FILE" ] && shift ;;
        --restore-interactive)  ACTION="restore_interactive"; CLI_FILE="${2:-}"; shift; [ -n "$CLI_FILE" ] && shift ;;
        --cleanup|--limpeza)    ACTION="cleanup"; shift ;;
        --list)                 ACTION="list"; CLI_FILE="${2:-}"; shift; [ -n "$CLI_FILE" ] && shift ;;
        --schedule)             ACTION="schedule"; shift ;;
        --dry-run)              DRY_RUN=1; shift ;;
        --help|-h)              show_help; exit 0 ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Execute CLI action if specified
case "$ACTION" in
    backup)
        backup_configs
        exit $?
        ;;
    restore)
        [ -z "$CLI_FILE" ] && { log_msg ERROR "No file specified for --restore"; show_help; exit 1; }
        restore_all "$CLI_FILE"
        exit $?
        ;;
    restore_interactive)
        [ -z "$CLI_FILE" ] && { log_msg ERROR "No file specified for --restore-interactive"; show_help; exit 1; }
        restore_interactive "$CLI_FILE"
        exit $?
        ;;
    cleanup)
        full_cleanup
        exit $?
        ;;
    list)
        [ -z "$CLI_FILE" ] && { log_msg ERROR "No file specified for --list"; show_help; exit 1; }
        list_backup_contents "$CLI_FILE"
        exit $?
        ;;
    schedule)
        schedule_cleanup
        exit $?
        ;;
esac

# Interactive Terminal Menu (no CLI arguments)
while true; do
    echo ""
    echo "=== BRCS v${VERSION} - System Maintenance ==="
    echo "1) Backup configurations"
    echo "2) Restore configurations"
    echo "3) Full system cleanup"
    echo "4) Full system cleanup (dry-run)"
    echo "5) List backup contents"
    echo "6) Schedule cleanup at boot"
    echo "7) Exit"
    echo "Package manager: $PKG_MANAGER"
    read -r -p "Choose an option: " option

    case "$option" in
        1) backup_configs ;;
        2)
            echo ""
            echo "=== Restore Options ==="
            echo "1 - Interactive restore (review each file)"
            echo "2 - Restore all (no prompt)"
            echo "3 - Back"
            read -r -p "Choose an option: " restopt
            case "$restopt" in
                1) restore_interactive ;;
                2) restore_all ;;
                *) echo "Returning..." ;;
            esac
            ;;
        3) DRY_RUN=0; full_cleanup ;;
        4) DRY_RUN=1; full_cleanup; DRY_RUN=0 ;;
        5) list_backup_contents ;;
        6) schedule_cleanup ;;
        7) echo "Goodbye!"; exit 0 ;;
        *) log_msg ERROR "Invalid option." ;;
    esac
done

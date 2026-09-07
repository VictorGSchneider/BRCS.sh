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

VERSION="2.2.0"

# Hostname fallback and date for backup filename
MY_HOSTNAME="${HOSTNAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)}"
TODAY=$(date +%Y%m%d)

# Where archives land. Anchored, like the log on the line below it. Left
# unanchored, the archive was written to whatever directory you happened to
# be standing in, so a backup taken from one shell was invisible from the
# next and --list could not find it again.
BACKUP_DIR="${BRCS_BACKUP_DIR:-$HOME}"

# The scratch directories step 11 sweeps. Overridable so the step can be
# exercised against a sandbox: it deletes files, and a test suite that
# points it at the real /tmp is one broken guard away from sweeping the
# developer's machine.
BRCS_TMP_DIRS="${BRCS_TMP_DIRS:-/tmp /var/tmp}"
arq="$BACKUP_DIR/$MY_HOSTNAME.confs.$TODAY.zip"
log="$HOME/backup_$TODAY.log"
USER_DIR="$HOME"
DRY_RUN=0

# --- Cleanup scope ---
# "full" is every step, for someone watching it run. "safe" is what an
# unattended run scheduled at boot is allowed to do on its own: delete
# garbage and change nothing else. It leaves out the system upgrade and
# orphan removal (both alter what is installed, unwatched), old-kernel
# removal, the docker prune (stopped containers are someone's work), and
# the Steam step -- a shader cache is regenerable, but rebuilding it costs
# a stuttering first launch per game, so wiping it on every boot is worse
# than useless.
#
# "user" is for a machine you do not administer: no sudo at all. Only the
# steps that touch your own files, plus the per-user variants of the two
# that have one -- flatpak's user installation and your own journal. The
# package manager, snap, the kernels and the system journal are simply
# not yours to clean, so they are skipped rather than attempted; see
# _explain_user_scope below, which says so once instead of leaving you to
# wonder why the run got short.
CLEANUP_SCOPE="full"
_SAFE_STEPS=" clean flatpak journal leftovers tmp "
_USER_STEPS=" flatpak journal docker steam usercache leftovers tmp "

_step() {
    case "$CLEANUP_SCOPE" in
        full) return 0 ;;
        safe) case "$_SAFE_STEPS" in *" $1 "*) return 0 ;; esac ;;
        user) case "$_USER_STEPS" in *" $1 "*) return 0 ;; esac ;;
    esac
    return 1
}

# True when this run must not invoke sudo even once.
_user_scope() { [ "$CLEANUP_SCOPE" = "user" ]; }

_explain_user_scope() {
    log_msg INFO "Unprivileged run: skipping the package manager, snap, old kernels"
    log_msg INFO "and the system journal -- those need root. Cleaning your own files."
}

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
    [ "$(id -u)" -eq 0 ] && return 0

    if ! command -v sudo >/dev/null 2>&1; then
        log_msg ERROR "Needs root and sudo is not installed."
        log_msg ERROR "To clean only your own files instead: --cleanup --user"
        return 1
    fi

    # --dry-run executes nothing, so there is no sudo to fail and no
    # faillock counter to trip. Let a piped preview through: refusing it
    # would make the one mode that is safe to run unattended the one mode
    # you could not.
    [ "$DRY_RUN" -eq 1 ] && return 0

    # Unprivileged *and* unattended is the dangerous combination. Every
    # sudo below would be a PAM auth attempt with no terminal to prompt
    # on; PAM logs each as "conversation failed" and pam_faillock counts
    # it. Three attempts is the default on several distributions, and the
    # account is then locked -- at the login screen, on the next boot.
    # Refuse once, loudly, rather than trip that.
    if ! sudo -n true 2>/dev/null && [ ! -t 0 ]; then
        log_msg ERROR "Needs root, but there is no terminal to ask for a password."
        log_msg ERROR "Run it as root, or grant this user a NOPASSWD sudoers rule."
        log_msg ERROR "To clean only your own files instead: --cleanup --user"
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
    local dir="$1" owner="${2:-}"
    _collected_files=()
    # With an owner, only that user's files. /tmp is shared: without root
    # someone else's files are not ours to delete, and trying just prints
    # a permission error per file.
    local -a pred=(-type f)
    [ -n "$owner" ] && pred+=(-user "$owner")
    while IFS= read -r -d '' f; do
        _collected_files+=("$f")
    done < <(find "$dir" "${pred[@]}" -print0 2>/dev/null)
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
    # Measure the filesystem holding what we are about to clean. An
    # unprivileged run only ever touches $HOME, which on a shared or
    # managed machine is very often a different mount from / -- reporting
    # on / there would have said "no measurable space freed" every time.
    df "${1:-/}" 2>/dev/null | awk 'NR==2{print $3}'
}

# --- Backup ---

backup_configs() {
    mkdir -p "$BACKUP_DIR" 2>/dev/null
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
    local pre_restore_backup
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    pre_restore_backup="$BACKUP_DIR/pre_restore_$(date +%Y%m%d_%H%M%S).zip"
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
    local pre_restore_backup
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    pre_restore_backup="$BACKUP_DIR/pre_restore_$(date +%Y%m%d_%H%M%S).zip"
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
                # run_cmd is a shell function, so xargs could never exec
                # it: this branch has always been a silent no-op, with
                # xargs' "run_cmd: No such file or directory" swallowed by
                # the redirect. Collect the names and pass them as
                # arguments instead.
                local orphaned
                mapfile -t orphaned < <(deborphan 2>/dev/null)
                [ "${#orphaned[@]}" -gt 0 ] && \
                    run_cmd sudo apt-get -y remove --purge "${orphaned[@]}"
                mapfile -t orphaned < <(deborphan --guess-data 2>/dev/null)
                [ "${#orphaned[@]}" -gt 0 ] && \
                    run_cmd sudo apt-get -y remove --purge "${orphaned[@]}"
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
        zypper)
            # The same xargs-cannot-exec-a-shell-function defect as the
            # apt branch above. Field 3 also arrives padded with the
            # table's column spacing, so strip it before use.
            local unneeded
            mapfile -t unneeded < <(zypper packages --unneeded 2>/dev/null \
                | awk -F'|' 'NR>4 {gsub(/ /, "", $3); if ($3 != "") print $3}')
            [ "${#unneeded[@]}" -gt 0 ] && run_cmd sudo zypper remove -y "${unneeded[@]}"
            ;;
        apk)    : ;; # apk has no autoremove
        *)      log_msg WARN "Unknown package manager, skipping autoremove." ;;
    esac
}

# --- Full cleanup ---

full_cleanup() {
    # An unprivileged run never calls sudo, so there is nothing to
    # authenticate and nothing for pam_faillock to count.
    if ! _user_scope; then
        check_root || return 1
    fi
    log_msg INFO "Starting ${CLEANUP_SCOPE} cleanup..."
    _user_scope && _explain_user_scope

    # Only $HOME is touched unprivileged, and it is often its own mount.
    local measure="/"
    _user_scope && measure="$HOME"
    local space_before
    space_before=$(get_disk_used_kb "$measure")

    local steps
    case "$CLEANUP_SCOPE" in
        safe) steps=("clean" "flatpak" "journal" "leftovers" "tmp") ;;
        user) steps=("flatpak" "journal" "docker" "steam" "usercache" \
                     "leftovers" "tmp") ;;
        *)    steps=("update" "clean" "autoremove" "snap" "flatpak" "journal" \
                     "kernels" "docker" "steam" "usercache" "leftovers" "tmp") ;;
    esac
    local total=${#steps[@]}
    local count=0

    # 1. Update & upgrade
    if _step update; then
        pkg_update
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # 2. Clean package cache
    if _step clean; then
        pkg_clean
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # 3. Remove orphan packages
    if _step autoremove; then
        pkg_autoremove
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # 4. Snap cleanup
    if _step snap; then
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
    fi

    # 5. Flatpak cleanup
    if _step flatpak; then
        if command -v flatpak >/dev/null 2>&1; then
            if _user_scope; then
                # --user confines this to the per-user installation. Without
                # it flatpak targets the system one and raises a polkit
                # prompt there is nobody to answer.
                run_cmd flatpak uninstall --user --unused -y 2>/dev/null
            else
                run_cmd flatpak uninstall --unused -y 2>/dev/null
            fi
        fi
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # 6. Journal log cleanup
    if _step journal; then
        if command -v journalctl >/dev/null 2>&1; then
            if _user_scope; then
                # Your own journal, which you own and may vacuum freely.
                run_cmd journalctl --user --vacuum-time=7d 2>/dev/null
                run_cmd journalctl --user --vacuum-size=100M 2>/dev/null
            else
                run_cmd sudo journalctl --vacuum-time=7d 2>/dev/null
                run_cmd sudo journalctl --vacuum-size=100M 2>/dev/null
            fi
        fi
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # 7. Old kernel cleanup
    if _step kernels; then
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
    fi

    # 8. Docker cleanup
    if _step docker; then
        if command -v docker >/dev/null 2>&1; then
            run_cmd docker system prune -f 2>/dev/null
        fi
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # 9. Steam shader cache cleanup
    if _step steam; then
        if [ -d "$HOME/.steam/steam/steamapps" ]; then
            # shadercache only. compatdata sits next to it and holds the
            # Proton prefixes: unless a game uses Steam Cloud, its saves
            # are in there. Releases up to 2.0.0 deleted it as "compat
            # cache" -- it is not cache, and it is never deleted here.
            if [ "$DRY_RUN" -eq 0 ]; then
                rm -rf "$HOME/.steam/steam/steamapps/shadercache/"* 2>/dev/null
            else
                log_msg INFO "[DRY-RUN] Would clean the Steam shader cache"
            fi
        fi
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # Regenerable caches under $HOME. Everything here comes back on its
    # own the next time the tool that made it runs -- the only cost of
    # deleting it is the time to rebuild. Nothing here is a preference, a
    # credential or a piece of work, which is why it can go without asking.
    #
    # Deliberately NOT here: ~/.cache wholesale (applications keep real
    # state in there, not just cache), the trash (you may still want those
    # files back), and the Go module cache (it is regenerable, but it is
    # gigabytes of re-download, not seconds of rebuild).
    if _step usercache; then
        local freed_any=0

        if [ -d "$HOME/.cache/thumbnails" ]; then
            if [ "$DRY_RUN" -eq 0 ]; then
                rm -rf "${HOME:?}/.cache/thumbnails/"* 2>/dev/null
            else
                log_msg INFO "[DRY-RUN] Would clear the thumbnail cache"
            fi
            freed_any=1
        fi

        if command -v pip >/dev/null 2>&1; then
            run_cmd pip cache purge >/dev/null 2>&1 && freed_any=1
        elif command -v pip3 >/dev/null 2>&1; then
            run_cmd pip3 cache purge >/dev/null 2>&1 && freed_any=1
        fi

        if command -v npm >/dev/null 2>&1; then
            run_cmd npm cache clean --force >/dev/null 2>&1 && freed_any=1
        fi

        if command -v yarn >/dev/null 2>&1; then
            run_cmd yarn cache clean >/dev/null 2>&1 && freed_any=1
        fi

        [ "$freed_any" -eq 0 ] && log_msg INFO "No user caches found to clear."
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # 10. Leftovers: our own archives, and the .bak/.log debris any tool
    # leaves behind. Everything here is age-gated at 30 days except the
    # archive pruning, which is count-gated -- a file nothing has written
    # to in a month is not in use by anything, which is what makes
    # sweeping *.log safe at all.
    #
    # Deliberately NOT touched: /var/log. Those belong to services that
    # hold them open, and the journal has its own step above.
    if _step leftovers; then
        local pruned=0 swept=0 f pattern old

        # Keep the two most recent of each archive kind; anything older is
        # superseded by definition -- the newest is what you would restore.
        for pattern in '*.confs.*.zip' 'pre_restore_*.zip'; do
            while IFS= read -r old; do
                [ -n "$old" ] || continue
                [ "$DRY_RUN" -eq 0 ] && rm -f "$old" 2>/dev/null
                pruned=$((pruned + 1))
            done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pattern" \
                        -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +3 \
                        | cut -d' ' -f2-)
        done

        # $HOME's top level: a stray .log or .bak there is debris, never a
        # program's working file. ~/.cache is debris by definition. Under
        # ~/.config and ~/.local/share only .bak is swept -- a .log there
        # may well be an application's real log.
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            [ "$DRY_RUN" -eq 0 ] && rm -f "$f" 2>/dev/null
            swept=$((swept + 1))
        done < <(
            {
                find "$USER_DIR" -maxdepth 1 -type f \
                    \( -name '*.log' -o -name '*.bak' -o -name '*.bak.*' \) -mtime +30
                find "$USER_DIR/.cache" -type f \
                    \( -name '*.log' -o -name '*.bak' -o -name '*.bak.*' \) -mtime +30
                find "$USER_DIR/.config" "$USER_DIR/.local/share" -type f \
                    \( -name '*.bak' -o -name '*.bak.*' \) -mtime +30
            } 2>/dev/null
        )

        if [ "$DRY_RUN" -eq 0 ]; then
            log_msg INFO "Leftovers: pruned ${pruned} old archive(s), swept ${swept} stale .log/.bak"
        else
            log_msg INFO "[DRY-RUN] Would prune ${pruned} old archive(s) and sweep ${swept} stale .log/.bak"
        fi
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # 11. Clean temporary files
    if _step tmp; then
        # Unprivileged, only your own files: /tmp is shared, and the rest
        # is not yours to delete.
        local tmp_owner=""
        if _user_scope; then
            tmp_owner=$(id -un 2>/dev/null)
            log_msg INFO "Cleaning your own files in ${BRCS_TMP_DIRS}..."
        else
            log_msg INFO "Cleaning temporary files in ${BRCS_TMP_DIRS}..."
        fi
        if [ "$DRY_RUN" -eq 0 ]; then
            local tmp_files=() tmp_dir
            # shellcheck disable=SC2086
            for tmp_dir in $BRCS_TMP_DIRS; do
                [ -d "$tmp_dir" ] || continue
                collect_files "$tmp_dir" "$tmp_owner"
                tmp_files+=("${_collected_files[@]}")
            done
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
            log_msg INFO "[DRY-RUN] Would clean temporary files in ${BRCS_TMP_DIRS}"
        fi
        count=$((count+1)); progress_bar "$total" "$count"
    fi

    # Report disk space freed
    local space_after freed_kb
    space_after=$(get_disk_used_kb "$measure")
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

    log_msg INFO "${CLEANUP_SCOPE^} cleanup completed."
}

# Backward-compatible alias
limpeza_completa() { full_cleanup "$@"; }

# --- Schedule cleanup at boot ---

# Releases up to 2.0.0 put the @reboot line in the *invoking user's*
# crontab, where the job runs unprivileged with no terminal -- see
# check_root for what that costs. Drop that entry wherever it is still
# installed, whatever name the script was carrying when it wrote it: a
# fork under a different filename is the same defect.
_LEGACY_CRON_RE='BRCS\.sh|brcs-cleanup|stoa-maintain'

_unschedule_user_crontab() {
    command -v crontab >/dev/null 2>&1 || return 0
    # Read the crontab once. Reading it twice -- once to test, once to
    # rewrite -- would drop anything added in between, and it puts the
    # read on the same pipeline as the write.
    local current
    current=$(crontab -l 2>/dev/null) || return 0
    printf '%s\n' "$current" | grep -qE "$_LEGACY_CRON_RE" || return 0
    printf '%s\n' "$current" | grep -vE "$_LEGACY_CRON_RE" | crontab -
    log_msg INFO "Removed the legacy user-crontab cleanup entry (it could not authenticate)."
}

schedule_cleanup() {
    log_msg INFO "Scheduling cleanup at boot..."
    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

    _unschedule_user_crontab

    # systemd first, deliberately. The cleanup runs the package manager and
    # journalctl: it needs root. A @reboot line in this user's crontab runs
    # it unprivileged with nothing to prompt on, so every sudo inside fails
    # as a PAM "conversation failed" and pam_faillock locks the account --
    # at the login screen, on the next boot. The systemd unit runs as root,
    # so nothing has to ask.
    if command -v systemctl >/dev/null 2>&1; then
        local unit_dir="/etc/systemd/system"
        check_root || return 1

        sudo tee "$unit_dir/brcs-cleanup.service" >/dev/null <<SVCEOF
[Unit]
Description=BRCS system cleanup at boot
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $script_path --cleanup --unattended
SVCEOF

        sudo tee "$unit_dir/brcs-cleanup.timer" >/dev/null <<TMREOF
[Unit]
Description=Run BRCS cleanup on boot

[Timer]
OnBootSec=2min

[Install]
WantedBy=timers.target
TMREOF

        sudo systemctl daemon-reload
        sudo systemctl enable brcs-cleanup.timer
        log_msg INFO "Cleanup scheduled at boot via systemd timer."
        log_msg INFO "To undo: sudo systemctl disable --now brcs-cleanup.timer"
    elif command -v crontab >/dev/null 2>&1; then
        # No systemd: root's crontab, so the job is already privileged and
        # nothing inside it has to ask for a password.
        check_root || return 1
        local CRON_CMD="@reboot bash $script_path --cleanup --unattended"
        (sudo crontab -l 2>/dev/null | grep -vE "$_LEGACY_CRON_RE" ; echo "$CRON_CMD") \
            | sudo crontab -
        log_msg INFO "Cleanup scheduled at boot via root crontab."
    else
        log_msg ERROR "Neither systemctl nor crontab found. Cannot schedule cleanup."
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
  --cleanup             Run full system cleanup (12 steps, see below)
  --unattended          Use with --cleanup: run only the steps that are
                        safe without a person watching -- package cache,
                        unused flatpaks, journal, leftovers and temp files.
                        No upgrade, no package removal, no Steam, no
                        docker prune, no kernel removal. This is what the
                        scheduled boot job runs.
  --user                Use with --cleanup: never call sudo at all. Runs
                        only the steps that touch your own files, for a
                        machine you do not administer. See below.
  --dry-run             Show what cleanup would do (use with --cleanup)
  --list FILE           List contents of a backup file
  --schedule            Schedule the unattended cleanup two minutes after
                        each boot, as a root-owned systemd timer
                        (undo: sudo systemctl disable --now brcs-cleanup.timer)
  --help, -h            Show this help message

Cleanup steps, in order:
   1  upgrade every package                     changes what is installed
   2  trim the package cache
   3  remove orphaned packages                  changes what is installed
   4  drop disabled snap revisions
   5  uninstall unused flatpak runtimes
   6  vacuum the journal to 7 days / 100M
   7  remove old kernels                        apt and dnf only
   8  docker system prune                       drops stopped containers
   9  clear the Steam shader cache
  10  regenerable user caches: thumbnails, pip, npm, yarn
  11  leftovers: keep the 2 newest archives of each kind, and sweep
      .log/.bak older than 30 days from \$HOME, ~/.cache, and (.bak only)
      ~/.config and ~/.local/share. Never /var/log.
  12  clear /tmp and /var/tmp, skipping files in use

Steam compatdata is never touched: Proton keeps game saves there.

Unprivileged cleanup (--user), for a machine where you have no sudo.
Runs seven steps, none of which call sudo even once:

   *  unused flatpak runtimes from your *user* installation
   *  your own journal, vacuumed to 7 days / 100M
   *  docker system prune, if you are in the docker group
   *  the Steam shader cache
   *  regenerable caches: thumbnails, pip, npm, yarn
   *  leftovers, as step 11 above
   *  your own files in /tmp and /var/tmp -- not other people's

The package manager, snap, old kernels and the system journal are
skipped: they are not yours to clean without root. Space freed is
measured on the filesystem holding \$HOME, which is often not /.

Examples:
  $(basename "$0")                          # Interactive menu
  $(basename "$0") --backup                 # Backup all configs
  $(basename "$0") --restore backup.zip     # Restore all from backup
  $(basename "$0") --dry-run --cleanup      # Preview cleanup actions
  $(basename "$0") --cleanup --unattended   # Safe subset only
  $(basename "$0") --list backup.zip        # Show backup contents

Backups are written to: $BACKUP_DIR
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
        --unattended)           CLEANUP_SCOPE="safe"; shift ;;
        --user)                 CLEANUP_SCOPE="user"; shift ;;
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
    echo "5) Safe cleanup only (what the boot job runs)"
    echo "6) Cleanup without sudo (your own files only)"
    echo "7) List backup contents"
    echo "8) Schedule cleanup at boot"
    echo "9) Exit"
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
        3) DRY_RUN=0; CLEANUP_SCOPE="full"; full_cleanup ;;
        4) DRY_RUN=1; CLEANUP_SCOPE="full"; full_cleanup; DRY_RUN=0 ;;
        5) DRY_RUN=0; CLEANUP_SCOPE="safe"; full_cleanup; CLEANUP_SCOPE="full" ;;
        6) DRY_RUN=0; CLEANUP_SCOPE="user"; full_cleanup; CLEANUP_SCOPE="full" ;;
        7) list_backup_contents ;;
        8) schedule_cleanup ;;
        9) echo "Goodbye!"; exit 0 ;;
        *) log_msg ERROR "Invalid option." ;;
    esac
done

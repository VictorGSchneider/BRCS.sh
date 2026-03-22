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

# Hostname fallback and date for backup filename
MY_HOSTNAME="${HOSTNAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)}"
Mdia=$(date +%Y%m%d)
arq="$MY_HOSTNAME.confs.$Mdia.zip"
log="$HOME/backup_$Mdia.log"
USER_DIR="$HOME"

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

# Function: Backup
backup_configs() {
    echo "[+] Starting backup..."

    if ! command -v zip >/dev/null 2>&1; then
        echo "[!] Error: 'zip' is not installed. Please install it first."
        return 1
    fi

    local repo_patterns
    repo_patterns=$(get_repo_patterns)

    local total=0 count=0

    # Phase 1: collect all file paths
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
    for sysfile in /etc/fstab /etc/default/grub /etc/hostname; do
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

    # Remove empty lines and duplicates, then zip
    all_files=$(echo "$all_files" | sort -u | sed '/^$/d')

    if [ -z "$all_files" ]; then
        echo "[!] No configuration files found."
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

    echo "[+] Backup saved as: $arq"
}

# Function: Restore (interactive)
restaurar_configs() {
    read -r -p "Enter the path to the backup file (.zip): " arquivo
    [ ! -f "$arquivo" ] && echo "[!] File not found." && return

    if ! command -v unzip >/dev/null 2>&1; then
        echo "[!] Error: 'unzip' is not installed. Please install it first."
        return 1
    fi

    local TMPDIR_RESTORE
    TMPDIR_RESTORE=$(mktemp -d)
    unzip -o "$arquivo" -d "$TMPDIR_RESTORE" >/dev/null

    collect_files "$TMPDIR_RESTORE"
    local files=("${_collected_files[@]}")
    local total=${#files[@]}
    local count=0

    echo "[*] Restoring files..."
    for FILE in "${files[@]}"; do
        DEST="/${FILE#"$TMPDIR_RESTORE"/}"
        echo "Restore $DEST? [y/N]"
        read -r CONF
        if [[ "$CONF" =~ ^[Yy]$ ]]; then
            sudo mkdir -p "$(dirname "$DEST")"
            sudo cp "$FILE" "$DEST"
            echo "[+] Restored: $DEST"
        else
            echo "[-] Skipped: $DEST"
        fi
        count=$((count+1))
        progress_bar "$total" "$count"
    done
    rm -rf "$TMPDIR_RESTORE"
    echo "[+] Restore complete."
}

# Function: Restore all (no prompt)
restaurar_tudo() {
    read -r -p "Enter the path to the backup file (.zip): " arquivo
    [ ! -f "$arquivo" ] && echo "[!] File not found." && return

    if ! command -v unzip >/dev/null 2>&1; then
        echo "[!] Error: 'unzip' is not installed. Please install it first."
        return 1
    fi

    local TMPDIR_RESTORE
    TMPDIR_RESTORE=$(mktemp -d)
    unzip -o "$arquivo" -d "$TMPDIR_RESTORE" >/dev/null

    collect_files "$TMPDIR_RESTORE"
    local files=("${_collected_files[@]}")
    local total=${#files[@]}
    local count=0

    echo "[*] Restoring all files..."
    for FILE in "${files[@]}"; do
        DEST="/${FILE#"$TMPDIR_RESTORE"/}"
        sudo mkdir -p "$(dirname "$DEST")"
        sudo cp "$FILE" "$DEST"
        echo "[+] Restored: $DEST"
        count=$((count+1))
        progress_bar "$total" "$count"
    done
    rm -rf "$TMPDIR_RESTORE"
    echo "[+] Full restore complete."
}

# Package manager: update & upgrade
pkg_update() {
    case "$PKG_MANAGER" in
        apt)    sudo apt-get update && sudo apt-get upgrade -y ;;
        dnf)    sudo dnf upgrade --refresh -y ;;
        yum)    sudo yum update -y ;;
        pacman) sudo pacman -Syu --noconfirm ;;
        zypper) sudo zypper refresh && sudo zypper update -y ;;
        apk)    sudo apk update && sudo apk upgrade ;;
        *)      echo "[!] Unknown package manager, skipping update." ;;
    esac
}

# Package manager: clean caches
pkg_clean() {
    case "$PKG_MANAGER" in
        apt)
            sudo apt-get clean
            sudo apt-get autoclean
            ;;
        dnf)    sudo dnf clean all ;;
        yum)    sudo yum clean all ;;
        pacman)
            if command -v paccache >/dev/null 2>&1; then
                sudo paccache -rk1
            else
                sudo pacman -Sc --noconfirm
            fi
            ;;
        zypper) sudo zypper clean --all ;;
        apk)    sudo apk cache clean 2>/dev/null ;;
        *)      echo "[!] Unknown package manager, skipping clean." ;;
    esac
}

# Package manager: remove orphan/unused packages
pkg_autoremove() {
    case "$PKG_MANAGER" in
        apt)
            sudo apt-get autoremove -y
            if command -v deborphan >/dev/null 2>&1; then
                sudo deborphan | xargs sudo apt-get -y remove --purge 2>/dev/null
                sudo deborphan --guess-data | xargs sudo apt-get -y remove --purge 2>/dev/null
            fi
            if command -v localepurge >/dev/null 2>&1; then
                sudo localepurge
            fi
            ;;
        dnf)    sudo dnf autoremove -y ;;
        yum)    sudo yum autoremove -y 2>/dev/null || sudo package-cleanup --leaves -y 2>/dev/null ;;
        pacman)
            local orphans
            orphans=$(pacman -Qdtq 2>/dev/null)
            if [ -n "$orphans" ]; then
                echo "$orphans" | sudo pacman -Rns --noconfirm - 2>/dev/null
            fi
            ;;
        zypper) sudo zypper packages --unneeded 2>/dev/null | awk -F'|' 'NR>4{print $3}' | xargs sudo zypper remove -y 2>/dev/null ;;
        apk)    : ;; # apk has no autoremove
        *)      echo "[!] Unknown package manager, skipping autoremove." ;;
    esac
}

limpeza_completa() {
    echo "[*] Starting full cleanup..."
    local steps=("update" "clean" "autoremove" "snap" "flatpak" "steam" "tmp")
    local total=${#steps[@]}
    local count=0

    pkg_update
    count=$((count+1)); progress_bar "$total" "$count"

    pkg_clean
    count=$((count+1)); progress_bar "$total" "$count"

    pkg_autoremove
    count=$((count+1)); progress_bar "$total" "$count"

    # Snap cleanup (only if snap is installed)
    if command -v snap >/dev/null 2>&1; then
        sudo snap set system refresh.retain=2 2>/dev/null
        snap list --all 2>/dev/null | awk '/disabled/{print $1, $2}' | while read -r snapname revision; do
            sudo snap remove "$snapname" --revision="$revision" --purge 2>/dev/null || \
            sudo snap remove "$snapname" --purge 2>/dev/null
        done
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # Flatpak cleanup (only if flatpak is installed)
    if command -v flatpak >/dev/null 2>&1; then
        flatpak uninstall --unused -y 2>/dev/null
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # Steam shader cache cleanup
    if [ -d "$HOME/.steam/steam/steamapps" ]; then
        rm -rf "$HOME/.steam/steam/steamapps/shadercache/"* 2>/dev/null
        rm -rf "$HOME/.steam/steam/steamapps/compatdata/"* 2>/dev/null
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    # Clean temporary files
    echo "[*] Cleaning temporary files in /tmp and /var/tmp..."
    collect_files "/tmp"
    local tmp1=("${_collected_files[@]}")
    collect_files "/var/tmp"
    local tmp2=("${_collected_files[@]}")
    local tmp_files=("${tmp1[@]}" "${tmp2[@]}")
    local total_tmp=${#tmp_files[@]}

    for file in "${tmp_files[@]}"; do
        if command -v lsof >/dev/null 2>&1; then
            if ! lsof "$file" >/dev/null 2>&1; then
                rm -f "$file" 2>/dev/null
            fi
        elif command -v fuser >/dev/null 2>&1; then
            if ! fuser "$file" >/dev/null 2>&1; then
                rm -f "$file" 2>/dev/null
            fi
        else
            rm -f "$file" 2>/dev/null
        fi
    done
    if [ "$total_tmp" -gt 0 ]; then
        progress_bar "$total_tmp" "$total_tmp"
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    echo "[+] Full cleanup completed."
}

# Function: Schedule Cleanup at Boot
schedule_cleanup() {
    echo "[*] Scheduling cleanup at boot..."
    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    local CRON_CMD="@reboot bash $script_path --limpeza"
    (crontab -l 2>/dev/null | grep -v "$script_path" ; echo "$CRON_CMD") | crontab -
    echo "[+] Cleanup scheduled at boot."
}

# Skip menu when sourced by tests or other scripts
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return

# Handle --limpeza for cron execution
if [ "$1" = "--limpeza" ]; then
    limpeza_completa
    exit 0
fi

# Interactive Terminal Menu
while true; do
    echo ""
    echo "=== System Maintenance Menu ==="
    echo "1) Backup configurations"
    echo "2) Restore configurations"
    echo "3) Full system cleanup"
    echo "4) Schedule cleanup at boot"
    echo "5) Exit"
    echo "Detected package manager: $PKG_MANAGER"
    read -r -p "Choose an option: " option

    case "$option" in
        1) backup_configs ;;
        2)
            echo ""
            echo "=== Restore Options ==="
            echo "1 - Interactive restore"
            echo "2 - Restore all (no prompt)"
            echo "3 - Back"
            read -r -p "Choose an option: " restopt
            case "$restopt" in
                1) restaurar_configs ;;
                2) restaurar_tudo ;;
                *) echo "Returning..." ;;
            esac
            ;;
        3) limpeza_completa ;;
        4) schedule_cleanup ;;
        5) echo "Goodbye!"; exit 0 ;;
        *) echo "[!] Invalid option." ;;
    esac
done

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

# 🖥️ Hostname and date for backup filename
Mdia=$(date +%Y%m%d)
arq="$HOSTNAME.confs.$Mdia.zip"
log="$HOME/backup_$Mdia.log"
USER_DIR="$HOME"

# 📊 Function: Show terminal progress bar with color
progress_bar() {
    local total=$1
    local current=$2
    local bar_length=30
    percent=$((current * 100 / total))
    filled=$((bar_length * percent / 100))
    empty=$((bar_length - filled))
    bar="\e[1;32m$(printf '%0.s█' $(seq 1 $filled))\e[0m$(printf '%0.s░' $(seq 1 $empty))"
    printf "\r[%b] %3d%%" "$bar" "$percent"
    [ "$current" -eq "$total" ] && echo
}

# 💾 Function: Backup
backup_configs() {
    echo "[+] Starting backup..."
    com1="locate"
    com2="zip"
    para="-r -9 -@"

    patterns=(.conf .ini .rules .sh /etc/fstab /etc/default/grub /etc/hostname)
    if command -v apt >/dev/null; then
        patterns+=(/etc/apt/sources.list*)
    else
        patterns+=(/etc/yum.repos.d/*)
    fi
    total=${#patterns[@]}
    count=0

    for pattern in "${patterns[@]}"; do
        case $pattern in
            .conf) $com1 .conf | grep /etc/ | $com2 "$arq" "$para" >> "$log" ;;
            .ini) $com1 .ini | grep /etc/ | $com2 "$arq" "$para" >> "$log" ;;
            .rules) $com1 .rules | grep /etc/ | $com2 "$arq" "$para" >> "$log" ;;
            .sh) $com1 .sh | grep ".sh$" | grep "$USER_DIR" | $com2 "$arq" "$para" >> "$log" ;;
            /etc/fstab|/etc/default/grub|/etc/hostname) $com1 "$pattern" | $com2 "$arq" "$para" >> "$log" ;;
            /etc/apt/sources.list*) $com1 "$pattern" | $com2 "$arq" "$para" >> "$log" ;;
            /etc/yum.repos.d/*) $com1 "$pattern" | $com2 "$arq" "$para" >> "$log" ;;
        esac
        count=$((count + 1))
        progress_bar "$total" "$count"
    done

    echo "[✅] Backup saved as: $arq"
}

# 🔁 Function: Restore (interactive)
restaurar_configs() {
    read -r -p "📦 Enter the path to the backup file (.zip): " arquivo
    [ ! -f "$arquivo" ] && echo "❌ File not found." && return

    TMPDIR=$(mktemp -d)
    unzip -o "$arquivo" -d "$TMPDIR" >/dev/null

    mapfile -d '' -t files < <(find "$TMPDIR" -type f -print0)
    total=${#files[@]}
    count=0

    echo "🔁 Restoring files..."
    for FILE in "${files[@]}"; do
        DEST="/${FILE#"$TMPDIR"/}"
        echo "Restore $DEST? [y/N]"
        read -r CONF
        if [[ "$CONF" =~ ^[Yy]$ ]]; then
            sudo mkdir -p "$(dirname "$DEST")"
            sudo cp "$FILE" "$DEST"
            echo "[✅] Restored: $DEST"
        else
            echo "[⏭️] Skipped: $DEST"
        fi
        count=$((count+1))
    done
    progress_bar "$total" "$count"
    rm -rf "$TMPDIR"
    echo "[✅] Restore complete."
}

# 🔁 Function: Restore all (no prompt)
restaurar_tudo() {
    read -r -p "📦 Enter the path to the backup file (.zip): " arquivo
    [ ! -f "$arquivo" ] && echo "❌ File not found." && return

    TMPDIR=$(mktemp -d)
    unzip -o "$arquivo" -d "$TMPDIR" >/dev/null

    mapfile -d '' -t files < <(find "$TMPDIR" -type f -print0)
    total=${#files[@]}
    count=0

    echo "🔁 Restoring all files..."
    for FILE in "${files[@]}"; do
        DEST="/${FILE#"$TMPDIR"/}"
        sudo mkdir -p "$(dirname "$DEST")"
        sudo cp "$FILE" "$DEST"
        echo "[✅] Restored: $DEST"
        count=$((count+1))
    done
    progress_bar "$total" "$count"
    rm -rf "$TMPDIR"
    echo "[✅] Full restore complete."
}

limpeza_completa() {
    echo "🧹 Starting full cleanup..."
    steps=("apt update" "apt clean" "autoclean" "autoremove" "deborphan" "localepurge" "snap" "flatpak" "steam")
    total=${#steps[@]}
    count=0

    sudo apt-get update && sudo apt-get upgrade -y
    count=$((count+1)); progress_bar "$total" "$count"

    sudo apt-get clean
    count=$((count+1)); progress_bar "$total" "$count"

    sudo apt-get autoclean
    count=$((count+1)); progress_bar "$total" "$count"

    sudo apt-get autoremove -y
    count=$((count+1)); progress_bar "$total" "$count"

    if command -v deborphan &>/dev/null; then
        sudo deborphan | xargs sudo apt-get -y remove --purge
        sudo deborphan --guess-data | xargs sudo apt-get -y remove --purge
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    if command -v localepurge &>/dev/null; then
        sudo localepurge
    fi
    count=$((count+1)); progress_bar "$total" "$count"

    sudo snap set system refresh.retain=2
    sudo snap list --all | awk '/disabled/{print $1, $2}' | while read -r snapname revision; do
        sudo snap remove "$snapname" --revision="$revision" --purge 2>/dev/null || \
        sudo snap remove "$snapname" --purge
    done
    count=$((count+1)); progress_bar "$total" "$count"

    flatpak uninstall --unused -y
    count=$((count+1)); progress_bar "$total" "$count"

    rm -rf ~/.steam/steam/steamapps/shadercache/*
    rm -rf ~/.steam/steam/steamapps/compatdata/*
    count=$((count+1)); progress_bar "$total" "$count"

        echo "🗑️ Cleaning temporary files in /tmp and /var/tmp..."
    mapfile -d '' -t tmp_files < <(find /tmp /var/tmp -type f -print0 2>/dev/null)
    total_tmp=${#tmp_files[@]}
    count_tmp=0

    for file in "${tmp_files[@]}"; do
        if ! lsof "$file" &>/dev/null; then
            rm -f "$file"
            echo "[✅] Removed: $file"
        else
            echo "[⏭️] Skipped (in use): $file"
        fi
        count_tmp=$((count_tmp+1))
    done
    progress_bar "$total_tmp" "$count_tmp"

    echo "[✅] Full cleanup completed."
}

# ⏰ Function: Schedule Cleanup at Boot
schedule_cleanup() {
    echo "⏰ Scheduling cleanup at boot..."
    CRON_CMD="@reboot bash $PWD/$0 --limpeza"
    (crontab -l 2>/dev/null | grep -v "$0" ; echo "$CRON_CMD") | crontab -
    echo "[✅] Cleanup scheduled at boot."
}

# 📋 Interactive Terminal Menu

# Skip menu when sourced by tests or other scripts
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return

# Handle --limpeza for cron execution
if [ "$1" == "--limpeza" ]; then
    limpeza_completa
    exit 0
fi

while true; do
    echo -e "
🛠️ System Maintenance Menu"
    echo "1️⃣  Backup configurations"
    echo "2️⃣  Restore configurations"
    echo "3️⃣  Full system cleanup"
    echo "4️⃣  Schedule cleanup at boot"
    echo "5️⃣  Exit"
    read -r -p "Choose an option: " option

    case "$option" in
        1) backup_configs ;;
        2)
            echo -e "
🔁 Restore Options"
            echo "1 - Interactive restore"
            echo "2 - Restore all (no prompt)"
            echo "3 - Back"
            read -r -p "Choose an option: " restopt
            case "$restopt" in
                1) restaurar_configs ;;
                2) restaurar_tudo ;;
                *) echo "↩️  Returning..." ;;
            esac
            ;;
        3) limpeza_completa ;;
        4) schedule_cleanup ;;
        5) echo "👋 Goodbye!"; exit 0 ;;
        *) echo "❌ Invalid option." ;;
    esac
done


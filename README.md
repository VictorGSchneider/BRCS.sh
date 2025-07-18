# 🛠️ BRCS.sh, a Linux System Maintenance CLI

A handy command-line tool to back up and restore Linux system configurations, clean up unnecessary files, and schedule automatic maintenance at system startup.
BRCS is an acronym for Backup, Restoration, Cleaner and Schedule.

## 📦 Features

- 💾 Backup configuration files (`.conf`, `.ini`, `.rules`, etc.)
- 🔁 Restore interactively or in bulk
- 🧹 Clean package cache, orphaned packages, Snap, Flatpak, and Steam leftovers
- ⏰ Schedule cleanup automatically at boot
- 📊 Terminal-based progress bar for all operations
- Simple, intuitive terminal menu interface

## ⚙️ Requirements

- `bash`
- `zip`
- `unzip`
- `locate`
- `deborphan` *(optional but recommended)*
- `localepurge` *(optional)*
- `flatpak` *(optional)*
- `snapd` *(optional)*

### Install missing tools via:
`sudo apt install zip unzip locate deborphan localepurge flatpak snapd`

## 🚀 How to Use

1. Download the file:

2. Make the script executable:
`chmod +x BRCS.sh`

3. Run it:
`./BRCS.sh`

4. Follow the interactive menu.
```
🛠️ System Maintenance Menu
1️⃣  Backup configurations
2️⃣  Restore configurations
3️⃣  Full system cleanup
4️⃣  Schedule cleanup at boot
5️⃣  Exit
```

## 📁 Backups

Backup files are saved in the format: `hostname.confs.YYYYMMDD.zip`

Logs are saved to `~/backup_YYYYMMDD.log`

## 🖥️ System Information

| Component         | Details                                      |
|------------------|----------------------------------------------|
| **Model**         | Lenovo IdeaPad S145-15IWL                    |
| **Memory**        | 8 GiB                                        |
| **Processor**     | Intel® Core™ i7-8565U CPU @ 1.80GHz × 8      |
| **Graphics**      | Mesa Intel® UHD Graphics 620 (WHL GT2)       |
| **Disk Capacity** | 120 GB                                       |
| **OS**            | Zorin OS 17.3 Core (64-bit)                  |
| **Window System** | Wayland                                      |

🧪 This utility has been tested and works well with the setup above.

## 📜 License

This project is licensed under the terms of the [GNU General Public License v3.0](LICENSE).

## Contributing

To run the test suite you need the [Bats](https://github.com/bats-core/bats-core) framework.
Install it via your package manager (e.g. `sudo apt install bats`) and then execute:

```bash
bats test
```


# glpi-links-install.sh

Automated installer for GLPI on a fresh Ubuntu/Debian machine. Handles everything from system checks to backup restore in a single script, with colored output, idempotent steps, and no hardcoded paths.

---

## Requirements

- Ubuntu 22.04+ or Debian 11+ (other Debian-based distros may work)
- Architecture: `amd64`, `arm64`, or `arm-7`
- At least `512MB` RAM and `5GB` free disk space
- A regular user with `sudo` privileges (do **not** run as root)
- An SSH key registered on GitHub (for cloning the private `glpi-stack` repo)
- Internet access

---

## Usage

```bash
curl -fsSL https://links-ads.github.io/glpi-stack-installer/glpi-links-install.sh | bash
```

The script is safe to re-run — every step checks whether it has already been completed and skips it if so.

---

## What It Does

The installer runs through 11 sequential steps:

### Step 1 — System Checks
Verifies architecture (`amd64`, `arm64`, `arm-7`), operating system (Linux only), distribution (Debian/Ubuntu family), available RAM (minimum 512MB), and free disk space (minimum 5GB). Unsupported distributions trigger a confirmation prompt rather than a hard failure.

### Step 2 — Dependencies
Installs the following packages if not already present: `curl`, `wget`, `tree`, `screenfetch`, `rclone`, `smartmontools`. Only missing packages are installed — existing ones are reported and skipped.

### Step 3 — Docker
Checks for an existing Docker installation (minimum version 20). If not found, installs via the official `get.docker.com` script. Also installs the Docker Compose plugin if missing, and adds the current user to the `docker` group.

### Step 4 — GLPI Stack
Creates `~/DockerApps/` and clones the private `glpi-stack` repository into `~/DockerApps/glpi`. If the repository already exists, pulls the latest changes instead. After cloning, marks `backup_tool/rclone.conf` with `git update-index --skip-worktree` so that rclone's automatic token updates do not interfere with future pulls.

### Step 5 — Start GLPI & Create Backup User
Starts the full GLPI stack with `docker compose up -d`. Waits for MySQL to be ready by probing it with `mysqladmin ping`. Retrieves the auto-generated MySQL root password from the container logs and saves it securely to `~/DockerApps/glpi/.mysql_root_password` (`chmod 600`, owned by root). Creates a dedicated `glpi_backup` MySQL user with read-only privileges for use by the backup scripts.

### Step 6 — GLPI Marketplace
Checks whether a GLPI Network registration key is already set in the database. If not, prompts the user to paste their key (skippable). Sets the key via the GLPI console command, which handles encryption automatically.

> You can find your GLPI Network key at [services.glpi-network.com](https://services.glpi-network.com).

### Step 7 — Plugin Installation
Checks whether the required plugins (`Fields` and `Accounts Inventory`) are already installed and enabled. If not, displays step-by-step browser instructions and waits for the user to complete the installation via the GLPI web UI. Verifies the result in the database (`glpi_plugins.state = 1`) and loops until both plugins are confirmed active.

### Step 8 — Apply Patches
Applies all `.patch` files found in `~/DockerApps/glpi/patches/` to the GLPI source code inside the container. The patches directory is bind-mounted into the container, so no file copying is needed. Uses `patch --forward` so already-applied patches are skipped gracefully. Cleans up any `.rej` files left behind. Logs every run to `patches/apply-patches.log`.

### Step 9 — Aliases & Dropbox Sync
Adds a line to `~/.bash_aliases` to source `~/DockerApps/glpi/.glpi_aliases`, making GLPI shell aliases available in interactive sessions. Then syncs backup archives from Dropbox (`dropbox:glpi-backups`) to the local `backup_tool/output/` directory using rclone. After a successful sync, restarts the GLPI container so the bind-mounted output directory reflects the newly downloaded files.

### Step 10 — Restore Latest Backup
Scans the `backup_tool/output/` directory for backup folders (named by date, e.g. `2026-04-26_000001`), identifies the most recent one, and asks the user whether to restore it. If confirmed, runs the restore script inside the container as root. This step is skipped automatically if the Dropbox sync in Step 9 failed.

### Step 11 — Backup Cronjob
Configures two things for automated daily backups:

1. Creates `/etc/sudoers.d/glpi-rclone` — a drop-in sudoers file that allows the current user to run `rclone` without a password, while preserving the necessary environment variables (`RCLONE_CONFIG_PASS`, `RCLONE_CONFIG`, `RCLONE_REMOTE`). The file is validated with `visudo -cf` before being saved.
2. Adds a crontab entry for the current user that runs `glpi-backupandsync.sh` daily at 02:00, logging output to `backup_tool/glpi-backup.log`.

---

## File Structure After Installation

```
~/DockerApps/
└── glpi/                          ← cloned from git@github.com:links-ads/glpi-stack.git
    ├── docker-compose.yml
    ├── .env                        ← DB credentials and config
    ├── .glpi_aliases               ← shell aliases (sourced via ~/.bash_aliases)
    ├── .mysql_root_password        ← root-only, chmod 600
    ├── patches/
    │   ├── *.patch                 ← custom GLPI patches
    │   └── apply-patches.log
    └── backup_tool/
        ├── glpi-backup.sh
        ├── glpi-restore.sh
        ├── glpi-backupandsync.sh
        ├── glpi-backup.conf
        ├── rclone.conf             ← skip-worktree, not tracked by git
        ├── glpi-backup.log
        └── output/                 ← backup archives (bind-mounted into container)
            └── YYYY-MM-DD_HHMMSS/
```

---

## Available Shell Aliases

After running `source ~/.bash_aliases`, the following commands are available:

| Alias | Description |
|---|---|
| `glpi-backup` | Run a manual backup inside the container |
| `glpi-restore <folder>` | Restore a specific backup by folder name |
| `glpi-sync-push` | Sync local backups to Dropbox |
| `glpi-sync-pull` | Pull backups from Dropbox to local |

---

## Resetting for a Clean Re-install

To wipe everything and start from scratch:

```bash
# Remove containers and volumes
sudo docker rm -f glpi-glpi-1 glpi-db-1
sudo docker volume rm glpi_glpi_data glpi_db_data

# Remove the repo and data
rm -rf ~/DockerApps

# Remove cronjob
crontab -r

# Remove sudoers entry
sudo rm /etc/sudoers.d/glpi-rclone

# Remove bash_aliases entry
nano ~/.bash_aliases  # delete the line referencing .glpi_aliases
```

Then re-run the installer:

```bash
bash glpi-links-install.sh
```

---

## Notes

- The script uses `sudo` internally for all privileged operations — do not run it as root directly.
- `rclone.conf` is tracked in the repo but marked with `--skip-worktree` on each machine to prevent rclone's automatic token updates from blocking git pulls. To intentionally update the file in the repo, temporarily remove the flag with `git update-index --no-skip-worktree backup_tool/rclone.conf`.
- The MySQL root password is used only during installation (to create the backup user) and is never printed to the terminal. It is saved to `.mysql_root_password` for emergency troubleshooting only.
- GLPI 11 stores the Network registration key encrypted in the database. The installer sets it via the GLPI console command (`glpi:config:set`) rather than a direct SQL update.

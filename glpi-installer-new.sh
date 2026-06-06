#!/usr/bin/env bash
#
#           GLPI Installer Script
#
#   Installs GLPI (with Docker) on a fresh Ubuntu/Debian system.
#   Usage:
#       $ curl -fsSL https://your-repo/glpi-install.sh | bash
#         or
#       $ bash glpi-install.sh
#

set -e

export DEBIAN_FRONTEND=noninteractive

###############################################################################
# GLOBALS                                                                     #
###############################################################################

[[ $EUID -ne 0 ]] && sudo_cmd="sudo"

# Source OS info
# shellcheck source=/dev/null
source /etc/os-release

# System info
UNAME_M="$(uname -m)"
readonly UNAME_M

UNAME_U="$(uname -s)"
readonly UNAME_U

LSB_DIST="$( ([[ -n "${ID_LIKE}" ]] && echo "${ID_LIKE}") || ([[ -n "${ID}" ]] && echo "${ID}") )"
readonly LSB_DIST

DIST="${ID}"
readonly DIST

PHYSICAL_MEMORY=$(LC_ALL=C free -m | awk '/Mem:/ { print $2 }')
readonly PHYSICAL_MEMORY

FREE_DISK_BYTES=$(LC_ALL=C df -P / | tail -n 1 | awk '{print $4}')
readonly FREE_DISK_BYTES
readonly FREE_DISK_GB=$((FREE_DISK_BYTES / 1024 / 1024))

# Requirements
readonly MINIMUM_MEMORY_MB="512"
readonly MINIMUM_DISK_GB="5"

# Detected arch (set by Check_Arch)
TARGET_ARCH=""

###############################################################################
# COLORS & OUTPUT                                                             #
###############################################################################

readonly COLOUR_RESET='\e[0m'
readonly aCOLOUR=(
    '\e[38;5;154m'  # [0] Green      — lines, bullets, separators
    '\e[1m'         # [1] Bold white  — main descriptions
    '\e[90m'        # [2] Grey        — secondary text
    '\e[91m'        # [3] Red         — errors / failures
    '\e[33m'        # [4] Yellow      — warnings / emphasis
)

readonly GREEN_LINE=" ${aCOLOUR[0]}─────────────────────────────────────────────────────${COLOUR_RESET}"
readonly GREEN_BULLET=" ${aCOLOUR[0]}-${COLOUR_RESET}"

# $1 : 0=OK  1=FAILED  2=INFO  3=WARN
Show() {
    case "$1" in
        0) echo -e "${aCOLOUR[2]}[${COLOUR_RESET}${aCOLOUR[0]}  OK  ${COLOUR_RESET}${aCOLOUR[2]}]${COLOUR_RESET} $2" ;;
        1) echo -e "${aCOLOUR[2]}[${COLOUR_RESET}${aCOLOUR[3]}FAILED${COLOUR_RESET}${aCOLOUR[2]}]${COLOUR_RESET} $2" ; exit 1 ;;
        2) echo -e "${aCOLOUR[2]}[${COLOUR_RESET}${aCOLOUR[0]} INFO ${COLOUR_RESET}${aCOLOUR[2]}]${COLOUR_RESET} $2" ;;
        3) echo -e "${aCOLOUR[2]}[${COLOUR_RESET}${aCOLOUR[4]} WARN ${COLOUR_RESET}${aCOLOUR[2]}]${COLOUR_RESET} $2" ;;
    esac
}

trap 'echo -e "${COLOUR_RESET}"; exit 1' INT

###############################################################################
# BANNER                                                                      #
###############################################################################

Show_Banner() {
    echo -e "${aCOLOUR[0]}"
    echo '   _____ _      _____ _____   ___           _        _ _           '
    echo '  / ____| |    |  __ \_   _| |_ _|_ __  ___| |_ __ _| | | ___ _ __ '
    echo ' | |  __| |    | |__) || |    | || `_ \/ __| __/ _` | | |/ _ \ `__|'
    echo ' | | |_ | |    |  ___/ | |    | || | | \__ \ || (_| | | |  __/ |   '
    echo ' | |__| | |____| |    _| |_  |___|_| |_|___/\__\__,_|_|_|\___|_|   '
    echo '  \_____|______|_|   |_____|                                         '
    echo -e "${COLOUR_RESET}"
    echo -e "${GREEN_LINE}"
    echo -e " ${aCOLOUR[1]}GLPI Automated Installer${COLOUR_RESET}"
    echo -e "${GREEN_LINE}"
    echo ""
}

###############################################################################
# ARGUMENT PARSING                                                            #
###############################################################################

CUSTOM_DIR=""
SSH_KEY=""

usage() {
    echo ""
    echo -e "  ${aCOLOUR[1]}GLPI Installer — Usage${COLOUR_RESET}"
    echo ""
    echo "  bash glpi-links-install.sh [OPTIONS]"
    echo ""
    echo "  Options:"
    echo "    -d, --dir <path>       Installation directory (default: ~/DockerApps)"
    echo "    -k, --ssh-key <path>   SSH private key for GitHub (default: ~/.ssh/id_rsa)"
    echo "    -h, --help             Show this help message"
    echo ""
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d | --dir)
                CUSTOM_DIR="$2"
                shift 2
                ;;
            -k | --ssh-key)
                SSH_KEY="$2"
                shift 2
                ;;
            -h | --help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done
}

###############################################################################
# STEP 1 — SYSTEM CHECKS                                                     #
###############################################################################

Check_Arch() {
    Show 2 "Checking system architecture..."
    case "$UNAME_M" in
        *aarch64* | *arm64*) TARGET_ARCH="arm64" ;;
        *x86_64* | *amd64*)  TARGET_ARCH="amd64" ;;
        *armv7*)             TARGET_ARCH="arm-7" ;;
        *) Show 1 "Unsupported architecture: ${UNAME_M}. Aborting." ;;
    esac
    Show 0 "Architecture: ${UNAME_M} → ${TARGET_ARCH}"
}

Check_OS() {
    Show 2 "Checking operating system..."
    if [[ "$UNAME_U" != *Linux* ]]; then
        Show 1 "This installer only supports Linux. Detected: ${UNAME_U}"
    fi
    Show 0 "Operating system: ${UNAME_U}"
}

Check_Distribution() {
    Show 2 "Checking Linux distribution..."
    case "$LSB_DIST" in
        *debian* | *ubuntu* | *raspbian*)
            Show 0 "Distribution: ${DIST} (supported)"
            ;;
        *)
            Show 3 "Distribution '${DIST}' is not officially supported."
            echo -e "${aCOLOUR[4]}  This installer is designed for Debian/Ubuntu systems."
            echo -e "  Installation may still work but is not guaranteed.${COLOUR_RESET}"
            echo ""
            read -rp "  Continue anyway? [y/N] " yn </dev/tty
            case "$yn" in
                [yY][eE][sS] | [yY]) Show 0 "Distribution check bypassed by user." ;;
                *) Show 1 "Aborted by user." ;;
            esac
            ;;
    esac
}

Check_Memory() {
    Show 2 "Checking available memory..."
    if [[ "${PHYSICAL_MEMORY}" -lt "${MINIMUM_MEMORY_MB}" ]]; then
        Show 1 "At least ${MINIMUM_MEMORY_MB}MB of RAM is required. Detected: ${PHYSICAL_MEMORY}MB"
    fi
    Show 0 "Memory: ${PHYSICAL_MEMORY}MB (minimum: ${MINIMUM_MEMORY_MB}MB)"
}

Check_Disk() {
    Show 2 "Checking available disk space..."
    if [[ "${FREE_DISK_GB}" -lt "${MINIMUM_DISK_GB}" ]]; then
        Show 3 "Free disk space is ${FREE_DISK_GB}GB, recommended minimum is ${MINIMUM_DISK_GB}GB."
        echo ""
        read -rp "  Continue anyway? [y/N] " yn </dev/tty
        case "$yn" in
            [yY][eE][sS] | [yY]) Show 0 "Disk space check bypassed by user." ;;
            *) Show 1 "Aborted by user." ;;
        esac
    else
        Show 0 "Disk space: ${FREE_DISK_GB}GB free (minimum: ${MINIMUM_DISK_GB}GB)"
    fi
}

###############################################################################
# STEP 2 — DEPENDENCIES                                                       #
###############################################################################

readonly DEP_COMMANDS=('curl' 'wget' 'tree' 'screenfetch' 'rclone' 'smartctl')
readonly DEP_PACKAGES=('curl' 'wget' 'tree' 'screenfetch' 'rclone'  'smartmontools')
readonly MINIMUM_DOCKER_VERSION="20"

Update_Package_Index() {
    Show 2 "Updating package index..."
    ${sudo_cmd} apt-get update -qq
    Show 0 "Package index updated."
}

Install_Dependencies() {
    Show 2 "Checking required dependencies..."
    local missing=()
    for ((i = 0; i < ${#DEP_COMMANDS[@]}; i++)); do
        cmd="${DEP_COMMANDS[$i]}"
        pkg="${DEP_PACKAGES[$i]}"
        if command -v "$cmd" &>/dev/null; then
            Show 0 "${pkg}: already installed ($(command -v "$cmd"))"
        else
            Show 3 "${pkg}: not found — will install"
            missing+=("$pkg")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        Show 0 "All dependencies already satisfied."
        return
    fi
    Show 2 "Installing: ${missing[*]}"
    ${sudo_cmd} apt-get install -y -qq "${missing[@]}"
    local failed=()
    for ((i = 0; i < ${#DEP_COMMANDS[@]}; i++)); do
        cmd="${DEP_COMMANDS[$i]}"
        pkg="${DEP_PACKAGES[$i]}"
        if ! command -v "$cmd" &>/dev/null; then
            failed+=("$pkg")
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        Show 1 "The following dependencies failed to install: ${failed[*]}"
    fi
    Show 0 "All dependencies installed successfully."
}

###############################################################################
# STEP 3 — DOCKER                                                             #
###############################################################################

Install_Docker() {
    Show 2 "Installing Docker via official install script..."
    ${sudo_cmd} curl -fsSL https://get.docker.com | bash
    if [[ $? -ne 0 ]]; then
        Show 1 "Docker installation failed. Please install Docker manually and re-run this script."
    fi
}

Check_Docker_Running() {
    Show 2 "Ensuring Docker service is active..."
    for ((i = 1; i <= 5; i++)); do
        if [[ $(${sudo_cmd} systemctl is-active docker 2>/dev/null) == "active" ]]; then
            Show 0 "Docker service is running."
            return
        fi
        Show 3 "Docker not active yet, attempt ${i}/5 — retrying in 3s..."
        sleep 3
        ${sudo_cmd} systemctl start docker || true
    done
    Show 1 "Docker service failed to start. Check: systemctl status docker"
}

Check_Docker_Install() {
    Show 2 "Checking Docker installation..."
    if command -v docker &>/dev/null; then
        DOCKER_VERSION=$(${sudo_cmd} docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")
        DOCKER_MAJOR="${DOCKER_VERSION%%.*}"
        if [[ "$DOCKER_MAJOR" -lt "$MINIMUM_DOCKER_VERSION" ]]; then
            Show 3 "Docker ${DOCKER_VERSION} is below the recommended minimum (v${MINIMUM_DOCKER_VERSION})."
            Show 1 "Please remove the old Docker version and re-run this script."
        fi
        Show 0 "Docker ${DOCKER_VERSION} is installed."
        Check_Docker_Running
    else
        Show 3 "Docker not found — installing..."
        Install_Docker
        Check_Docker_Running
    fi
}

Check_Docker_Compose() {
    Show 2 "Checking Docker Compose (plugin)..."
    if ${sudo_cmd} docker compose version &>/dev/null; then
        COMPOSE_VERSION=$(${sudo_cmd} docker compose version --short 2>/dev/null || echo "unknown")
        Show 0 "Docker Compose plugin: v${COMPOSE_VERSION}"
    else
        Show 3 "Docker Compose plugin not found — installing..."
        ${sudo_cmd} apt-get install -y -qq docker-compose-plugin
        if ${sudo_cmd} docker compose version &>/dev/null; then
            Show 0 "Docker Compose plugin installed."
        else
            Show 1 "Docker Compose plugin installation failed. Please install it manually."
        fi
    fi
}

Add_User_To_Docker_Group() {
    local real_user="${SUDO_USER:-$USER}"
    if [[ -z "$real_user" ]]; then
        Show 3 "Could not determine the current user — skipping docker group assignment."
        return
    fi
    if groups "$real_user" 2>/dev/null | grep -q docker; then
        Show 0 "User '${real_user}' is already in the docker group."
        return
    fi
    Show 2 "Adding '${real_user}' to the docker group..."
    ${sudo_cmd} usermod -aG docker "$real_user"
    Show 0 "User '${real_user}' added to the docker group."
    Show 3 "You will need to log out and back in (or reboot) for this to take effect."
    Show 3 "Until then, all docker commands require sudo."
}

###############################################################################
# STEP 4 — GLPI STACK                                                         #
###############################################################################

readonly GLPI_REPO="git@github.com:links-ads/glpi-stack.git"

# These are set in main() after parse_args() so they reflect --dir if provided
DOCKER_APPS_DIR=""
GLPI_DIR=""

Check_SSH_Key() {
    Show 2 "Checking SSH connectivity to GitHub..."

    local ssh_opts="-o StrictHostKeyChecking=no -o BatchMode=yes"
    if [[ -n "${SSH_KEY}" ]]; then
        ssh_opts="${ssh_opts} -i ${SSH_KEY}"
        Show 2 "Using SSH key: ${SSH_KEY}"
    fi

    local result
    result=$(ssh -T git@github.com ${ssh_opts} 2>&1 || true)
    if echo "$result" | grep -q "successfully authenticated"; then
        Show 0 "SSH key authentication to GitHub: OK"
    else
        Show 1 "Cannot authenticate to GitHub via SSH. Make sure your SSH key is set up correctly.\n  Run: ssh -T git@github.com to debug."
    fi
}

Setup_GLPI_Stack() {
    Show 2 "Creating DockerApps directory at ${DOCKER_APPS_DIR}..."
    mkdir -p "${DOCKER_APPS_DIR}"
    Show 0 "Directory ready: ${DOCKER_APPS_DIR}"

    # Build git SSH command if a custom key is provided
    local git_ssh_cmd=""
    if [[ -n "${SSH_KEY}" ]]; then
        git_ssh_cmd="GIT_SSH_COMMAND='ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no'"
    fi

    if [[ -d "${GLPI_DIR}/.git" ]]; then
        Show 3 "${GLPI_DIR} already exists — pulling latest changes..."
        eval "${git_ssh_cmd}" git -C "${GLPI_DIR}" fetch --all
        eval "${git_ssh_cmd}" git -C "${GLPI_DIR}" pull --rebase
        Show 0 "Repository updated: ${GLPI_DIR}"
    elif [[ -d "${GLPI_DIR}" ]] && [[ ! -d "${GLPI_DIR}/.git" ]]; then
        Show 1 "${GLPI_DIR} exists but is not a git repository. Please remove or rename it and re-run the script."
    else
        Show 2 "Cloning ${GLPI_REPO} into ${GLPI_DIR}..."
        eval "${git_ssh_cmd}" git clone "${GLPI_REPO}" "${GLPI_DIR}"
        Show 0 "Repository cloned: ${GLPI_DIR}"
    fi

    Show 2 "Marking backup_tool/rclone.conf as skip-worktree..."
    git -C "${GLPI_DIR}" update-index --skip-worktree backup_tool/rclone.conf 2>/dev/null || true
    Show 0 "rclone.conf will not block future git pulls."
}

###############################################################################
# STEP 5 — START GLPI & CREATE BACKUP USER                                    #
###############################################################################

readonly DB_CONTAINER="glpi-db-1"
readonly GLPI_CONTAINER="glpi-glpi-1"
readonly BACKUP_USER="glpi_backup"
readonly BACKUP_PASSWORD="glpi_backup"
readonly CATALOG_USER="glpi_catalog"
readonly CATALOG_PASSWORD="glpi_catalog"

MYSQL_ROOT_PASSWORD=""

Start_GLPI_Stack() {
    Show 2 "Starting GLPI stack with Docker Compose..."
    ${sudo_cmd} docker compose -f "${GLPI_DIR}/docker-compose.yml" up -d
    Show 0 "Docker Compose started."
}

Wait_For_DB() {
    Show 2 "Waiting for MySQL to be ready inside container '${DB_CONTAINER}'..."
    local max_attempts=30
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        local running
        running=$(${sudo_cmd} docker inspect --format='{{.State.Running}}' "${DB_CONTAINER}" 2>/dev/null || echo "false")
        if [[ "$running" == "true" ]]; then
            break
        fi
        Show 2 "Waiting for container to start... (${attempt}/${max_attempts})"
        sleep 3
        attempt=$((attempt + 1))
    done
    if [[ $attempt -gt $max_attempts ]]; then
        Show 1 "Container '${DB_CONTAINER}' did not start in time. Check: sudo docker logs ${DB_CONTAINER}"
    fi
    Show 2 "Container is running. Probing MySQL with mysqladmin ping..."
    attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if ${sudo_cmd} docker exec "${DB_CONTAINER}" mysqladmin ping -h 127.0.0.1 --silent 2>/dev/null; then
            Show 0 "MySQL is ready and accepting connections."
            return 0
        fi
        Show 2 "MySQL not ready yet, attempt ${attempt}/${max_attempts}..."
        sleep 5
        attempt=$((attempt + 1))
    done
    Show 1 "MySQL did not become ready in time. Check: sudo docker logs ${DB_CONTAINER}"
}

Wait_For_GLPI() {
    Show 2 "Waiting for GLPI to complete first-run initialization..."

    local env_file="${GLPI_DIR}/.env"
    local db_user db_password db_name
    db_user=$(grep -E '^GLPI_DB_USER=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')
    db_password=$(grep -E '^GLPI_DB_PASSWORD=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')
    db_name=$(grep -E '^GLPI_DB_NAME=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')

    local max_attempts=60  # up to 5 minutes
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        local dbversion
        dbversion=$(${sudo_cmd} docker exec "${DB_CONTAINER}" mysql \
            -u "${db_user}" \
            -p"${db_password}" \
            "${db_name}" \
            -sN \
            -e "SELECT value FROM glpi_configs WHERE name = 'dbversion';" \
            2>/dev/null | tr -d '[:space:]')

        if [[ -n "${dbversion}" && "${dbversion}" != "NULL" ]]; then
            Show 0 "GLPI initialization complete (dbversion: ${dbversion})."
            return 0
        fi

        Show 2 "GLPI not initialized yet, attempt ${attempt}/${max_attempts}..."
        sleep 5
        attempt=$((attempt + 1))
    done

    Show 1 "GLPI did not complete initialization in time. Check: sudo docker logs ${GLPI_CONTAINER}"
}

Get_MySQL_Root_Password() {
    Show 2 "Retrieving generated MySQL root password from container logs..."
    local max_attempts=12
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        MYSQL_ROOT_PASSWORD=$(${sudo_cmd} docker logs "${DB_CONTAINER}" 2>&1 \
            | grep "GENERATED ROOT PASSWORD:" \
            | sed 's/.*GENERATED ROOT PASSWORD: //' \
            | tr -d '[:space:]')
        if [[ -n "${MYSQL_ROOT_PASSWORD}" ]]; then
            Show 0 "MySQL root password retrieved successfully."
            local creds_file="${GLPI_DIR}/.mysql_root_password"
            ${sudo_cmd} bash -c "cat > '${creds_file}' <<EOF
# GLPI MySQL root credentials
# Generated on: $(date '+%Y-%m-%d %H:%M:%S')
# WARNING: keep this file secure — do not share or commit to git
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
EOF"
            ${sudo_cmd} chmod 600 "${creds_file}"
            ${sudo_cmd} chown root:root "${creds_file}"
            Show 0 "Root password saved to: ${creds_file} (root-only, chmod 600)"
            return 0
        fi
        Show 2 "Password not in logs yet, attempt ${attempt}/${max_attempts}..."
        sleep 5
        attempt=$((attempt + 1))
    done
    Show 1 "Could not retrieve the generated MySQL root password.\n  This may mean the DB was already initialized previously.\n  Check manually: sudo docker logs ${DB_CONTAINER} 2>&1 | grep 'GENERATED ROOT PASSWORD'"
}

Create_Backup_User() {
    Show 2 "Creating MySQL backup user '${BACKUP_USER}'..."
    local result=0
    ${sudo_cmd} docker exec "${DB_CONTAINER}" mysql \
        -u root \
        -p"${MYSQL_ROOT_PASSWORD}" \
        --connect-expired-password \
        -e "
            CREATE USER IF NOT EXISTS '${BACKUP_USER}'@'%' IDENTIFIED BY '${BACKUP_PASSWORD}';
            GRANT SELECT, SHOW VIEW, RELOAD, REPLICATION CLIENT, EVENT, TRIGGER, LOCK TABLES, PROCESS ON *.* TO '${BACKUP_USER}'@'%';
            FLUSH PRIVILEGES;
        " 2>/dev/null || result=$?
    if [[ $result -eq 0 ]]; then
        Show 0 "Backup user '${BACKUP_USER}' created and privileges granted."
        echo ""
        echo -e "${GREEN_LINE}"
        Show 0 "GLPI is up and running at ${GLPI_DIR}"
        Show 0 "Backup user '${BACKUP_USER}' is ready for use."
        echo -e "${GREEN_LINE}"
    else
        Show 1 "Failed to create backup user. Check MySQL logs: docker logs ${DB_CONTAINER}"
    fi
}

Create_Catalog_User() {
    Show 2 "Creating MySQL catalog read-only user '${CATALOG_USER}'..."
    local result=0
    ${sudo_cmd} docker exec "${DB_CONTAINER}" mysql \
        -u root \
        -p"${MYSQL_ROOT_PASSWORD}" \
        --connect-expired-password \
        -e "
            CREATE USER IF NOT EXISTS '${CATALOG_USER}'@'%' IDENTIFIED BY '${CATALOG_PASSWORD}';
            GRANT SELECT ON glpi.glpi_softwares TO '${CATALOG_USER}'@'%';
            GRANT SELECT ON glpi.glpi_softwarelicenses TO '${CATALOG_USER}'@'%';
            GRANT SELECT ON glpi.glpi_items_softwarelicenses TO '${CATALOG_USER}'@'%';
            GRANT SELECT ON glpi.glpi_softwarelicenses_users TO '${CATALOG_USER}'@'%';
            GRANT SELECT ON glpi.glpi_softwarelicensetypes TO '${CATALOG_USER}'@'%';
            FLUSH PRIVILEGES;
        " 2>/dev/null || result=$?
    if [[ $result -eq 0 ]]; then
        Show 0 "Catalog user '${CATALOG_USER}' created with read-only access to software/license tables."
    else
        Show 1 "Failed to create catalog user. Check DB connectivity and root password."
    fi
}

###############################################################################
# STEP 6 — GLPI NETWORK KEY                                                   #
###############################################################################

GLPI_NETWORK_KEY=""

Check_Network_Key_Exists() {
    local env_file="${GLPI_DIR}/.env"
    local db_user db_password db_name
    db_user=$(grep -E '^GLPI_DB_USER=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')
    db_password=$(grep -E '^GLPI_DB_PASSWORD=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')
    db_name=$(grep -E '^GLPI_DB_NAME=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')
    local current
    current=$(${sudo_cmd} docker exec "${DB_CONTAINER}" mysql \
        -u "${db_user}" \
        -p"${db_password}" \
        "${db_name}" \
        -sN \
        -e "SELECT value FROM glpi_configs WHERE name = 'glpinetwork_registration_key';" \
        2>/dev/null | tr -d '[:space:]')
    if [[ -n "${current}" && "${current}" != "NULL" ]]; then
        return 0
    fi
    return 1
}

Prompt_Network_Key() {
    Show 2 "Checking GLPI Network registration key..."
    if Check_Network_Key_Exists; then
        Show 0 "GLPI Network key already set — skipping."
        return 0
    fi
    Show 3 "No GLPI Network key found."
    echo ""
    echo -e "${aCOLOUR[1]}  GLPI Marketplace Network Key${COLOUR_RESET}"
    echo -e "${aCOLOUR[2]}  You can find your key at: https://services.glpi-network.com${COLOUR_RESET}"
    echo ""
    while [[ -z "${GLPI_NETWORK_KEY}" ]]; do
        read -rp "  Paste your GLPI Network key (or press Enter to skip): " GLPI_NETWORK_KEY </dev/tty
        if [[ -z "${GLPI_NETWORK_KEY}" ]]; then
            Show 3 "No key provided — skipping marketplace activation."
            Show 3 "You can set it later via GLPI web UI: Setup → General → GLPI Network."
            return 0
        fi
    done
}

Set_Network_Key() {
    Show 2 "Setting GLPI Network key via GLPI console..."
    local result=0
    ${sudo_cmd} docker exec "${GLPI_CONTAINER}" php /var/www/glpi/bin/console \
        glpi:config:set glpinetwork_registration_key "${GLPI_NETWORK_KEY}" --context=core \
        2>/dev/null || result=$?
    if [[ $result -eq 0 ]]; then
        Show 0 "GLPI Network key set successfully. Marketplace is now enabled."
    else
        Show 1 "Failed to set GLPI Network key. You can set it manually via the web UI."
    fi
}

###############################################################################
# STEP 7 — PLUGIN INSTALLATION                                                #
###############################################################################

readonly REQUIRED_PLUGINS=('fields' 'accounts')

Get_GLPI_Port() {
    local compose_file="${GLPI_DIR}/docker-compose.yml"
    grep -A1 'ports:' "${compose_file}" \
        | grep -oP '^\s*-\s*"\K[0-9]+(?=:)' \
        | head -n1
}

Verify_Plugins() {
    local env_file="${GLPI_DIR}/.env"
    local db_user db_password db_name
    db_user=$(grep -E '^GLPI_DB_USER=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')
    db_password=$(grep -E '^GLPI_DB_PASSWORD=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')
    db_name=$(grep -E '^GLPI_DB_NAME=' "${env_file}" | cut -d'=' -f2 | tr -d '[:space:]')
    local all_ok=true
    for plugin in "${REQUIRED_PLUGINS[@]}"; do
        local state
        state=$(${sudo_cmd} docker exec "${DB_CONTAINER}" mysql \
            -u "${db_user}" \
            -p"${db_password}" \
            "${db_name}" \
            -sN \
            -e "SELECT state FROM glpi_plugins WHERE directory = '${plugin}';" \
            2>/dev/null | tr -d '[:space:]')
        if [[ "${state}" == "1" ]]; then
            Show 0 "Plugin '${plugin}': installed and enabled. ✓"
        elif [[ "${state}" == "4" ]]; then
            Show 3 "Plugin '${plugin}': installed but NOT enabled — please enable it in GLPI."
            all_ok=false
        else
            Show 3 "Plugin '${plugin}': not found (state=${state:-missing}) — please install and enable it."
            all_ok=false
        fi
    done
    if [[ "${all_ok}" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

Install_Plugins() {
    Show 2 "Checking if required plugins are already installed and enabled..."
    if Verify_Plugins; then
        Show 0 "All required plugins are already active — skipping."
        return 0
    fi
    local glpi_port
    glpi_port=$(Get_GLPI_Port)
    if [[ -z "${glpi_port}" ]]; then
        glpi_port="38080"
        Show 3 "Could not detect port from docker-compose.yml — defaulting to ${glpi_port}."
    fi
    echo ""
    echo -e "${aCOLOUR[1]}  Manual plugin installation required${COLOUR_RESET}"
    echo -e "${GREEN_LINE}"
    echo -e "  ${aCOLOUR[0]}1.${COLOUR_RESET} Open your browser and go to: ${aCOLOUR[4]}http://localhost:${glpi_port}${COLOUR_RESET}"
    echo -e "  ${aCOLOUR[0]}2.${COLOUR_RESET} Log in with: ${aCOLOUR[4]}glpi / glpi${COLOUR_RESET}"
    echo -e "  ${aCOLOUR[0]}3.${COLOUR_RESET} Go to: ${aCOLOUR[4]}Setup → Plugins → Marketplace${COLOUR_RESET}"
    echo -e "  ${aCOLOUR[0]}4.${COLOUR_RESET} Search and install: ${aCOLOUR[4]}Fields${COLOUR_RESET}"
    echo -e "  ${aCOLOUR[0]}5.${COLOUR_RESET} Search and install: ${aCOLOUR[4]}Account Inventory${COLOUR_RESET}"
    echo -e "  ${aCOLOUR[0]}6.${COLOUR_RESET} Make sure both plugins are ${aCOLOUR[4]}installed AND enabled${COLOUR_RESET}"
    echo -e "${GREEN_LINE}"
    echo ""
    while true; do
        read -rp "  Press Enter when both plugins are installed and enabled..." </dev/tty
        echo ""
        Show 2 "Verifying plugins in database..."
        if Verify_Plugins; then
            Show 0 "All required plugins are installed and enabled."
            break
        else
            echo ""
            echo -e "${aCOLOUR[4]}  Some plugins are missing or not enabled. Please go back to GLPI and fix this before continuing.${COLOUR_RESET}"
            echo ""
        fi
    done
}

###############################################################################
# STEP 8 — APPLY PATCHES                                                      #
###############################################################################

readonly PATCH_DIR_CONTAINER="/var/lib/glpi-patches"
PATCH_DIR_HOST=""
PATCH_LOG=""

Apply_Patches() {
    Show 2 "Looking for patches in ${PATCH_DIR_HOST}..."
    if [[ ! -d "${PATCH_DIR_HOST}" ]]; then
        Show 3 "No patches directory found at ${PATCH_DIR_HOST} — skipping."
        return 0
    fi
    local patches=("${PATCH_DIR_HOST}"/*.patch)
    if [[ ! -f "${patches[0]}" ]]; then
        Show 3 "No .patch files found in ${PATCH_DIR_HOST} — skipping."
        return 0
    fi
    Show 2 "Found ${#patches[@]} patch(es) to apply."
    echo "=== Patch run: $(date) ===" >> "${PATCH_LOG}"
    local applied=0
    local skipped=0
    for patch in "${patches[@]}"; do
        local filename
        filename=$(basename "${patch}")
        Show 2 "Applying: ${filename}..."

        # First do a dry-run to check if patch needs applying at all
        local dry_result=0
        ${sudo_cmd} docker exec "${GLPI_CONTAINER}" \
            patch -p1 --forward --dry-run -d /var/www/glpi \
            -i "${PATCH_DIR_CONTAINER}/${filename}" &>/dev/null || dry_result=$?

        if [[ $dry_result -ne 0 ]]; then
            Show 3 "Skipped (already applied or failed): ${filename}"
            echo "⚠ Skipped: ${filename}" >> "${PATCH_LOG}"
            skipped=$((skipped + 1))
            ${sudo_cmd} docker exec "${GLPI_CONTAINER}" \
                find /var/www/glpi -name "*.rej" -delete 2>/dev/null || true
            continue
        fi

        # Dry-run passed — apply for real
        local result=0
        ${sudo_cmd} docker exec "${GLPI_CONTAINER}" \
            patch -p1 --forward -d /var/www/glpi \
            -i "${PATCH_DIR_CONTAINER}/${filename}" &>/dev/null || result=$?

        if [[ $result -eq 0 ]]; then
            Show 0 "Applied: ${filename}"
            echo "✓ Applied: ${filename}" >> "${PATCH_LOG}"
            applied=$((applied + 1))
        else
            Show 3 "Failed to apply: ${filename}"
            echo "✗ Failed: ${filename}" >> "${PATCH_LOG}"
            skipped=$((skipped + 1))
            ${sudo_cmd} docker exec "${GLPI_CONTAINER}" \
                find /var/www/glpi -name "*.rej" -delete 2>/dev/null || true
        fi
    done
    echo "Done. Applied: ${applied}, Skipped: ${skipped}" >> "${PATCH_LOG}"
    echo "" >> "${PATCH_LOG}"
    Show 0 "Patch run complete — applied: ${applied}, skipped: ${skipped}."
    Show 2 "Clearing GLPI cache..."
    ${sudo_cmd} docker exec "${GLPI_CONTAINER}" rm -rf /var/glpi/files/_cache \
        && Show 0 "Cache cleared." \
        || Show 3 "Cache clear failed — you may need to run it manually."
}

###############################################################################
# STEP 9 — ALIASES & DROPBOX SYNC                                             #
###############################################################################

Setup_Aliases() {
    Show 2 "Setting up GLPI shell aliases..."
    local real_user real_home
    real_user="${SUDO_USER:-$USER}"
    real_home=$(getent passwd "${real_user}" | cut -d: -f6)

    # Always use absolute path — relative paths break when sourcing from .bash_aliases
    local abs_glpi_dir
    abs_glpi_dir=$(realpath "${GLPI_DIR}")
    local aliases_source="${abs_glpi_dir}/.glpi_aliases"
    local bash_aliases="${real_home}/.bash_aliases"

    local source_line=". ${aliases_source}"
    if [[ -f "${bash_aliases}" ]] && grep -qF "${source_line}" "${bash_aliases}"; then
        Show 0 ".bash_aliases already sources .glpi_aliases — skipping."
    else
        Show 2 "Adding .glpi_aliases to ${bash_aliases}..."
        echo "${source_line}" >> "${bash_aliases}"
        Show 0 "Added to ${bash_aliases}. Run 'source ~/.bash_aliases' to activate."
    fi
}

Sync_From_Dropbox() {
    Show 2 "Syncing backups from Dropbox to local output folder..."
    local real_user real_home
    real_user="${SUDO_USER:-$USER}"
    real_home=$(getent passwd "${real_user}" | cut -d: -f6)
    local rclone_conf="${GLPI_DIR}/backup_tool/rclone.conf"
    local output_dir="${GLPI_DIR}/backup_tool/output"
    if [[ ! -f "${rclone_conf}" ]]; then
        Show 3 "rclone.conf not found at ${rclone_conf} — skipping Dropbox sync."
        return 0
    fi
    mkdir -p "${output_dir}"
    Show 2 "Running rclone sync from dropbox:glpi-backups → ${output_dir}..."
    local rclone_exit=0
    ${sudo_cmd} env RCLONE_CONFIG_PASS=adsadmin rclone \
        --config "${rclone_conf}" \
        sync dropbox:glpi-backups "${output_dir}" \
        --progress || rclone_exit=$?
    if [[ $rclone_exit -eq 0 ]]; then
        Show 0 "Dropbox sync complete. Backups available in: ${output_dir}"
        Show 2 "Restarting GLPI container to refresh bind mount..."
        ${sudo_cmd} docker restart "${GLPI_CONTAINER}" &>/dev/null
        local attempt=1
        while [[ $attempt -le 10 ]]; do
            if [[ $(${sudo_cmd} docker inspect --format='{{.State.Running}}' "${GLPI_CONTAINER}" 2>/dev/null) == "true" ]]; then
                Show 0 "Container restarted and running."
                return 0
            fi
            Show 2 "Waiting for container to come back up... (${attempt}/10)"
            sleep 3
            attempt=$((attempt + 1))
        done
        Show 3 "Container may not have restarted cleanly. Check: sudo docker ps"
    else
        Show 3 "Dropbox sync finished with errors (exit code: ${rclone_exit}). Check output manually."
    fi
}

###############################################################################
# STEP 10 — RESTORE MOST RECENT BACKUP                                        #
###############################################################################

Restore_Latest_Backup() {
    local output_dir="${GLPI_DIR}/backup_tool/output"
    if [[ ! -d "${output_dir}" ]]; then
        Show 3 "Backup output directory not found — skipping restore."
        return 0
    fi
    local latest
    latest=$(ls -1 "${output_dir}" 2>/dev/null | sort -r | head -n1)
    if [[ -z "${latest}" ]]; then
        Show 3 "No backup folders found in ${output_dir} — skipping restore."
        return 0
    fi
    echo ""
    echo -e "${aCOLOUR[1]}  Most recent backup found:${COLOUR_RESET}"
    echo -e "  ${aCOLOUR[4]}${latest}${COLOUR_RESET}"
    echo ""
    read -rp "  Do you want to restore this backup? [y/N] " answer </dev/tty
    echo ""
    case "${answer}" in
        [yY][eE][sS] | [yY])
            Show 2 "Restoring backup: ${latest}..."
            local result=0
            ${sudo_cmd} docker exec -i -u root "${GLPI_CONTAINER}" \
                /usr/local/bin/glpi-restore "${latest}" || result=$?
            if [[ $result -eq 0 ]]; then
                Show 0 "Backup restored successfully."
            else
                Show 3 "Restore finished with errors. Check the output above."
            fi
            ;;
        *)
            Show 3 "Restore skipped by user."
            ;;
    esac
}

###############################################################################
# STEP 11 — BACKUP CRONJOB                                                    #
###############################################################################

Setup_Cronjob() {
    local real_user real_home
    real_user="${SUDO_USER:-$USER}"
    real_home=$(getent passwd "${real_user}" | cut -d: -f6)

    # Always resolve to absolute paths — relative paths break cron
    local abs_glpi_dir
    abs_glpi_dir=$(realpath "${GLPI_DIR}")
    local backup_script="${abs_glpi_dir}/backup_tool/glpi-backupandsync.sh"
    local log_file="${abs_glpi_dir}/backup_tool/glpi-backup.log"
    local sudoers_file="/etc/sudoers.d/glpi-rclone"
    Show 2 "Configuring sudoers for passwordless rclone..."
    if [[ -f "${sudoers_file}" ]]; then
        Show 0 "Sudoers entry already exists — skipping."
    else
        ${sudo_cmd} bash -c "cat > '${sudoers_file}' <<'EOF'
# Allow ${real_user} to run rclone without password for GLPI backup sync
${real_user} ALL=(ALL) NOPASSWD: /usr/bin/rclone
Defaults env_keep += \"RCLONE_CONFIG_PASS RCLONE_CONFIG RCLONE_REMOTE\"
EOF"
        ${sudo_cmd} chmod 440 "${sudoers_file}"
        if ! ${sudo_cmd} visudo -cf "${sudoers_file}" &>/dev/null; then
            Show 1 "Sudoers file validation failed — removing to avoid lockout."
            ${sudo_cmd} rm -f "${sudoers_file}"
        fi
        Show 0 "Sudoers entry created at ${sudoers_file}."
    fi
    Show 2 "Setting up daily backup cronjob for user '${real_user}'..."
    local cron_job="0 2 * * * ${backup_script} >> ${log_file} 2>&1"
    if ${sudo_cmd} -u "${real_user}" crontab -l 2>/dev/null | grep -qF "${backup_script}"; then
        Show 0 "Cronjob already exists — skipping."
    else
        local tmp_cron
        tmp_cron=$(mktemp)
        ${sudo_cmd} -u "${real_user}" crontab -l 2>/dev/null > "${tmp_cron}" || true
        echo "${cron_job}" >> "${tmp_cron}"
        ${sudo_cmd} -u "${real_user}" crontab "${tmp_cron}"
        rm -f "${tmp_cron}"
        Show 0 "Cronjob added: runs daily at 02:00."
        Show 2 "Log file: ${log_file}"
    fi
}

###############################################################################
# MAIN                                                                        #
###############################################################################

main() {
    parse_args "$@"

    # Resolve installation directory — custom or default
    if [[ -n "${CUSTOM_DIR}" ]]; then
        DOCKER_APPS_DIR="${CUSTOM_DIR}"
    else
        DOCKER_APPS_DIR="${HOME}/DockerApps"
    fi
    GLPI_DIR="${DOCKER_APPS_DIR}/glpi"
    PATCH_DIR_HOST="${GLPI_DIR}/patches"
    PATCH_LOG="${PATCH_DIR_HOST}/apply-patches.log"

    Show_Banner
    Show 2 "Installation directory: ${DOCKER_APPS_DIR}"
    [[ -n "${SSH_KEY}" ]] && Show 2 "SSH key: ${SSH_KEY}"
    echo ""

    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 1 — System Checks${COLOUR_RESET}"
    echo ""
    Check_Arch
    Check_OS
    Check_Distribution
    Check_Memory
    Check_Disk

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 2 — Dependencies${COLOUR_RESET}"
    echo ""
    Update_Package_Index
    Install_Dependencies

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 3 — Docker${COLOUR_RESET}"
    echo ""
    Check_Docker_Install
    Check_Docker_Compose
    Add_User_To_Docker_Group

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 4 — GLPI Stack${COLOUR_RESET}"
    echo ""
    Check_SSH_Key
    Setup_GLPI_Stack

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 5 — Start GLPI & Create Backup User${COLOUR_RESET}"
    echo ""
    Start_GLPI_Stack
    Wait_For_DB
    Wait_For_GLPI
    Get_MySQL_Root_Password
    Create_Backup_User

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 6 — GLPI Marketplace${COLOUR_RESET}"
    echo ""
    Prompt_Network_Key
    if [[ -n "${GLPI_NETWORK_KEY}" ]]; then
        Set_Network_Key
    fi

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 7 — Plugin Installation${COLOUR_RESET}"
    echo ""
    Install_Plugins

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 8 — Apply Patches${COLOUR_RESET}"
    echo ""
    Apply_Patches

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 9 — Aliases & Dropbox Sync${COLOUR_RESET}"
    echo ""
    Setup_Aliases
    local sync_ok=0
    Sync_From_Dropbox || sync_ok=$?

    if [[ $sync_ok -eq 0 ]]; then
        echo ""
        echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 10 — Restore Latest Backup${COLOUR_RESET}"
        echo ""
        Restore_Latest_Backup
    else
        Show 3 "Skipping restore step due to Dropbox sync errors."
    fi

    # Create catalog user here — by this point GLPI has initialized its
    # schema (either via first request or restored backup), so tables exist
    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 10b — Create Catalog User${COLOUR_RESET}"
    echo ""
    Create_Catalog_User

    echo ""
    echo -e "${GREEN_BULLET} ${aCOLOUR[1]}Step 11 — Backup Cronjob${COLOUR_RESET}"
    echo ""
    Setup_Cronjob

    echo ""
    echo -e "${GREEN_LINE}"
    Show 0 "Installation complete!"
    Show 0 "All required plugins are active."
    Show 0 "Patches applied. See log: ${PATCH_LOG}"
    Show 2 "Run 'source ~/.bash_aliases' to activate GLPI aliases in this session."
    echo -e "${GREEN_LINE}"
    echo ""
}

main "$@"

#!/bin/bash
set -euo pipefail

# ===== Global Logging Setup =====
LOG_FILE="/var/log/rcs-bootstrap.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local LEVEL="$1"
    shift
    local MSG="[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $*"
    echo -e "$MSG" | tee -a "$LOG_FILE"
}

info()  { log "ℹ️ INFO" "$*"; }
warn()  { log "⚠️ WARN" "$*"; }
error() { log "❌ ERROR" "$*"; }

trap 'error "An unexpected error occurred on line $LINENO. Exiting."; exit 1' ERR

# ===== Install AWS CLI v2 =====
install_aws_cli() {
    if command -v aws >/dev/null 2>&1; then
        info "✅ AWS CLI already installed at $(command -v aws)"
        return 0
    fi

    info "📦 Installing AWS CLI v2..."

    local ZIP_PATH="/tmp/awscliv2.zip"
    local TMP_DIR="/tmp/aws"

    # Ensure old artifacts are gone before starting
    if [[ -f "$ZIP_PATH" || -d "$TMP_DIR" ]]; then
        info "🧹 Cleaning up old AWS CLI installer artifacts..."
        rm -rf "$ZIP_PATH" "$TMP_DIR"
    fi

    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$ZIP_PATH"
    unzip -q "$ZIP_PATH" -d /tmp

    # Cleanup on exit no matter what
    trap 'info "🧹 Removing temporary AWS CLI installer files..."; rm -rf "$ZIP_PATH" "$TMP_DIR"' RETURN

    sudo "$TMP_DIR/install" --update

    # Final cleanup (also covered by trap)
    rm -rf "$ZIP_PATH" "$TMP_DIR"
    info "🧹 Removed AWS CLI installer files."

    # Ensure root can always find aws
    if [[ ! -f /usr/bin/aws ]]; then
        sudo ln -s /usr/local/bin/aws /usr/bin/aws
        info "🔗 Symlink created: /usr/bin/aws → /usr/local/bin/aws"
    fi

    info "✅ AWS CLI v2 installed at $(command -v aws)"
}

# ===== Run OS Updates =====
run_updates() {
    info "🔧 Installing dnf-plugin-versionlock..."
    sudo dnf install -y dnf-plugin-versionlock

    info "🔒 Locking kernel to prevent updates..."
    sudo dnf versionlock add kernel*

    info "⬆️ Running system updates..."
    sudo dnf update -y

    info "📦 Installing additional utilities (bzip2, wget, epel-release, efs-utils, unzip)..."
    sudo dnf install -y bzip2 wget epel-release efs-utils unzip btop
    info "✅ System updates and package installation complete."
}

# ===== EFS Configuration =====
configure_efs_mount() {
    local EFS_ID="fs-0f8857f1863053bdb"
    local MOUNT_DIR="/opt/Thinkbox/DeadlineRepository10"
    local FSTAB_LINE="${EFS_ID}:/ ${MOUNT_DIR} efs _netdev,tls 0 0"

    info "📂 Preparing EFS mount directory at $MOUNT_DIR"
    sudo mkdir -p "$MOUNT_DIR"
    sudo chmod 777 "$MOUNT_DIR"

    if ! grep -qF "$FSTAB_LINE" /etc/fstab; then
        echo "$FSTAB_LINE" | sudo tee -a /etc/fstab
        sudo systemctl daemon-reload
        info "📝 Added EFS entry to /etc/fstab"
    else
        info "ℹ️ EFS entry already present in /etc/fstab"
    fi

    info "🔌 Mounting EFS..."
    sudo mount -a || { error "Failed to mount EFS at $MOUNT_DIR"; exit 1; }
    info "✅ EFS mounted successfully at $MOUNT_DIR"
}

# ===== Download & Extract Deadline Linux Installer =====
download_deadline_linux_installer() {
    local PARAM_PATH="/managed-studio/studio-ldn-deadline/deadline10/linux-installer-url"
    local REPO_DIR="/opt/Thinkbox/DeadlineRepository10"
    local INSTALLERS_DIR="${REPO_DIR}/_installers"
    local TMP_DIR="/tmp"

    info "🌐 Fetching Deadline installer URL from SSM..."
    local URL
    URL=$(aws ssm get-parameter --name "$PARAM_PATH" --query "Parameter.Value" --output text)
    local FILENAME
    FILENAME=$(basename "$URL")
    local VERSION
    VERSION=$(echo "$FILENAME" | grep -oP '\d+\.\d+\.\d+\.\d+')
    local VERSION_DIR="${INSTALLERS_DIR}/${VERSION}"

    info "📦 Detected Deadline version: $VERSION"
    info "📂 Target install directory: $VERSION_DIR"

    sudo mkdir -p "$INSTALLERS_DIR"
    sudo chmod 777 "$INSTALLERS_DIR"

    # If installer directory already exists
    if [[ -d "$VERSION_DIR" ]] && [[ -n "$(ls -A "$VERSION_DIR")" ]]; then
        info "✅ Installer for version $VERSION already exists. Skipping download."
    else
        local ARCHIVE_PATH="${TMP_DIR}/${FILENAME}"

        info "⬇️ Downloading installer to $ARCHIVE_PATH"
        curl -L -o "$ARCHIVE_PATH" "$URL"

        # Always clean up archive on exit
        trap 'info "🧹 Removing temporary Deadline installer archive..."; rm -f "$ARCHIVE_PATH"' RETURN

        info "📦 Extracting installer into $VERSION_DIR"
        sudo mkdir -p "$VERSION_DIR"
        case "$FILENAME" in
            *.tar)    sudo tar -xf "$ARCHIVE_PATH" -C "$VERSION_DIR" ;;
            *.tar.gz) sudo tar -xzf "$ARCHIVE_PATH" -C "$VERSION_DIR" ;;
            *.zip)    sudo unzip -q "$ARCHIVE_PATH" -d "$VERSION_DIR" ;;
            *) error "❌ Unknown archive format: $FILENAME"; return 1 ;;
        esac

        rm -f "$ARCHIVE_PATH"
        info "🧹 Removed installer archive $ARCHIVE_PATH"
        info "✅ Installer extracted successfully to $VERSION_DIR"
    fi

    # Locate the .run file
    local run_file
    run_file=$(ls "${VERSION_DIR}"/DeadlineRepository-*linux-x64-installer.run 2>/dev/null | head -n1)

    if [[ -z "$run_file" || ! -f "$run_file" ]]; then
        error "❌ Could not find Deadline Repository .run installer in $VERSION_DIR"
        return 1
    fi

    # Set global variable instead of echo
    DEADLINE_INSTALLER_PATH="$run_file"
    info "📦 Found installer: $DEADLINE_INSTALLER_PATH"
}

# ===== Check if Deadline 10 Repo + DB already installed =====
check_deadline_repository_installed() {
    local repo_dir="/opt/Thinkbox/DeadlineRepository10"
    local db_dir="/opt/Thinkbox/DeadlineDatabase10"
    local repo_ok=1
    local db_ok=1

    # --- Check Repository ---
    if [[ -d "$repo_dir/settings" ]]; then
        log "✅ Deadline Repository detected at $repo_dir"
        repo_ok=0
    elif command -v deadlinecommand >/dev/null 2>&1; then
        log "✅ Deadline command-line tools found, Repository assumed installed."
        repo_ok=0
    else
        log "ℹ️ Deadline Repository not found."
    fi

    # --- Check Database ---
    if [[ -d "$db_dir" ]]; then
        log "✅ Local Deadline Database detected at $db_dir"
        db_ok=0
    else
        log "ℹ️ No local Deadline Database found (expected if using DocumentDB)."
    fi

    # return codes:
    # 0 = repo + db ok (installed locally)
    # 1 = repo only
    # 2 = db only
    # 3 = none installed
    if [[ $repo_ok -eq 0 && $db_ok -eq 0 ]]; then
        return 0
    elif [[ $repo_ok -eq 0 && $db_ok -ne 0 ]]; then
        return 1
    elif [[ $repo_ok -ne 0 && $db_ok -eq 0 ]]; then
        return 2
    else
        return 3
    fi
}

configure_documentdb_cert() {
    local cert_dir="/opt/Thinkbox/DeadlineRepository10/certs"
    local docdb_ca_file="$cert_dir/global-bundle.pem"
    local ssm_param="/managed-studio/studio-ldn-deadline/deadline10/documentdb/global-ca-bundle"

    log "🔍 Checking DocumentDB CA bundle at $docdb_ca_file"

    # If cert already exists, we're done
    if [[ -f "$docdb_ca_file" ]]; then
        log "✅ CA bundle already exists at $docdb_ca_file"
        return 0
    fi

    # Get URL from SSM
    log "📥 Retrieving CA bundle URL from SSM: $ssm_param"
    local url
    url=$(aws ssm get-parameter \
        --name "$ssm_param" \
        --region eu-west-2 \
        --with-decryption \
        --query "Parameter.Value" \
        --output text)

    # Download cert
    log "🌍 Downloading DocumentDB CA bundle from $url"
    mkdir -p "$cert_dir"
    wget -qO "$docdb_ca_file" "$url"

    if [[ -s "$docdb_ca_file" ]]; then
        chmod 644 "$docdb_ca_file"
        log "✅ CA bundle downloaded successfully: $docdb_ca_file"
    else
        log "❌ Failed to download CA bundle from $url"
        return 1
    fi
}

install_deadline_repository() {
    local repo_dir="/opt/Thinkbox/DeadlineRepository10"
    local settings_file="$repo_dir/settings/repository.ini"
    local docdb_ca_file="$repo_dir/certs/global-bundle.pem"

    # Check if repository.ini exists
    if [[ -f "$settings_file" ]]; then
        local installed_version
        installed_version=$(grep -E '^Version=' "$settings_file" | head -n1 | cut -d'=' -f2)

        if [[ -n "$installed_version" ]]; then
            info "✅ Deadline Repository already installed."
            info "   📂 Location: $repo_dir"
            info "   🔢 Version: $installed_version"
        else
            info "✅ Deadline Repository already installed, but version could not be detected."
        fi
        return 0
    fi

    # Use the global installer path set earlier
    if [[ -z "${DEADLINE_INSTALLER_PATH:-}" || ! -f "$DEADLINE_INSTALLER_PATH" ]]; then
        error "Deadline Repository installer not found (DEADLINE_INSTALLER_PATH is empty)"
        return 1
    fi

    local installer_path="$DEADLINE_INSTALLER_PATH"
    local installer_name
    installer_name=$(basename "$installer_path")

    info "ℹ️ Using Deadline installer:"
    info "   📂 Path: $installer_path"
    info "   📦 File: $installer_name"

    info "ℹ️ Fetching DocumentDB connection details from Secrets Manager..."

    # Fetch credentials JSON from Secrets Manager
    local creds
    creds=$(aws secretsmanager get-secret-value \
        --secret-id "/managed-studio/studio-ldn-deadline/deadline10/documentdb/credentials" \
        --region eu-west-2 \
        --query SecretString \
        --output text 2>/dev/null || true)

    if [[ -z "$creds" ]]; then
        error "Could not fetch DocumentDB credentials secret."
        return 1
    fi

    local db_user db_pass
    db_user=$(echo "$creds" | jq -r '.username')
    db_pass=$(echo "$creds" | jq -r '.password')

    if [[ -z "$db_user" || -z "$db_pass" ]]; then
        error "DocumentDB credentials secret is missing username or password."
        return 1
    fi

    # Fetch endpoint from SSM
    local db_host
    db_host=$(aws ssm get-parameter \
        --name "/managed-studio/studio-ldn-deadline/deadline10/documentdb/endpoint" \
        --region eu-west-2 \
        --with-decryption \
        --query "Parameter.Value" \
        --output text 2>/dev/null || true)

    if [[ -z "$db_host" ]]; then
        error "Could not fetch DocumentDB endpoint from SSM."
        return 1
    fi

    info "ℹ️ DocumentDB endpoint: $db_host"
    info "ℹ️ Repository directory: $repo_dir"
    info "ℹ️ DocumentDB CA bundle: $docdb_ca_file"

    info "🚀 Running Deadline Repository installer..."
    sudo "$installer_path" \
        --mode unattended \
        --prefix "$repo_dir" \
        --setpermissions true \
        --dbtype DocumentDB \
        --dbhost "$db_host" \
        --dbport 27017 \
        --dbname deadline10db \
        --dbreplicaset "" \
        --dbauth true \
        --dbuser "$db_user" \
        --dbpassword "$db_pass" \
        --dbssl true \
        --dbcacert "$docdb_ca_file" \
        --backuprepo true \
        --debuglevel 2

    info "✅ Deadline Repository installation completed successfully."
}

# ===== Main Execution =====
info "🚀 Starting RCS server bootstrap process..."
run_updates
install_aws_cli
configure_efs_mount
download_deadline_linux_installer
configure_documentdb_cert
install_deadline_repository
info "🎉 RCS server bootstrap process completed successfully!"

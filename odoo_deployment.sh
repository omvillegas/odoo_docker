#!/usr/bin/env bash
#
# Odoo.sh - Odoo Production Deployment Script
# Deploys Odoo 18 via Docker Compose with an Apache reverse proxy,
# Let's Encrypt SSL, and daily backups.
#
# USAGE:       sudo ./Odoo.sh -d yourdomain.com -e your@email.com
# REQUIRES:    Ubuntu 24.04 LTS, root privileges, and a valid DNS A record.
# WARNING:     This is a destructive script. It will remove existing Docker
#              containers, volumes, and web server configs for the specified domain.
#

set -euo pipefail

############################################################
# Helper Functions
############################################################

usage() {
  echo "Usage: sudo $0 -d yourdomain.com -e your@email.com"
  echo "  -d yourdomain.com      Main domain for Apache and Let’s Encrypt (e.g., mycompany.com)"
  echo "  -e your@email.com      Email for Certbot notifications"
  exit 1
}

gen_password() {
  openssl rand -hex 8
}

ensure_package() {
  local pkg="$1"
  if ! dpkg -s "$pkg" &>/dev/null; then
    echo "     → Installing package: $pkg"
    apt-get install -y "$pkg"
  else
    echo "     → Package $pkg already installed."
  fi
}

install_docker_and_compose() {
  echo "## 4) Installing Docker Engine and Docker Compose…"
  if command -v docker &>/dev/null && command -v docker compose &>/dev/null; then
    echo "     → Docker and Docker Compose are already installed."
    return
  fi

  if ! command -v docker &>/dev/null; then
    echo "     → Purging containerd (to avoid previous conflicts)…"
    apt-get purge -y containerd || true

    echo "     → Adding official Docker CE repository…"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable docker
    systemctl start docker
    echo "     → Docker Engine installed and running."
  fi

  if ! command -v docker compose &>/dev/null; then
    echo "     → Installing Docker Compose plugin…"
    apt-get install -y docker-compose-plugin
    echo "     → Docker Compose plugin installed."
  fi
  echo "     → Docker and Docker Compose are ready."
}

############################################################
# Parameters and Validation
############################################################

echo "## Starting Odoo deployment script with Docker Compose…"
[[ $# -eq 0 ]] && usage

DOMINIO=""
EMAIL=""

while getopts "d:e:" opt; do
  case $opt in
    d) DOMINIO="$OPTARG" ;;
    e) EMAIL="$OPTARG"   ;;
    *) usage ;;
  esac
done

[[ -z $DOMINIO || -z $EMAIL ]] && usage

[[ $DOMINIO =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || {
  echo "ERROR: Invalid domain format: $DOMINIO. E.g.: example.com"; exit 1; }

[[ $EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || {
  echo "ERROR: Invalid email format: $EMAIL. E.g.: mail@example.com"; exit 1; }

echo "  → Domain configured: $DOMINIO"
echo "  → Contact email: $EMAIL"

############################################################
# 1. Host Prerequisites
############################################################
echo "## 1) Verifying root privileges…"
[[ $EUID -eq 0 ]] || { echo "ERROR: This script must be run as root. Use 'sudo ./$0'."; exit 1; }

echo "## 2) Updating package list (apt update)…"
apt-get update -y

echo "## 3) Installing basic packages on the host…"
for p in git apache2 wget curl ufw snapd openssl gpg lsb-release; do
  ensure_package "$p"
done

install_docker_and_compose

echo "## 5) Enabling Apache modules (proxy, ssl, headers, rewrite)…"
a2enmod proxy proxy_http ssl headers rewrite || true

############################################################
# 2. Configure UFW (Firewall)
############################################################
echo "## 6) Configuring UFW (firewall)…"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "  → UFW configured and enabled."

############################################################
# 3. Create Folder Structure and Permissions
############################################################
BASE_DIR=/opt/odoo
ODOO_DATA_DIR=$BASE_DIR/data
ODOO_LOG_DIR=$BASE_DIR/logs
ODOO_ADDONS_DIR=$BASE_DIR/extra-addons
CONFIG_DIR=$BASE_DIR/config
BACKUPS_DIR=$BASE_DIR/backups

echo "## 7) Creating base folders for Odoo and PostgreSQL: $BASE_DIR and subdirectories…"
mkdir -p "$ODOO_DATA_DIR/filestore" "$ODOO_LOG_DIR" "$ODOO_ADDONS_DIR" "$CONFIG_DIR" "$BACKUPS_DIR"

if ! getent group 999 >/dev/null; then
  echo "  → Creating 'odoo' group (GID 999) on the host…"
  groupadd -r -g 999 odoo || true
fi
if ! id -u 999 &>/dev/null; then
  echo "  → Creating 'odoo' user (UID 999) on the host…"
  useradd -r -g 999 -u 999 odoo || true
fi

echo "  → Adjusting permissions for Odoo volumes…"
chown -R 999:999 "$ODOO_DATA_DIR" "$ODOO_LOG_DIR" "$ODOO_ADDONS_DIR" "$CONFIG_DIR"
chmod -R 750 "$ODOO_DATA_DIR" "$ODOO_LOG_DIR" "$ODOO_ADDONS_DIR" "$CONFIG_DIR"
chown -R root:root "$BACKUPS_DIR" && chmod -R 700 "$BACKUPS_DIR"

echo "  → Folder structure created and permissions set."

############################################################
# 4. Generate Passwords
############################################################
echo "## 8) Generating secure random passwords…"
POSTGRES_PASSWORD=$(gen_password)
ODOO_MASTER_PASSWORD=$(gen_password)
echo "  → Password for PostgreSQL (user 'odoo'): [SAVED TO FILE]"
echo "  → Odoo Master Password: [SAVED TO FILE]"

echo "$POSTGRES_PASSWORD" > "$CONFIG_DIR/db_password.txt"
echo "$ODOO_MASTER_PASSWORD" > "$CONFIG_DIR/master_password.txt"
chmod 600 "$CONFIG_DIR/db_password.txt"
chmod 600 "$CONFIG_DIR/master_password.txt"
chown 999:999 "$CONFIG_DIR/db_password.txt" || true
chown 999:999 "$CONFIG_DIR/master_password.txt" || true
echo "  → Passwords securely saved in $CONFIG_DIR."

############################################################
# 5. Generate odoo.conf (for the Odoo container)
############################################################
echo "## 9) Generating odoo.conf configuration file for the Odoo container…"
CPU_CORES=$(nproc)
WORKERS=$(( CPU_CORES * 2 + 1 ))
echo "  → Detected $CPU_CORES cores, configuring $WORKERS workers."

cat > "$CONFIG_DIR/odoo.conf" <<EOF
[options]
; ---- PRODUCTION PARAMETERS ----
workers = $WORKERS
max_cron_threads = 2
limit_time_cpu = 600
limit_time_real = 1200
proxy_mode = True

; Internal port where Odoo listens
xmlrpc_port = 8069
longpolling_port = 8072

; PostgreSQL connection
db_host = db
db_port = 5432
db_user = odoo
db_password = ${POSTGRES_PASSWORD}
admin_passwd = ${ODOO_MASTER_PASSWORD}

; Addons paths
addons_path = /opt/odoo/extra-addons,/opt/odoo/src/addons,/opt/odoo/src/odoo/addons

; Filestore and logs
data_dir = /opt/odoo/data/filestore
logfile = /opt/odoo/logs/odoo-server.log
EOF
chown 999:999 "$CONFIG_DIR/odoo.conf"
chmod 640 "$CONFIG_DIR/odoo.conf"
echo "  → odoo.conf file generated in $CONFIG_DIR."

############################################################
# 6. Generate docker-compose.yml
############################################################
echo "## 10) Generating docker-compose.yml file…"

cat > "$BASE_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  db:
    image: postgres:16-alpine
    hostname: db
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_USER=odoo
    volumes:
      - odoo-db-data:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo -d postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  odoo:
    build:
      context: .
      dockerfile: Dockerfile
    image: odoo-custom-build:18.0
    hostname: odoo
    user: "999"
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:8069:8069"
      - "127.0.0.1:8072:8072"
    volumes:
      - ./config/odoo.conf:/opt/odoo/config/odoo.conf:ro
      - ./data/filestore:/opt/odoo/data/filestore
      - ./logs:/opt/odoo/logs
      - ./extra-addons:/opt/odoo/extra-addons
    environment:
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - ODOO_MASTER_PASSWORD=\${ODOO_MASTER_PASSWORD}
    command: ["python3", "/opt/odoo/src/odoo-bin", "--config=/opt/odoo/config/odoo.conf"]
    restart: unless-stopped

volumes:
  odoo-db-data:
EOF
echo "  → docker-compose.yml file generated in $BASE_DIR."

############################################################
# 7. Generate Dockerfile
############################################################
echo "## 11) Generating Dockerfile for the Odoo container…"
DOCKERFILE_PATH="$BASE_DIR/Dockerfile"
rm -f "$DOCKERFILE_PATH"

cat > "$DOCKERFILE_PATH" <<'EOF'
FROM python:3.11-slim

ARG ODOO_VERSION=18.0

# 1. Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential git wget curl ca-certificates \
        libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
        libssl-dev libffi-dev libpq-dev postgresql-client \
        libjpeg-dev zlib1g-dev \
        wkhtmltopdf && \
    rm -rf /var/lib/apt/lists/*

# 2. Create odoo user and group
RUN groupadd -r -g 999 odoo && useradd -r -g 999 -u 999 odoo

# 3. Clone Odoo into the destination path /opt/odoo/src
RUN git clone --depth 1 --branch ${ODOO_VERSION} https://github.com/odoo/odoo.git /opt/odoo/src

# 4. Install Python dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /opt/odoo/src/requirements.txt

# 5. Create directories for volumes and set permissions
RUN mkdir -p /opt/odoo/config \
             /opt/odoo/data/filestore \
             /opt/odoo/logs \
             /opt/odoo/extra-addons && \
    chown -R odoo:odoo /opt/odoo

# 6. Set the default user
USER odoo
WORKDIR /opt/odoo/src

EXPOSE 8069 8072
CMD ["python3", "/opt/odoo/src/odoo-bin"]
EOF
echo "  → Dockerfile generated in $DOCKERFILE_PATH."

############################################################
# 8. Deploy with Docker Compose
############################################################
echo "## 12) Deploying Odoo and PostgreSQL with Docker Compose…"

export POSTGRES_PASSWORD
export ODOO_MASTER_PASSWORD

cd "$BASE_DIR"
echo "  → Stopping and removing previous Odoo/PostgreSQL containers and volumes…"
docker compose down --volumes --rmi local --remove-orphans || true

echo "  → Starting Docker Compose services. This may take time to build the Odoo image…"
docker compose up -d --build --wait
cd - > /dev/null

echo "  → Verifying the status of Docker Compose containers…"
running_services=$(docker compose ps --services --filter "status=running")
if ! echo "$running_services" | grep -q '^db$' || ! echo "$running_services" | grep -q '^odoo$'; then
  echo "ERROR: Docker Compose services did not start or are not running. Check the logs:"
  docker compose logs
  exit 1
fi
echo "  → Odoo and PostgreSQL containers are running."

############################################################
# 9. Configure Apache HTTP (for Certbot)
############################################################
APACHE_CONF="/etc/apache2/sites-available/$DOMINIO.conf"

echo "## 13) Configuring Apache HTTP VirtualHost for Certbot…"
a2dissite "$DOMINIO.conf" 2>/dev/null || true
rm -f "$APACHE_CONF" 2>/dev/null || true
rm -rf /etc/letsencrypt/live/"$DOMINIO" /etc/letsencrypt/archive/"$DOMINIO" /etc/letsencrypt/renewal/"$DOMINIO".conf 2>/dev/null || true

cat > "$APACHE_CONF" <<EOF
<VirtualHost *:80>
  ServerName $DOMINIO
  ServerAlias www.$DOMINIO
  ProxyPreserveHost On
  ProxyRequests Off
  ProxyPass /longpolling/ http://127.0.0.1:8072/longpolling/ nocanon
  ProxyPassReverse /longpolling/ http://127.0.0.1:8072/longpolling/
  ProxyPass / http://127.0.0.1:8069/
  ProxyPassReverse / http://127.0.0.1:8069/
  ErrorLog \${APACHE_LOG_DIR}/error_odoo_http.log
  CustomLog \${APACHE_LOG_DIR}/access_odoo_http.log combined
</VirtualHost>
EOF

a2ensite "$DOMINIO.conf"
systemctl reload apache2
if ! systemctl is-active --quiet apache2; then
  echo "ERROR: Apache failed to reload with the HTTP VirtualHost. Check 'systemctl status apache2'."
  exit 1
fi
echo "  → Apache configured and running on HTTP."

############################################################
# 10. Certbot (Let’s Encrypt SSL)
############################################################
echo "## 14) Installing and running Certbot for SSL…"
if ! command -v certbot &>/dev/null; then
    snap install core >/dev/null 2>&1 || true
    snap refresh core >/dev/null 2>&1
    snap install --classic certbot >/dev/null 2>&1
    ln -sf /snap/bin/certbot /usr/bin/certbot
fi

echo "  → Requesting SSL certificate for $DOMINIO…"
if ! certbot --apache -d "$DOMINIO" --www -m "$EMAIL" --agree-tos --non-interactive --redirect; then
  echo "ERROR: SSL certificate request with Certbot failed. Check DNS, firewall (ports 80/443 open), and Certbot logs."
  exit 1
fi

systemctl reload apache2
if ! systemctl is-active --quiet apache2; then
  echo "ERROR: Apache failed to reload after Certbot. Check 'systemctl status apache2'."
  exit 1
fi
echo "  → SSL certificate obtained and Apache reconfigured for HTTPS."

############################################################
# 11. Daily Backup Script
############################################################
BACKUP_SCRIPT=/etc/cron.daily/odoo_backup
echo "## 15) Configuring daily backup script…"
cat > "$BACKUP_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Backup script for Docker Compose Odoo/PostgreSQL
# Dumps the Odoo DB and backs up filestore/config

BASE_DIR=/opt/odoo
BACKUP_ROOT_DIR=\$BASE_DIR/backups
TIMESTAMP=\$(date +'%F_%H%M%S')
CURRENT_BACKUP_DIR=\$BACKUP_ROOT_DIR/\$TIMESTAMP

DB_CONTAINER_ID=\$(docker compose -f "\$BASE_DIR/docker-compose.yml" ps -q db)
ODOO_DB_USER=odoo

# Create backup directory
mkdir -p "\$CURRENT_BACKUP_DIR"
chmod 700 "\$CURRENT_BACKUP_DIR"
echo "  [Backup] Backup directory: \$CURRENT_BACKUP_DIR"

# Get the PostgreSQL password
DB_PASSWORD=\$(cat \$BASE_DIR/config/db_password.txt)
export PGPASSWORD="\$DB_PASSWORD"

# 1) Database backup
echo "  [Backup] Dumping databases…"
if docker exec "\$DB_CONTAINER_ID" pg_dumpall -U "\$ODOO_DB_USER" -c | gzip > "\$CURRENT_BACKUP_DIR/database.sql.gz"; then
  echo "  [Backup] Database dump completed."
else
  echo "ERROR: [Backup] Database dump failed."
  rm -rf "\$CURRENT_BACKUP_DIR"; exit 1
fi

# 2) Data directories backup
echo "  [Backup] Compressing filestore, addons, and config…"
tar czf "\$CURRENT_BACKUP_DIR/filestore.tar.gz" -C "\$BASE_DIR/data/filestore" .
tar czf "\$CURRENT_BACKUP_DIR/extra_addons.tar.gz" -C "\$BASE_DIR/extra-addons" .
tar czf "\$CURRENT_BACKUP_DIR/config.tar.gz" -C "\$BASE_DIR/config" .

# Delete old backups (e.g., keep the last 7 days)
echo "  [Backup] Deleting backups older than 7 days…"
find "\$BACKUP_ROOT_DIR" -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
echo "  [Backup] Cleanup of old backups completed."

echo "  [Backup] Daily Odoo backup finished at \$(date)."
EOF
chmod 750 "$BACKUP_SCRIPT"

############################################################
# Completion
############################################################
echo -e "\n############################################################"
echo "Odoo 18 deployment with Docker Compose completed!"
echo "------------------------------------------------------------"
echo "IMPORTANT DETAILS:"
echo "  ✔ Your Odoo instance is accessible at: https://$DOMINIO"
echo "  ✔ Generated passwords (also in $CONFIG_DIR/):"
echo "    - PostgreSQL (user 'odoo'): $POSTGRES_PASSWORD"
echo "    - Odoo Master Password (to create DBs): $ODOO_MASTER_PASSWORD"
echo "  ✔ Containers managed with Docker Compose at: $BASE_DIR/docker-compose.yml"
echo "  ✔ Service logs: cd $BASE_DIR && docker compose logs -f"
echo "  ✔ Restart services: cd $BASE_DIR && docker compose restart"
echo "  ✔ Access Odoo shell: cd $BASE_DIR && docker compose exec odoo bash"
echo "  ✔ Access DB shell: cd $BASE_DIR && docker compose exec db psql -U odoo"
echo "  ✔ Daily backups configured in /etc/cron.daily/odoo_backup"
echo "    - Backups are saved in: $BACKUPS_DIR"
echo "------------------------------------------------------------"
echo "NEXT STEPS:"
echo "  1. Access Odoo through your browser: https://$DOMINIO"
echo "  2. In Odoo, create your first database. Use the generated 'Odoo Master Password'."
echo "  3. To add custom modules, place them in $BASE_DIR/extra-addons/"
echo "     and then update the module list in Odoo (developer mode)."
echo "############################################################"
echo

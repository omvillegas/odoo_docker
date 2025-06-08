# Odoo 18 Production Deployment Script

This shell script automates the deployment of a production-ready Odoo 18 instance on a fresh Ubuntu 24.04 LTS server.

It uses Docker Compose to orchestrate the Odoo and PostgreSQL containers, and configures Apache as a reverse proxy with free, auto-renewing SSL certificates from Let's Encrypt. It also includes a daily backup mechanism.

## Features

-   **Automated Setup**: Deploys the entire stack with a single command.
-   **Containerized**: Odoo 18 and PostgreSQL 16 run in separate, isolated Docker containers.
-   **Production Ready**:
    -   Configures **Apache** as a reverse proxy.
    -   Secures the site with **Let's Encrypt SSL** (HTTPS).
    -   Optimizes Odoo for production with a proper worker configuration.
    -   Sets up and enables the **UFW firewall**.
-   **Daily Backups**: Automatically creates a daily backup of the database and the filestore.
-   **Idempotent**: Safe to re-run in case of interruption.

## Requirements

-   A server running a fresh installation of **Ubuntu 24.04 LTS**.
-   **Root or `sudo`** privileges.
-   A **domain name** with its DNS `A` record pointing to the server's public IP address.
-   Ports `80` (HTTP) and `443` (HTTPS) must be open and accessible from the internet.

## Usage

1.  **Download the Script**

    Clone this repository or simply download the `Odoo.sh` script to your server.
    ```bash
    git clonw https://github.com/omvillegas/odoo_docker.git --branch=18.0
    ```

2.  **Make it Executable**
    ```bash
    chmod +x Odoo.sh
    ```

3.  **Run the Script**

    Execute the script with `sudo`, providing your domain and a contact email for SSL notifications.

    ```bash
    sudo ./Odoo.sh -d domain.com -e email@example.com
    ```
    -   `-d domain.com`: **(Required)** Your public domain name.
    -   `-e email@example.com`: **(Required)** The email address for Let's Encrypt to send expiry notifications.

The script will take several minutes to complete, especially the first time as it needs to download Docker images and build the Odoo container.

## The Deployment Process

The script automates the following steps:
1.  **System Preparation**: Updates package lists and installs dependencies like Apache, Docker, Git, and UFW.
2.  **Firewall Configuration**: Allows SSH, HTTP, and HTTPS traffic.
3.  **Directory Structure**: Creates the necessary folder structure under `/opt/odoo`.
4.  **Password Generation**: Generates secure, random passwords for the database and the Odoo master password.
5.  **Configuration Files**: Creates a custom `Dockerfile`, `docker-compose.yml`, and `odoo.conf` with production settings.
6.  **Docker Deployment**: Builds the custom Odoo image and starts the `odoo` and `db` services using Docker Compose.
7.  **Web Server Configuration**: Sets up Apache as a reverse proxy to forward traffic to the Odoo container.
8.  **SSL Certificate**: Runs Certbot to obtain and install an SSL certificate for your domain.
9.  **Backup Job**: Creates a daily cron job in `/etc/cron.daily/odoo_backup`.

## Post-Installation Management

All project files and data are located in `/opt/odoo`. To manage your Odoo instance, first navigate to this directory:
```bash
cd /opt/odoo
```

#### Start, Stop, and Restart Services
```bash
# Stop all services
docker compose stop

# Start all services
docker compose up -d

# Restart all services 
docker compose restart
```

#### Access Container Shells
```bash
# Access the Odoo container shell
docker compose exec odoo bash

# Access the PostgreSQL container shell
docker compose exec db psql -U odoo
```

## Backups and Restoration

#### Backup Location
Daily backups are automatically stored in timestamped directories inside `/opt/odoo/backups`. Each backup contains:
-   `database.sql.gz`: A full dump of the PostgreSQL database.
-   `filestore.tar.gz`: A compressed archive of the Odoo filestore (attachments, binary files).
-   `config.tar.gz`: A backup of the configuration files.

#### How to Restore from a Backup

> **WARNING**: Always test the restoration process in a staging environment before attempting it on a live production server. This process is destructive and will overwrite existing data.

1.  **Stop the Odoo service** to prevent any new data from being written.
    ```bash
    cd /opt/odoo
    docker compose stop odoo
    ```

2.  **Identify the backup** you want to restore from `/opt/odoo/backups/`. Let's assume the backup directory is `2025-06-08_143000`.

3.  **Restore the Database**. This command will drop the existing databases and restore them from the dump file.
    ```bash
    gunzip < /opt/odoo/backups/2025-06-08_143000/database.sql.gz | docker compose exec -T db psql -U odoo -d postgres
    ```

4.  **Restore the Filestore**. First, remove the old filestore, then extract the backup.
    ```bash
    # IMPORTANT: This command deletes the current filestore
    rm -rf /opt/odoo/data/filestore/*

    # Extract the backup
    tar -xzf /opt/odoo/backups/2025-06-08_143000/filestore.tar.gz -C /opt/odoo/data/filestore
    ```
5.  **Restart the Odoo service**.
    ```bash
    docker compose start odoo
    ```
    Your instance should now be restored to the state of the backup.

## Custom Addons

To add your own custom modules:
1.  Copy your addon directories into `/opt/odoo/extra-addons/` on the host server.
2.  Restart the Odoo container for the changes to be detected:
    ```bash
    cd /opt/odoo
    docker compose restart odoo
    ```
3.  In your Odoo instance, enable Developer Mode.
4.  Navigate to **Apps** -> **Update Apps List** to make your new modules available for installation.

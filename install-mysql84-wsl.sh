#!/usr/bin/env bash
# Install MySQL 8.4 LTS server + client on WSL Ubuntu and prepare a local test copy of dcWebUsers
# for the SSO server tests. Usage:  sudo bash install-mysql84-wsl.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"   # e.g. jammy, noble
echo ">> Ubuntu codename: $CODENAME"

# 1. Official MySQL APT repo, 8.4 LTS track
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 | gpg --dearmor --yes -o /etc/apt/keyrings/mysql.gpg
cat > /etc/apt/sources.list.d/mysql.list <<LIST
deb [signed-by=/etc/apt/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu $CODENAME mysql-8.4-lts
deb [signed-by=/etc/apt/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu $CODENAME mysql-tools
LIST
apt-get update -qq

# 2. Server + client + shell, non-interactive (root uses auth_socket: `sudo mysql`)
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "mysql-community-server mysql-community-server/root-pass password "
debconf-set-selections <<< "mysql-community-server mysql-community-server/re-root-pass password "
apt-get install -y -qq mysql-server mysql-client mysql-shell

# 3. Start it (works with or without systemd in WSL)
if pidof systemd >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
  systemctl enable --now mysql
else
  service mysql start
fi
sleep 3
mysql -e "SELECT VERSION();"

# 4. Local test database + the two SSO accounts (passwords are prompted, not stored here)
read -rsp "Password for local sso_app (runtime, DML only): " APP_PW; echo
read -rsp "Password for local sso_migrator (DDL for migrate): " MIG_PW; echo
mysql <<SQL
CREATE DATABASE IF NOT EXISTS dcWebUsers CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS 'sso_app'@'%'      IDENTIFIED WITH caching_sha2_password BY '${APP_PW}';
CREATE USER IF NOT EXISTS 'sso_migrator'@'%' IDENTIFIED WITH caching_sha2_password BY '${MIG_PW}';
GRANT SELECT, INSERT, UPDATE, DELETE ON dcWebUsers.* TO 'sso_app'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES, DROP ON dcWebUsers.* TO 'sso_migrator'@'%';
FLUSH PRIVILEGES;
SQL

# 5. Listen on all interfaces so Windows-side tools can reach it too (WSL only; not for a public server)
CNF=/etc/mysql/mysql.conf.d/zz-sso-test.cnf
printf '[mysqld]\nbind-address = 0.0.0.0\nrequire_secure_transport = ON\n' > "$CNF"
(systemctl restart mysql 2>/dev/null || service mysql restart)

echo
echo ">> Done. MySQL $(mysql -N -e 'SELECT VERSION()') running on port 3306 (TLS required)."
echo ">> Next: load a copy of production dcWebUsers into it, e.g. from your PC:"
echo "   mysqldump --single-transaction --set-gtid-purged=OFF -h <prod-host> -P 25060 -u <admin> -p dcWebUsers > dcWebUsers.sql"
echo "   sudo mysql dcWebUsers < dcWebUsers.sql"
echo ">> WSL IP for SSO_DBHOST: $(hostname -I | awk '{print $1}')"

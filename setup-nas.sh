#!/bin/bash

set -e

NAS_DIR="/srv/nas/shared"
NAS_USER="nasuser"
NAS_PASS="123456"
NC_DIR="/srv/nextcloud"

echo "=== Update hệ thống ==="
apt update && apt upgrade -y

echo "=== Cài package cơ bản ==="
apt install -y curl wget gnupg ca-certificates lsb-release samba ufw

# ========================
# Cài Docker (chuẩn)
# ========================
echo "=== Cài Docker CE ==="

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update

apt install -y docker-ce docker-ce-cli containerd.io \
docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# ========================
# Fix quyền Docker
# ========================
usermod -aG docker $SUDO_USER

# ========================
# Cài Tailscale
# ========================
echo "=== Cài Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sh

systemctl enable tailscaled
systemctl start tailscaled

tailscale up --ssh

# ========================
# Tạo user NAS
# ========================
echo "=== Tạo user NAS ==="

id "$NAS_USER" &>/dev/null || useradd -m -s /bin/bash "$NAS_USER"

echo "$NAS_USER:$NAS_PASS" | chpasswd

(echo "$NAS_PASS"; echo "$NAS_PASS") | smbpasswd -s -a "$NAS_USER"
smbpasswd -e "$NAS_USER"

# ========================
# Thư mục NAS
# ========================
mkdir -p "$NAS_DIR"
chown -R "$NAS_USER:$NAS_USER" "$NAS_DIR"
chmod -R 775 "$NAS_DIR"

chmod +x /srv
chmod +x /srv/nas

# ========================
# Samba config sạch
# ========================
echo "=== Cấu hình Samba ==="

cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server role = standalone server
   security = user
   map to guest = never
   ntlm auth = yes

[shared]
   path = $NAS_DIR
   browseable = yes
   read only = no
   guest ok = no
   valid users = $NAS_USER
   create mask = 0664
   directory mask = 0775
EOF

systemctl restart smbd
systemctl enable smbd

# ========================
# Nextcloud (Docker)
# ========================
echo "=== Cài Nextcloud ==="

mkdir -p "$NC_DIR"
cd "$NC_DIR"

cat > docker-compose.yml <<EOF
services:
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: always
    ports:
      - "8080:80"
    volumes:
      - ./nextcloud:/var/www/html
      - $NAS_DIR:/var/www/html/data
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=ncuser
      - MYSQL_PASSWORD=ncpass
      - MYSQL_ROOT_PASSWORD=rootpass
    depends_on:
      - db

  db:
    image: mariadb:10.6
    container_name: nextcloud-db
    restart: always
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    volumes:
      - ./db:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=rootpass
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=ncuser
      - MYSQL_PASSWORD=ncpass
EOF

docker compose up -d

# ========================
# Firewall
# ========================
echo "=== Cấu hình firewall ==="

ufw allow 22/tcp
ufw allow 8080/tcp
ufw allow 10000/tcp
ufw allow in on tailscale0
ufw --force enable

# ========================
# Hoàn tất
# ========================
IP=$(tailscale ip -4 | head -n1)

echo "================================="
echo "NAS + Nextcloud setup hoàn tất"
echo ""
echo "Samba:"
echo "  //$IP/shared"
echo "  user: $NAS_USER"
echo "  pass: $NAS_PASS"
echo ""
echo "Nextcloud:"
echo "  http://$IP:8080"
echo ""
echo "Tailscale IP:"
echo "  $IP"
echo "================================="
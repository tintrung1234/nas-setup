#!/bin/bash

set -e

NAS_DIR="/srv/nas/shared"
NAS_USER="nasuser"

echo "=== Update hệ thống ==="
apt update && apt upgrade -y

echo "=== Cài package ==="
apt install -y curl wget gnupg2 software-properties-common samba ufw

# ========================
# Cài Tailscale
# ========================
echo "=== Cài Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sh

systemctl enable tailscaled
systemctl start tailscaled

tailscale up --ssh

# ========================
# Cài Webmin
# ========================
echo "=== Cài Webmin ==="
wget -qO - http://www.webmin.com/jcameron-key.asc | gpg --dearmor -o /usr/share/keyrings/webmin.gpg

echo "deb [signed-by=/usr/share/keyrings/webmin.gpg] http://download.webmin.com/download/repository sarge contrib" \
    | tee /etc/apt/sources.list.d/webmin.list

apt update
apt install -y webmin

# ========================
# Cấu hình Webmin File Manager
# ========================
echo "=== Cấu hình Webmin File Manager ==="

mkdir -p /etc/webmin/filemin

cat <<EOF > /etc/webmin/filemin/config
root=$NAS_DIR
upload=1
download=1
max_upload=10240
EOF

# restart webmin
systemctl restart webmin

# ========================
# Tạo user NAS
# ========================
id "$NAS_USER" &>/dev/null || adduser --disabled-password --gecos "" $NAS_USER

echo "=== Set password Samba ==="
(echo "123456"; echo "123456") | smbpasswd -s -a $NAS_USER

# ========================
# Tạo thư mục NAS
# ========================
mkdir -p $NAS_DIR
chown -R $NAS_USER:$NAS_USER $NAS_DIR
chmod -R 755 $NAS_DIR

# ========================
# Samba
# ========================
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

cat <<EOF >> /etc/samba/smb.conf

[shared]
   path = $NAS_DIR
   browseable = yes
   read only = no
   guest ok = no
   valid users = $NAS_USER
   force user = $NAS_USER
EOF

systemctl restart smbd
systemctl enable smbd

# ========================
# Mount ổ đĩa
# ========================
echo "================================="
echo "Danh sách ổ đĩa:"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
echo "================================="

read -p "Nhập phân vùng (vd: sdb1) hoặc ENTER để bỏ qua: " DISK_NAME

if [ -n "$DISK_NAME" ]; then
    DEVICE="/dev/$DISK_NAME"

    if [ ! -b "$DEVICE" ]; then
        echo "Thiết bị không tồn tại!"
        exit 1
    fi

    UUID=$(blkid -s UUID -o value $DEVICE)

    if [ -z "$UUID" ]; then
        echo "Không có UUID (ổ chưa format)"
        exit 1
    fi

    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID $NAS_DIR ext4 defaults,nofail 0 2" >> /etc/fstab
    fi

    mount -a || true
    echo "Đã mount vào $NAS_DIR"
else
    echo "Bỏ qua mount"
fi

# ========================
# Firewall
# ========================
ufw allow OpenSSH
ufw allow 10000/tcp
ufw allow in on tailscale0
ufw --force enable

# ========================
# Hoàn tất
# ========================
IP=$(tailscale ip -4 | head -n1)

echo "================================="
echo "NAS setup hoàn tất"
echo "User: $NAS_USER"
echo "Pass: 123456"
echo ""
echo "Webmin: https://$IP:10000"
echo "Samba: //$IP/shared"
echo "================================="
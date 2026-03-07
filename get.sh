#!/bin/bash

# Wait for cloud-init to finish if present (common on fresh VPS rebuilds)
if command -v cloud-init >/dev/null 2>&1; then
    echo "Waiting for cloud-init to complete..."
    cloud-init status --wait || true
fi

echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4" > /etc/resolv.conf
chattr +i /etc/resolv.conf

# Import AlmaLinux GPG key
sudo rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux

# Install EPEL repository
echo "Installing EPEL repository..."
sudo yum install epel-release -y


# Install unzip
echo "Installing unzip wget nano..."
sudo yum install unzip wget nano -y

# Install OpenLiteSpeed repository
echo "Installing OpenLiteSpeed repository..."
sudo wget -O - https://repo.litespeed.sh | sudo bash
sudo yum install openlitespeed -y

echo "Installing OpenLiteSpeed and PHP 7.4 with all common extensions..."

# Install OpenLiteSpeed and base PHP
sudo yum install -y openlitespeed lsphp74 lsphp74-common lsphp74-opcache lsphp74-mysqlnd lsphp74-pdo
sudo yum install -y lsphp74-mbstring lsphp74-xml lsphp74-gd lsphp74-curl lsphp74-json lsphp74-zip
sudo yum install -y lsphp74-intl lsphp74-soap lsphp74-xmlrpc lsphp74-bcmath lsphp74-imap
sudo yum install -y lsphp74-pear lsphp74-devel lsphp74-process lsphp74-ldap
sudo yum install -y lsphp74-iconv lsphp74-gettext lsphp74-ftp lsphp74-tidy lsphp74-enchant lsphp74-pspell
sudo yum install -y lsphp74-sqlite3 lsphp74-pgsql lsphp74-snmp lsphp74-sodium lsphp74-gmp lsphp74-ssh2


echo "Creating PHP symlinks..."
mkdir -p /usr/local/lsws/fcgi-bin/
ln -sf /usr/local/lsws/lsphp74/bin/lsphp /usr/local/lsws/fcgi-bin/lsphp74
ln -sf /usr/local/lsws/lsphp74/bin/lsphp /usr/local/lsws/fcgi-bin/lsphp
ln -sf /usr/local/lsws/lsphp74/bin/lsphp /usr/local/lsws/fcgi-bin/lsphp5
chown -h lsadm:lsadm /usr/local/lsws/fcgi-bin/lsphp*
chmod 755 /usr/local/lsws/fcgi-bin/


yum groupinstall "Development Tools" -y
yum install libzip libzip-devel pcre2-devel -y
sudo pkill lsphp

# Hide PHP version from response headers
sed -i 's/^expose_php = On/expose_php = Off/' /usr/local/lsws/lsphp74/etc/php.ini

echo "Configuring file descriptor limits..."
cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
nobody soft nofile 65535
nobody hard nofile 65535
EOF

mkdir -p /etc/systemd/system/lshttpd.service.d/
cat > /etc/systemd/system/lshttpd.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=65535
EOF

echo "fs.file-max = 2097152" >> /etc/sysctl.conf
sysctl -w fs.file-max=2097152

# Network tuning for high-concurrency workloads
cat >> /etc/sysctl.conf << 'SYSEOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
SYSEOF
sysctl -p
systemctl daemon-reload


# Enable and start OpenLiteSpeed
echo "Enabling and starting OpenLiteSpeed..."
sudo systemctl enable lsws
sudo systemctl start lsws

# Get server IP address
SERVER_IP=$(hostname -I | awk '{print $1}')


ssl_dir="/usr/local/lsws/conf/vhosts/Example"
ssl_key="${ssl_dir}/localhost.key"
ssl_cert="${ssl_dir}/localhost.crt"

if [ ! -f "$ssl_key" ] || [ ! -f "$ssl_cert" ]; then
	openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
		-subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=localhost" \
		-keyout "$ssl_key" -out "$ssl_cert" > /dev/null 2>&1
	chown -R lsadm:lsadm /usr/local/lsws/
fi


mkdir -p /usr/local/lsws/Example/html
rm -rf /usr/local/lsws/Example/html/*
chown -R lsadm:lsadm /usr/local/lsws/Example/



# Create OpenLiteSpeed configuration for PHP
OLS_CONF="/usr/local/lsws/conf/httpd_config.conf"

CONTENT="
listener Default {
  address                 *:80
  secure                  0
}

listener SSL {
  address                 *:443
  secure                  1
  keyFile                 $ssl_key
  certFile                $ssl_cert
  certChain               1
}

"

if [ -f "$OLS_CONF" ]; then
  sed -i '/listener Default{/,/}/d' "$OLS_CONF"
  sed -i '/listener Default {/,/}/d' "$OLS_CONF"
  sed -i '/listener SSL {/,/}/d' "$OLS_CONF"
  echo "$CONTENT" >> "$OLS_CONF"
  echo "Listener ports 80 & 443 added to $OLS_CONF"
fi


if ! grep -q "map.*Example" "$OLS_CONF"; then
  sed -i '/listener Default {/,/}/ {
    /}/ i\  map                     Example *
  }' "$OLS_CONF"
  
  sed -i '/listener SSL {/,/}/ {
    /}/ i\  map                     Example *
  }' "$OLS_CONF"
fi


# Remove existing tuning block (OLS ships with defaults that must be replaced)
perl -0777 -pi -e 's/tuning\s*\{[^}]*\}//s' "$OLS_CONF"

# Remove existing global extProcessor lsphp block (OLS ships with bad defaults)
perl -0777 -pi -e 's/extProcessor lsphp\s*\{[^}]*\}//s' "$OLS_CONF"

# Remove existing scriptHandler block (will be replaced)
perl -0777 -pi -e 's/scriptHandler\s*\{[^}]*\}//s' "$OLS_CONF"

# Add optimized tuning block
cat >> "$OLS_CONF" << 'TUNINGEOF'

tuning {
  maxConnections          10000
  maxSSLConnections       10000
  connTimeout             30
  maxKeepAliveReq         10000
  smartKeepAlive          0
  keepAliveTimeout        5
  sndBufSize              0
  rcvBufSize              0
  maxReqURLLen            32768
  maxReqHeaderSize        65536
  maxReqBodySize          2047M
  maxDynRespHeaderSize    32768
  maxDynRespSize          2047M
  enableGzipCompress      1
  enableBrCompress        4
  enableDynGzipCompress   1
  gzipCompressLevel       4
  gzipAutoUpdateStatic    1
  gzipStaticCompressLevel 6
  brStaticCompressLevel   6
  gzipMaxFileSize         10M
  gzipMinFileSize         300
  compressibleTypes       default
  fileETag                28
  eventDispatcher         best
  maxCachedFileSize       4096
  totalInMemCacheSize     20M
  maxMMapFileSize         256K
  totalMMapCacheSize      40M
  useSendfile             1
  SSLCryptoDevice         null
  quicEnable              1
  quicShmDir              /dev/shm
}

extProcessor lsphp {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp.sock
  maxConns                200
  env                     LSAPI_CHILDREN=200
  env                     LSAPI_AVOID_FORK=0
  env                     LSAPI_EXTRA_CHILDREN=50
  env                     LSAPI_MAX_IDLE=30
  env                     LSAPI_MAX_IDLE_CHILDREN=50
  env                     PHP_LSAPI_MAX_REQUESTS=10000
  env                     LSAPI_MAX_PROCESS_TIME=120
  env                     LSAPI_PPID_NO_CHECK=1
  initTimeout             30
  retryTimeout            0
  persistConn             1
  pcKeepAliveTimeout      30
  respBuffer              0
  autoStart               2
  path                    $SERVER_ROOT/lsphp74/bin/lsphp
  backlog                 100
  instances               1
  runOnStartUp            3
  extMaxIdleTime          30
  priority                0
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           500
  procHardLimit           600
}

scriptHandler {
  add lsapi:lsphp php
}
TUNINGEOF


chown -R lsadm:lsadm /usr/local/lsws/

# Hide server signature and X-Turbo-Charged-By headers
sed -i 's/^showVersionNumber                0/showVersionNumber                2/' "$OLS_CONF"

# Enable and start OpenLiteSpeed
echo "restarting OpenLiteSpeed..."
sudo systemctl restart lsws


# Install Certbot and the OpenLiteSpeed plugin for Certbot
echo "Installing Certbot and OpenLiteSpeed plugin..."
sudo yum install certbot python3-certbot-nginx -y

# Wget website create script
wget -O /usr/local/bin/star https://raw.githubusercontent.com/Eric0x2/scripts/main/manage.sh > /dev/null 2>&1
chmod +x /usr/local/bin/star > /dev/null 2>&1


sudo systemctl stop iptables 2>/dev/null;
sudo systemctl disable iptables 2>/dev/null;
sudo yum remove iptables iptables-services -y && echo "iptables completely removed"


# Install File Browser
wget -qO- https://github.com/hostinger/filebrowser/releases/download/v2.54.0-h6/filebrowser-v2.54.0-h6.tar.gz | tar -xzf -
sudo mv filebrowser-v2.54.0-h6 /usr/local/bin/filebrowser
sudo chmod +x /usr/local/bin/filebrowser
sudo chown nobody:nobody /usr/local/bin/filebrowser
sudo mkdir -p /etc/filebrowser /var/lib/filebrowser
filebrowser -d /var/lib/filebrowser/filebrowser.db config init
filebrowser -d /var/lib/filebrowser/filebrowser.db config set -a $SERVER_IP -p 9999
filebrowser -d /var/lib/filebrowser/filebrowser.db config set --trashDir .trash --viewMode list --sorting.by name --root /home --hidden-files .trash
filebrowser -d /var/lib/filebrowser/filebrowser.db config set --disable-exec --branding.disableUsedPercentage --branding.disableExternal --perm.share=false --perm.execute=false
filebrowser -d /var/lib/filebrowser/filebrowser.db users add admin admin123
sudo chown -R nobody:nobody /var/lib/filebrowser


# Configure File Browser service
cat <<EOL > "/etc/systemd/system/filebrowser.service"
[Unit]
Description=File Browser
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/filebrowser -d /var/lib/filebrowser/filebrowser.db
Restart=always
RestartSec=5
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOL

sudo semanage fcontext -a -t bin_t "/usr/local/bin/filebrowser(/.*)?"
sudo restorecon -R /usr/local/bin/filebrowser

sudo yum install policycoreutils-python-utils -y
sudo semanage port -a -t http_port_t -p tcp 9999


sudo systemctl daemon-reload
sudo systemctl enable filebrowser
sudo systemctl start filebrowser

printf "\n\n\033[0;32mInstallation completed. OpenLiteSpeed, PHP 7.3, Python 3, Certbot, and unzip have been installed and configured.\033[0m\n\n\n"
printf "\033[0;32mYour File Manager Link: http://$SERVER_IP:9999\033[0m\n"
printf "\033[0;32mYour File Manager User: admin\033[0m\n"
printf "\033[0;32mYour File Manager Pass: admin\033[0m\n\n\n"

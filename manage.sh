#!/bin/bash

# Configuration
LSDIR='/usr/local/lsws'
WEBCF="${LSDIR}/conf/httpd_config.conf"
VHDIR="${LSDIR}/conf/vhosts"
USER='nobody'
GROUP='nobody'
WWW_PATH='/home'

# Functions for colored output
echoR() {
    echo -e "\e[31m${1}\e[39m"
}
echoG() {
    echo -e "\e[32m${1}\e[39m"
}

# Create folder if it does not exist
create_folder() {
    local folder=$1
    mkdir -p "$folder"
}

# Change owner of the files
change_owner() {
    chown $USER:$GROUP "$1"
}

show_help() {
    echo "Usage: $0 [-create DOMAIN] [-delete DOMAIN] [-createbulk] [-h]"
    echo "-create DOMAIN    Create a new website"
    echo "-delete DOMAIN    Delete the website"
    echo "-createbulk       Create multiple websites"
    echo "-h                Show this help message"
    exit 0
}

create_website() {
    local domain=$1
    local doc_root="${WWW_PATH}/${domain}/public_html"
    local doc_logs="${WWW_PATH}/${domain}/logs"
    local vh_conf_file="${VHDIR}/${domain}/vhconf.conf"
    local ssl_dir="${VHDIR}/${domain}/ssl"
    local ssl_key="${ssl_dir}/${domain}.key"
    local ssl_cert="${ssl_dir}/${domain}.crt"

	create_folder "$doc_root"
	create_folder "$doc_logs"
	create_folder "$ssl_dir"
	create_folder "${doc_root}/.well-known/acme-challenge"

    # Create dummy SSL certificate
    if [ ! -f "$ssl_key" ] || [ ! -f "$ssl_cert" ]; then
        openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
            -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=${domain}" \
            -keyout "$ssl_key" -out "$ssl_cert" > /dev/null 2>&1
        change_owner "$ssl_key"
        change_owner "$ssl_cert"
    fi

    # Create Virtual Host Configuration
    cat <<EOF >> "$WEBCF"

virtualhost ${domain} {
vhRoot                  ${WWW_PATH}/${domain}/
configFile              ${VHDIR}/${domain}/vhconf.conf
allowSymbolLink         1
enableScript            1
restrained              1

vhssl {
	enable              1
	certFile            $ssl_cert
	keyFile             $ssl_key
}
}

EOF

    create_folder "${doc_root}"
    create_folder "${VHDIR}/${domain}"

    # Create index.html if it doesn't exist
    if [ ! -f "${doc_root}/index.html" ]; then
        cat <<EOF > "${doc_root}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to $domain!</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            margin: 0;
            padding: 0;
            background-color: #f4f4f4;
            color: #333;
        }
        h1 {
            margin-top: 50px;
            font-size: 2em;
        }
    </style>
</head>
<body>
    <h1>Success! The $domain is working!</h1>
</body>
</html>
EOF
        change_owner "${doc_root}/index.html"
    fi

    # Create Virtual Host Configuration if it doesn't exist
    if [ ! -f "${vh_conf_file}" ]; then
        cat > "${vh_conf_file}" <<EOF
docRoot                   \$VH_ROOT/public_html
vhDomain                  \$VH_NAME
vhAliases                 www.\$VH_NAME
adminEmails               nobody@gmail.com
enableGzip                1
enableIpGeo               1


errorlog \$VH_ROOT/logs/\$VH_NAME.error_log {
  useServer               0
  logLevel                WARN
  rollingSize             10M
}

accesslog \$VH_ROOT/logs/\$VH_NAME.access_log {
  useServer               0
  logFormat               "%h %l %u %t "%r" %>s %b "%{Referer}i" "%{User-Agent}i""
  logHeaders              5
  rollingSize             10M
  keepDays                10
  compressArchive         1
}

index  {
useServer               0
indexFiles              index.php, index.html
}

scripthandler  {
add                     lsapi:lsphp74 php
}

extprocessor lsphp74 {
type                    lsapi
address                 uds://tmp/lshttpd/${domain}.sock
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
path                    /usr/local/lsws/lsphp74/bin/lsphp
backlog                 100
instances               1
runOnStartUp            3
extMaxIdleTime          30
priority                0
extUser                 nobody
extGroup                nobody
memSoftLimit            2047M
memHardLimit            2047M
procSoftLimit           500
procHardLimit           600
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
  logLevel                0
  htAccess                1     # Add this
}

context / {
  location                \$VH_ROOT/public_html/
  allowBrowse             1
  rewrite  {
    enable                1
    inherit               1     # Inherit parent rules including autoLoadHtaccess
    autoLoadHtaccess      1     # Explicitly enable here too
  }
  addDefaultCharset       off
}

context /.well-known/acme-challenge {
  location                \$VH_ROOT/public_html/.well-known/acme-challenge
  allowBrowse             1
  rewrite  {
    enable                0
  }
  addDefaultCharset       off
}

vhssl  {
  keyFile                 $ssl_key
  certFile                $ssl_cert
  certChain               1
  sslProtocol             24
  enableECDHE             1
  enableDHE               1
  sslSessionCache         1
  sslSessionTickets       1
}
EOF
        chown -R lsadm:lsadm "${VHDIR}/${domain}"
    else
        echoR "Virtual host configuration file already exists, skipping!"
    fi

    if grep -q "map.*$domain" "$WEBCF"; then
        echo "Domain $domain already exists."
    else
        add_domain_mapping() {
            local port="$1"
            local temp_file=$(mktemp)
            local in_block=0

            awk -v port="$port" -v domain="$domain" '
                /address\s*\*:'"$port"'/ { in_block=1 }
                in_block && /^\s*}/ { print "  map " domain " " domain ", *." domain; in_block=0 }
                { print }
            ' "$WEBCF" > "$temp_file"

            mv "$temp_file" "$WEBCF"
        }

        add_domain_mapping 80
        add_domain_mapping 443
    fi

    chown -R $USER:$GROUP "${WWW_PATH}/${domain}/"

    echoG "Website ${domain} created successfully"
}

delete_website() {
    local domain=$1
    # Remove Virtual Host configuration
    rm -rf "${VHDIR}/${domain}"

    # Remove document root and logs
    rm -rf "${WWW_PATH}/${domain}"

    # Remove any domain mapping
    sed -i "/map.*${domain}/d" "$WEBCF"

	sed -i "/virtualhost ${domain} {/,/}/d" "$WEBCF"
	chown -R lsadm:lsadm /usr/local/lsws/
    echoG "Website ${domain} deleted"
}

create_bulk_websites() {
    echo "Enter domain names, one per line (end with an empty line):"

    DOMAIN_LIST=()
    while true; do
        read -r DOMAIN
        if [ -z "$DOMAIN" ]; then
            break
        fi
        DOMAIN_LIST+=("$DOMAIN")
    done

    echo "Domains to be created:"
    for domain in "${DOMAIN_LIST[@]}"; do
        create_website "$domain"
    done

	chown -R lsadm:lsadm /usr/local/lsws/
    sudo systemctl restart lsws > /dev/null 2>&1
    echoG "Bulk website creation completed and LiteSpeed service restarted."
}

# Main script
if [ $# -eq 0 ]; then
    show_help
fi

while [ "$1" != "" ]; do
    case $1 in
        -create )
            shift
            if [ "$1" != "" ]; then
                DOMAIN=$1
                create_website "$DOMAIN"
				chown -R lsadm:lsadm /usr/local/lsws/
				sudo systemctl restart lsws > /dev/null 2>&1
                shift
            else
                echoR "Error: -create requires a DOMAIN argument."
                show_help
            fi
            ;;
        -delete )
            shift
            if [ "$1" != "" ]; then
                DOMAIN=$1
                delete_website "$DOMAIN"
                shift
            else
                echoR "Error: -delete requires a DOMAIN argument."
                show_help
            fi
            ;;
        -createbulk )
            create_bulk_websites
            shift
            ;;
        -h )
            show_help
            ;;
        * )
            echoR "Invalid option: $1"
            show_help
            ;;
    esac
done

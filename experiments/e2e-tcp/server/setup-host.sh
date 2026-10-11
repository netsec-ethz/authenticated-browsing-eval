#!/bin/bash

# Runs on the HTTP server (snorlax): nginx serving a static http_payload_bytes file over IPv6.

set -e
set -x

source /root/code/pos-variables.sh

apt-get update -y
apt-get install -y nginx ethtool ntpsec

INTF=$(pos_get_variable intfs)
SNORLAX_V6=$(pos_get_variable snorlax_v6 --from-global)
WRKOUT_V6=$(pos_get_variable wrkout_v6 --from-global)
WRKOUT_MAC=$(pos_get_variable wrkout_mac --from-global)
HTTP_PATH=$(pos_get_variable http_path --from-global)
PAYLOAD_BYTES=$(pos_get_variable http_payload_bytes --from-global)

ip link set "$INTF" up
# the validator may forward frames with other dst MACs, the kernel would drop them
ip link set "$INTF" promisc on
ip -6 addr replace "${SNORLAX_V6}/64" dev "$INTF" nodad
ip -6 neigh replace "$WRKOUT_V6" lladdr "$WRKOUT_MAC" dev "$INTF" nud permanent

# no GRO/TSO batching skewing the latency tails
ethtool -K "$INTF" tx off rx off tso off gso off gro off >/dev/null 2>&1 || true

# /8k -> 8k
PAYLOAD_NAME="${HTTP_PATH#/}"
mkdir -p /var/www/html
dd if=/dev/urandom of="/var/www/html/${PAYLOAD_NAME}" bs="$PAYLOAD_BYTES" count=1
chmod 644 "/var/www/html/${PAYLOAD_NAME}"

# tuned so nginx is never the bottleneck
NGINX_WORKERS=$(nproc)
cat > /etc/nginx/nginx.conf <<NGINX
worker_processes ${NGINX_WORKERS};
worker_rlimit_nofile 65536;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 16384;
    use epoll;
    multi_accept on;
}

http {
    access_log off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    keepalive_requests 100000;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        root /var/www/html;
        server_name _;
        location / {
            try_files \$uri \$uri/ =404;
        }
    }
}
NGINX

# the stock default site would clash with the server block above
rm -f /etc/nginx/sites-enabled/*

systemctl restart nginx
systemctl enable nginx

echo "server setup successful: $INTF $SNORLAX_V6 -> $PAYLOAD_BYTES B at $HTTP_PATH"

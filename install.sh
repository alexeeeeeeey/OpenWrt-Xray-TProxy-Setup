#!/bin/sh

set -eu

XRAY_VERSION="${XRAY_VERSION:-25.12.8}"
XRAY_ARCH="${XRAY_ARCH:-arm64-v8a}"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
BYPASS_MAC="${2:-${BYPASS_MAC:-}}"

fail() {
  echo "Error: $*" >&2
  exit 1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_string_or_null() {
  if [ -n "$1" ]; then
    printf '"%s"' "$(json_escape "$1")"
  else
    printf 'null'
  fi
}

urldecode() {
  encoded="$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"
  printf '%b' "$encoded"
}

get_query_param() {
  key="$1"
  printf '%s\n' "$QUERY" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n 1
}

if [ "$(id -u)" -ne 0 ]; then
  fail "run this script as root"
fi

VLESS_URL="${1:-}"
if [ -z "$VLESS_URL" ]; then
  printf 'Enter VLESS URL: '
  IFS= read -r VLESS_URL
fi

case "$VLESS_URL" in
  vless://*) ;;
  *) fail "VLESS URL must start with vless://";;
esac

RAW="${VLESS_URL#vless://}"
MAIN="${RAW%%#*}"
case "$MAIN" in
  *@*) ;;
  *) fail "invalid VLESS URL";;
esac

USERINFO="${MAIN%%@*}"
REST="${MAIN#*@}"
HOST_PORT="${REST%%\?*}"
if [ "$HOST_PORT" = "$REST" ]; then
  QUERY=""
else
  QUERY="${REST#*\?}"
fi

HOST="${HOST_PORT%:*}"
PORT="${HOST_PORT##*:}"

[ -n "$USERINFO" ] || fail "missing UUID"
[ -n "$HOST" ] || fail "missing host"
[ "$PORT" != "$HOST_PORT" ] || fail "missing port"
case "$PORT" in
  ''|*[!0-9]*) fail "invalid port" ;;
esac

ENCRYPTION="$(get_query_param encryption)"
[ -n "$ENCRYPTION" ] || ENCRYPTION="none"
FLOW="$(get_query_param flow)"
SECURITY="$(get_query_param security)"
TYPE="$(get_query_param type)"
[ -n "$TYPE" ] || TYPE="tcp"
SNI="$(get_query_param sni)"
[ -n "$SNI" ] || SNI="$HOST"
FP="$(get_query_param fp)"
PBK="$(get_query_param pbk)"
SID="$(get_query_param sid)"
SPX_RAW="$(get_query_param spx)"
[ -n "$SPX_RAW" ] || SPX_RAW="/"
SPX="$(urldecode "$SPX_RAW")"

HOST_ESC="$(json_escape "$HOST")"
UUID_ESC="$(json_escape "$USERINFO")"
ENCRYPTION_ESC="$(json_escape "$ENCRYPTION")"
TYPE_ESC="$(json_escape "$TYPE")"
SNI_ESC="$(json_escape "$SNI")"
SPX_ESC="$(json_escape "$SPX")"
FLOW_JSON="$(json_string_or_null "$FLOW")"
SECURITY_JSON="$(json_string_or_null "$SECURITY")"
FP_JSON="$(json_string_or_null "$FP")"
PBK_JSON="$(json_string_or_null "$PBK")"
SID_JSON="$(json_string_or_null "$SID")"

if [ -n "$BYPASS_MAC" ]; then
  BYPASS_RULE="ether saddr $(json_escape "$BYPASS_MAC") return"
else
  BYPASS_RULE=""
fi

echo "Installing packages"
opkg update
opkg install kmod-nft-tproxy kmod-nf-tproxy unzip curl

echo "Downloading Xray ${XRAY_VERSION}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
curl -fL "$XRAY_URL" -o "$TMP_DIR/xray.zip"
unzip -oq "$TMP_DIR/xray.zip" -d "$TMP_DIR"

mv "$TMP_DIR/xray" /usr/bin/xray
chmod 0755 /usr/bin/xray

cp "$TMP_DIR/geosite.dat" /usr/bin/geosite.dat
chmod 0644 /usr/bin/geosite.dat

cp "$TMP_DIR/geoip.dat" /usr/bin/geoip.dat
chmod 0644 /usr/bin/geoip.dat

echo "Writing Xray config"
mkdir -p /etc/xray /etc/init.d /root
cat > /etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "tag": "socks",
      "port": 10818,
      "listen": "127.0.0.1",
      "protocol": "mixed",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic", "fakedns", "fakedns+others"],
        "routeOnly": false
      },
      "settings": {
        "auth": "noauth",
        "udp": true,
        "allowTransparent": false
      }
    },
    {
      "port": 10808,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${HOST_ESC}",
            "port": ${PORT},
            "users": [
              {
                "id": "${UUID_ESC}",
                "email": "main",
                "security": "auto",
                "encryption": "${ENCRYPTION_ESC}",
                "flow": ${FLOW_JSON}
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "${TYPE_ESC}",
        "security": ${SECURITY_JSON},
        "realitySettings": {
          "serverName": "${SNI_ESC}",
          "fingerprint": ${FP_JSON},
          "show": false,
          "publicKey": ${PBK_JSON},
          "shortId": ${SID_JSON},
          "spiderX": "${SPX_ESC}"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IpIfNonMatch",
    "rules": [
      {
        "inboundTag": ["dnsQuery"],
        "outboundTag": "proxy",
        "type": "field"
      },
      {
        "domain": [
          "domain:restream-media.net",
          ".ru",
          ".xn--p1ai"
        ],
        "outboundTag": "direct",
        "type": "field"
      }
    ]
  }
}
EOF

cat > /etc/xray/nft.rules <<EOF
table inet xray {
  chain prerouting {
    type filter hook prerouting priority -150; policy accept;
    iifname "br-lan" jump xray-chain
  }

  chain xray-chain {
    ip daddr 10.0.0.0/8 return
    ip daddr 100.64.0.0/10 return
    ip daddr 172.16.0.0/12 return
    ip daddr 192.168.0.0/16 return
    ip daddr 169.254.0.0/16 return
    ip daddr 224.0.0.0/4 return
    ip daddr 255.255.255.255 return
    ${BYPASS_RULE}
    meta l4proto tcp tproxy to :10808 meta mark set 1
    meta l4proto udp tproxy to :10808 meta mark set 1
  }
}
EOF

cat > /etc/init.d/xray <<'EOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/xray run -c /etc/xray/config.json
  procd_set_param respawn
  procd_close_instance
}
EOF

cat > /etc/init.d/xray-tproxy <<'EOF'
#!/bin/sh /etc/rc.common

START=95

start() {
  nft -f /etc/xray/nft.rules
  ip rule add fwmark 1 lookup 100 2>/dev/null
  ip route add local default dev lo table 100 2>/dev/null
}

stop() {
  nft delete table inet xray
  ip rule del fwmark 1 lookup 100 2>/dev/null
  ip route del local default dev lo table 100 2>/dev/null
}
EOF

cat > /root/on.sh <<'EOF'
/etc/init.d/xray start
/etc/init.d/xray-tproxy start
EOF

cat > /root/off.sh <<'EOF'
/etc/init.d/xray stop
/etc/init.d/xray-tproxy stop
EOF

chmod +x /etc/init.d/xray /etc/init.d/xray-tproxy /root/off.sh /root/on.sh

echo "Restarting services"
/etc/init.d/xray stop 2>/dev/null || true
/etc/init.d/xray-tproxy stop 2>/dev/null || true
/etc/init.d/xray enable
/etc/init.d/xray start
/etc/init.d/xray-tproxy enable
/etc/init.d/xray-tproxy start

echo "Done"

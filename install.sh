#!/bin/sh

set -eu

XRAY_VERSION="${XRAY_VERSION:-25.12.8}"
XRAY_ARCH="${XRAY_ARCH:-arm64-v8a}"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"

BASE_DIR="/etc/xray-manager"
STATE_FILE="${BASE_DIR}/config"
XRAY_DIR="/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
NFT_RULES="${XRAY_DIR}/nft.rules"
DEFAULT_BYPASS_RULES="domain:restream-media.net,.ru,.xn--p1ai"

fail() {
  echo "Error: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "run this script as root"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

ensure_dirs() {
  mkdir -p "$BASE_DIR" "$XRAY_DIR" /usr/bin /etc/init.d /root
}

write_state_defaults() {
  [ -f "$STATE_FILE" ] && return 0
  cat > "$STATE_FILE" <<EOF
MODE="url"
CURRENT_URL=""
SUBSCRIPTION_URL=""
BYPASS_MACS=""
BYPASS_RULES="${DEFAULT_BYPASS_RULES}"
LAST_SOURCE=""
EOF
}

install_packages() {
  echo "Installing packages"
  opkg update
  opkg install kmod-nft-tproxy kmod-nf-tproxy unzip curl ca-bundle ca-certificates openssl-util coreutils-base64
}

install_xray_core() {
  echo "Downloading Xray ${XRAY_VERSION}"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

  curl -fL "$XRAY_URL" -o "$TMP_DIR/xray.zip"
  unzip -oq "$TMP_DIR/xray.zip" -d "$TMP_DIR"

  mv "$TMP_DIR/xray" /usr/bin/xray
  chmod 0755 /usr/bin/xray

  rm /usr/bin/geosite.dat
  rm /usr/bin/geoip.dat
  touch /usr/bin/geosite.dat
  touch /usr/bin/geoip.dat
}

write_init_scripts() {
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
  nft delete table inet xray 2>/dev/null || true
  ip rule del fwmark 1 lookup 100 2>/dev/null
  ip route del local default dev lo table 100 2>/dev/null
}
EOF
}

write_manager() {
  cat > /usr/bin/xray-manager <<'EOF'
#!/bin/sh
set -eu

BASE_DIR="/etc/xray-manager"
STATE_FILE="${BASE_DIR}/config"
XRAY_DIR="/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
NFT_RULES="${XRAY_DIR}/nft.rules"
DEFAULT_BYPASS_RULES="domain:restream-media.net,.ru,.xn--p1ai"

fail() {
  echo "Error: $*" >&2
  exit 1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_string_or_null() {
  if [ -n "${1:-}" ]; then
    printf '"%s"' "$(json_escape "$1")"
  else
    printf 'null'
  fi
}

url_decode() {
  encoded="$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"
  printf '%b' "$encoded"
}

load_state() {
  [ -f "$STATE_FILE" ] || fail "state file not found: $STATE_FILE"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  [ "${BYPASS_RULES+x}" = "x" ] || BYPASS_RULES="$DEFAULT_BYPASS_RULES"
}

save_state() {
  cat > "$STATE_FILE" <<EOS
MODE="$(printf '%s' "${MODE:-url}" | sed 's/"/\\"/g')"
CURRENT_URL="$(printf '%s' "${CURRENT_URL:-}" | sed 's/"/\\"/g')"
SUBSCRIPTION_URL="$(printf '%s' "${SUBSCRIPTION_URL:-}" | sed 's/"/\\"/g')"
BYPASS_MACS="$(printf '%s' "${BYPASS_MACS:-}" | sed 's/"/\\"/g')"
BYPASS_RULES="$(printf '%s' "${BYPASS_RULES:-}" | sed 's/"/\\"/g')"
LAST_SOURCE="$(printf '%s' "${LAST_SOURCE:-}" | sed 's/"/\\"/g')"
EOS
}

get_query_param() {
  key="$1"
  printf '%s\n' "$QUERY" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n 1
}

extract_first_vless() {
  awk '/^vless:\/\// { print; exit }'
}

decode_subscription_blob() {
  tmp_in="$1"

  if grep -q 'vless://' "$tmp_in"; then
    cat "$tmp_in"
    return 0
  fi

  if command -v base64 >/dev/null 2>&1; then
    if base64 -d "$tmp_in" 2>/dev/null | grep -q 'vless://'; then
      base64 -d "$tmp_in" 2>/dev/null
      return 0
    fi
  fi

  if command -v openssl >/dev/null 2>&1; then
    if openssl base64 -d -A -in "$tmp_in" 2>/dev/null | grep -q 'vless://'; then
      openssl base64 -d -A -in "$tmp_in" 2>/dev/null
      return 0
    fi
  fi

  fail "subscription format not recognized"
}

resolve_subscription_to_url() {
  sub_url="$1"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT INT TERM

  curl -fsSL "$sub_url" -o "$tmp" || fail "failed to download subscription"

  decoded="$(decode_subscription_blob "$tmp" | tr -d '\r')"
  first_url="$(printf '%s\n' "$decoded" | extract_first_vless)"

  [ -n "$first_url" ] || fail "no valid vless:// entries found in subscription"
  printf '%s\n' "$first_url"
}

normalize_mac() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

normalize_bypass_rule() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

validate_mac() {
  mac="$(normalize_mac "$1")"
  printf '%s' "$mac" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || fail "invalid MAC address: $1"
}

validate_bypass_rule() {
  rule="$(normalize_bypass_rule "$1")"
  [ -n "$rule" ] || fail "empty bypass rule"
  case "$rule" in
    *\"*|*\\*|*,*)
      fail "bypass rule must not contain quotes, backslashes or commas"
      ;;
  esac
}

mac_exists() {
  m="$(normalize_mac "$1")"
  [ -n "${BYPASS_MACS:-}" ] || return 1
  printf '%s\n' "$BYPASS_MACS" | tr ',' '\n' | grep -qx "$m"
}

rule_exists() {
  r="$(normalize_bypass_rule "$1")"
  [ -n "${BYPASS_RULES:-}" ] || return 1
  printf '%s\n' "$BYPASS_RULES" | tr ',' '\n' | grep -Fxq "$r"
}

add_mac() {
  load_state
  m="${1:-}"
  [ -n "$m" ] || fail "usage: xray-manager add-bypass-mac aa:bb:cc:dd:ee:ff"
  validate_mac "$m"
  m="$(normalize_mac "$m")"

  if mac_exists "$m"; then
    echo "MAC already exists"
    return 0
  fi

  if [ -n "${BYPASS_MACS:-}" ]; then
    BYPASS_MACS="${BYPASS_MACS},${m}"
  else
    BYPASS_MACS="$m"
  fi

  save_state
  echo "MAC added"
}

del_mac() {
  load_state
  m="${1:-}"
  [ -n "$m" ] || fail "usage: xray-manager del-bypass-mac aa:bb:cc:dd:ee:ff"
  validate_mac "$m"
  m="$(normalize_mac "$m")"

  if [ -z "${BYPASS_MACS:-}" ]; then
    echo "No bypass MACs configured"
    return 0
  fi

  BYPASS_MACS="$(printf '%s\n' "$BYPASS_MACS" | tr ',' '\n' | grep -vx "$m" || true)"
  BYPASS_MACS="$(printf '%s\n' "$BYPASS_MACS" | join_comma_lines)"

  save_state
  echo "MAC removed"
}

list_mac() {
  load_state
  if [ -z "${BYPASS_MACS:-}" ]; then
    echo "No bypass MACs configured"
    return 0
  fi
  printf '%s\n' "$BYPASS_MACS" | tr ',' '\n'
}

join_comma_lines() {
  first=1
  out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$first" -eq 1 ]; then
      out="$line"
      first=0
    else
      out="${out},${line}"
    fi
  done
  printf '%s' "$out"
}

add_rule() {
  load_state
  r="${1:-}"
  [ -n "$r" ] || fail "usage: xray-manager add-bypass-rule <rule>"
  validate_bypass_rule "$r"
  r="$(normalize_bypass_rule "$r")"

  if rule_exists "$r"; then
    echo "Bypass rule already exists"
    return 0
  fi

  if [ -n "${BYPASS_RULES:-}" ]; then
    BYPASS_RULES="${BYPASS_RULES},${r}"
  else
    BYPASS_RULES="$r"
  fi

  save_state
  echo "Bypass rule added"
}

del_rule() {
  load_state
  r="${1:-}"
  [ -n "$r" ] || fail "usage: xray-manager del-bypass-rule <rule>"
  validate_bypass_rule "$r"
  r="$(normalize_bypass_rule "$r")"

  if [ -z "${BYPASS_RULES:-}" ]; then
    echo "No bypass rules configured"
    return 0
  fi

  BYPASS_RULES="$(printf '%s\n' "$BYPASS_RULES" | tr ',' '\n' | grep -Fvx "$r" || true)"
  BYPASS_RULES="$(printf '%s\n' "$BYPASS_RULES" | join_comma_lines)"

  save_state
  echo "Bypass rule removed"
}

list_rules() {
  load_state
  if [ -z "${BYPASS_RULES:-}" ]; then
    echo "No bypass rules configured"
    return 0
  fi
  printf '%s\n' "$BYPASS_RULES" | tr ',' '\n'
}

parse_vless() {
  VLESS_URL="$1"

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
  SPX="$(url_decode "$SPX_RAW")"

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
}

build_nft_bypass_rules() {
  NFT_BYPASS_RULES=""
  if [ -n "${BYPASS_MACS:-}" ]; then
    OLD_IFS="${IFS:- }"
    IFS=','
    for m in $BYPASS_MACS; do
      [ -n "$m" ] || continue
      NFT_BYPASS_RULES="${NFT_BYPASS_RULES}    ether saddr $(json_escape "$m") return
"
    done
    IFS="$OLD_IFS"
  fi
}

build_routing_direct_rule_json() {
  ROUTING_RULES_JSON=""
  ROUTING_DIRECT_RULE_JSON=""
  if [ -n "${BYPASS_RULES:-}" ]; then
    OLD_IFS="${IFS:- }"
    IFS=','
    for rule in $BYPASS_RULES; do
      rule="$(normalize_bypass_rule "$rule")"
      [ -n "$rule" ] || continue
      escaped_rule="$(json_escape "$rule")"
      if [ -n "$ROUTING_RULES_JSON" ]; then
        ROUTING_RULES_JSON="${ROUTING_RULES_JSON},
          \"${escaped_rule}\""
      else
        ROUTING_RULES_JSON="          \"${escaped_rule}\""
      fi
    done
    IFS="$OLD_IFS"

    if [ -n "$ROUTING_RULES_JSON" ]; then
      ROUTING_DIRECT_RULE_JSON="      {
        \"domain\": [
${ROUTING_RULES_JSON}
        ],
        \"outboundTag\": \"direct\",
        \"type\": \"field\"
      }"
    fi
  fi
}

write_xray_config() {
  parse_vless "$1"
  build_nft_bypass_rules
  build_routing_direct_rule_json

  cat > "$XRAY_CONFIG" <<EOS
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
${ROUTING_DIRECT_RULE_JSON}
    ]
  }
}
EOS

  cat > "$NFT_RULES" <<EOS
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
${NFT_BYPASS_RULES}    meta l4proto tcp tproxy to :10808 meta mark set 1
    meta l4proto udp tproxy to :10808 meta mark set 1
  }
}
EOS
}

validate_config() {
  /usr/bin/xray run -test -c "$XRAY_CONFIG" >/dev/null 2>&1 || fail "xray config test failed"
}

restart_services() {
  /etc/init.d/xray stop 2>/dev/null || true
  /etc/init.d/xray-tproxy stop 2>/dev/null || true
  /etc/init.d/xray start
  /etc/init.d/xray-tproxy start
}

cmd_set() {
  load_state
  input="${1:-}"
  [ -n "$input" ] || fail "usage: xray-manager set <vless://... | https://...>"

  case "$input" in
    vless://*)
      MODE="url"
      CURRENT_URL="$input"
      LAST_SOURCE="manual-url"
      echo "Mode set to URL"
      ;;
    http://*|https://*)
      MODE="subscription"
      SUBSCRIPTION_URL="$input"
      LAST_SOURCE="subscription"
      echo "Mode set to subscription"
      ;;
    *)
      fail "unknown input type"
      ;;
  esac

  save_state
}

cmd_apply() {
  load_state

  case "${MODE:-url}" in
    url)
      [ -n "${CURRENT_URL:-}" ] || fail "CURRENT_URL is empty"
      write_xray_config "$CURRENT_URL"
      ;;
    subscription)
      [ -n "${SUBSCRIPTION_URL:-}" ] || fail "SUBSCRIPTION_URL is empty"
      CURRENT_URL="$(resolve_subscription_to_url "$SUBSCRIPTION_URL")"
      LAST_SOURCE="subscription-refresh"
      save_state
      write_xray_config "$CURRENT_URL"
      ;;
    *)
      fail "unknown mode: $MODE"
      ;;
  esac

  validate_config
  restart_services
  echo "Config applied"
}

cmd_refresh() {
  load_state
  [ "${MODE:-}" = "subscription" ] || fail "refresh works only in subscription mode"
  [ -n "${SUBSCRIPTION_URL:-}" ] || fail "SUBSCRIPTION_URL is empty"

  CURRENT_URL="$(resolve_subscription_to_url "$SUBSCRIPTION_URL")"
  LAST_SOURCE="manual-refresh"
  save_state
  write_xray_config "$CURRENT_URL"
  validate_config
  restart_services
  echo "Subscription refreshed and applied"
}

cmd_show() {
  load_state
  echo "MODE=${MODE:-}"
  echo "CURRENT_URL=${CURRENT_URL:-}"
  echo "SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-}"
  echo "BYPASS_MACS=${BYPASS_MACS:-}"
  echo "BYPASS_RULES=${BYPASS_RULES:-}"
  echo "LAST_SOURCE=${LAST_SOURCE:-}"
}

cmd_status() {
  /etc/init.d/xray status 2>/dev/null || true
  echo
}

cmd_on() {
  /etc/init.d/xray start
  /etc/init.d/xray-tproxy start
}

cmd_off() {
  /etc/init.d/xray stop
  /etc/init.d/xray-tproxy stop
}

cmd_test() {
  echo "Testing via SOCKS5..."
  curl --socks5 127.0.0.1:10818 -m 10 -fsSL ifconfig.me || fail "test failed"
  echo
}

cmd_menu() {
  while :; do
    echo
    echo "1) Show config source"
    echo "2) Set URL / subscription"
    echo "3) Add bypass MAC"
    echo "4) Remove bypass MAC"
    echo "5) List bypass MAC"
    echo "6) Add bypass rule"
    echo "7) Remove bypass rule"
    echo "8) List bypass rules"
    echo "9) Apply current config"
    echo "10) Refresh subscription"
    echo "11) Test proxy"
    echo "12) Service status"
    echo "13) Start"
    echo "14) Stop"
    echo "0) Exit"
    printf "Choose: "
    read -r ans

    case "$ans" in
      1)
        cmd_show
        ;;
      2)
        printf "Enter URL or subscription: "
        read -r v
        cmd_set "$v"
        ;;
      3)
        printf "Enter MAC: "
        read -r m
        add_mac "$m"
        ;;
      4)
        printf "Enter MAC: "
        read -r m
        del_mac "$m"
        ;;
      5)
        list_mac
        ;;
      6)
        printf "Enter bypass rule: "
        read -r r
        add_rule "$r"
        ;;
      7)
        printf "Enter bypass rule: "
        read -r r
        del_rule "$r"
        ;;
      8)
        list_rules
        ;;
      9)
        cmd_apply
        ;;
      10)
        cmd_refresh
        ;;
      11)
        cmd_test
        ;;
      12)
        cmd_status
        ;;
      13)
        cmd_on
        ;;
      14)
        cmd_off
        ;;
      0)
        exit 0
        ;;
      *)
        echo "Unknown choice"
        ;;
    esac
  done
}

cmd="${1:-menu}"
shift || true

case "$cmd" in
  set) cmd_set "${1:-}" ;;
  apply) cmd_apply ;;
  refresh) cmd_refresh ;;
  show) cmd_show ;;
  status) cmd_status ;;
  on) cmd_on ;;
  off) cmd_off ;;
  test) cmd_test ;;
  add-bypass-mac) add_mac "${1:-}" ;;
  del-bypass-mac) del_mac "${1:-}" ;;
  list-bypass-mac) list_mac ;;
  add-bypass-rule) add_rule "${1:-}" ;;
  del-bypass-rule) del_rule "${1:-}" ;;
  list-bypass-rules) list_rules ;;
  menu) cmd_menu ;;
  *) fail "unknown command: $cmd" ;;
esac
EOF

  chmod +x /usr/bin/xray-manager
}

main() {
  need_root
  ensure_dirs
  write_state_defaults
  install_packages
  install_xray_core
  write_init_scripts
  write_manager

  /etc/init.d/xray enable
  /etc/init.d/xray-tproxy enable

  echo
  echo "Installed."
  echo
  echo "Commands:"
  echo "  xray-manager menu"
  echo "  xray-manager set 'vless://...'"
  echo "  xray-manager set 'https://example.com/subscription'"
  echo "  xray-manager apply"
  echo "  xray-manager refresh"
  echo "  xray-manager test"
  echo "  xray-manager add-bypass-mac aa:bb:cc:dd:ee:ff"
  echo "  xray-manager del-bypass-mac aa:bb:cc:dd:ee:ff"
  echo "  xray-manager list-bypass-mac"
  echo "  xray-manager add-bypass-rule 'vk.com'"
  echo "  xray-manager del-bypass-rule 'vk.com'"
  echo "  xray-manager list-bypass-rules"
  echo "  xray-manager show"
}

main "$@"

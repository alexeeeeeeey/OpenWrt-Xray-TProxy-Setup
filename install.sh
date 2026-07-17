#!/bin/sh

set -eu

XRAY_VERSION="${XRAY_VERSION:-25.12.8}"
XRAY_ARCH="${XRAY_ARCH:-}"
XRAY_URL=""

BASE_DIR="/etc/xray-manager"
STATE_FILE="${BASE_DIR}/config"
XRAY_DIR="/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
NFT_RULES="${XRAY_DIR}/nft.rules"

DEFAULT_BYPASS_RULES="domain:restream-media.net,.ru,.xn--p1ai"
DEFAULT_LAN_IFACE="br-lan"
DEFAULT_TPROXY_PORT="10808"
DEFAULT_TPROXY_MARK="1"
DEFAULT_TPROXY_TABLE="100"
DEFAULT_LOCAL_SOCKS_LISTEN="127.0.0.1"
DEFAULT_LOCAL_SOCKS_PORT="10818"

fail() {
  echo "Error: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "run this script as root"
}

state_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

ensure_dirs() {
  mkdir -p "$BASE_DIR" "$XRAY_DIR" /usr/bin /etc/init.d /root
}

append_state_key() {
  key="$1"
  value="$2"
  grep -q "^${key}=" "$STATE_FILE" 2>/dev/null && return 0
  printf '%s="%s"\n' "$key" "$(state_escape "$value")" >> "$STATE_FILE"
}

write_state_defaults() {
  if [ ! -f "$STATE_FILE" ]; then
    umask 077
    cat > "$STATE_FILE" <<EOF
MODE="url"
CURRENT_URL=""
SUBSCRIPTION_URL=""
SUBSCRIPTION_PICK="1"
BYPASS_MACS=""
BYPASS_RULES="${DEFAULT_BYPASS_RULES}"
LAN_IFACE="${DEFAULT_LAN_IFACE}"
TPROXY_PORT="${DEFAULT_TPROXY_PORT}"
TPROXY_MARK="${DEFAULT_TPROXY_MARK}"
TPROXY_TABLE="${DEFAULT_TPROXY_TABLE}"
LOCAL_SOCKS_LISTEN="${DEFAULT_LOCAL_SOCKS_LISTEN}"
LOCAL_SOCKS_PORT="${DEFAULT_LOCAL_SOCKS_PORT}"
LAST_SOURCE=""
EOF
    chmod 0600 "$STATE_FILE"
    return 0
  fi

  append_state_key MODE "url"
  append_state_key CURRENT_URL ""
  append_state_key SUBSCRIPTION_URL ""
  append_state_key SUBSCRIPTION_PICK "1"
  append_state_key BYPASS_MACS ""
  append_state_key BYPASS_RULES "$DEFAULT_BYPASS_RULES"
  append_state_key LAN_IFACE "$DEFAULT_LAN_IFACE"
  append_state_key TPROXY_PORT "$DEFAULT_TPROXY_PORT"
  append_state_key TPROXY_MARK "$DEFAULT_TPROXY_MARK"
  append_state_key TPROXY_TABLE "$DEFAULT_TPROXY_TABLE"
  append_state_key LOCAL_SOCKS_LISTEN "$DEFAULT_LOCAL_SOCKS_LISTEN"
  append_state_key LOCAL_SOCKS_PORT "$DEFAULT_LOCAL_SOCKS_PORT"
  append_state_key LAST_SOURCE ""
  chmod 0600 "$STATE_FILE"
}

install_packages() {
  echo "Installing packages"
  opkg update
  opkg install kmod-nft-tproxy kmod-nf-tproxy unzip uclient-fetch ca-bundle ca-certificates openssl-util coreutils-base64
}

download_file() {
  url="$1"
  out="$2"

  if command -v uclient-fetch >/dev/null 2>&1; then
    if uclient-fetch -q -O "$out" "$url"; then
      return 0
    fi
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget -q -O "$out" "$url"; then
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
    if curl -fsSL --show-error --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 120 "$url" -o "$out"; then
      return 0
    fi
  fi

  fail "failed to download: $url"
}

detect_xray_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "64" ;;
    i386|i686) echo "32" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    armv7*|armv7l) echo "arm32-v7a" ;;
    armv6*) echo "arm32-v6" ;;
    mips64el) echo "mips64le" ;;
    mips64) echo "mips64" ;;
    mipsel) echo "mips32le" ;;
    mips) echo "mips32" ;;
    *) fail "unsupported architecture: $(uname -m). Set XRAY_ARCH manually." ;;
  esac
}

set_xray_url() {
  [ -n "$XRAY_ARCH" ] || XRAY_ARCH="$(detect_xray_arch)"
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
}

install_xray_core() {
  set_xray_url
  echo "Downloading Xray ${XRAY_VERSION} (${XRAY_ARCH})"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

  download_file "$XRAY_URL" "$TMP_DIR/xray.zip"
  unzip -oq "$TMP_DIR/xray.zip" -d "$TMP_DIR"
  [ -f "$TMP_DIR/xray" ] || fail "xray binary was not found in downloaded archive"

  mv -f "$TMP_DIR/xray" /usr/bin/xray
  chmod 0755 /usr/bin/xray

  rm -f /usr/bin/geosite.dat /usr/bin/geoip.dat
  : > /usr/bin/geosite.dat
  : > /usr/bin/geoip.dat

  rm -rf "$TMP_DIR"
  trap - EXIT INT TERM
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

CONFIG="/etc/xray-manager/config"
NFT_RULES="/etc/xray/nft.rules"

load_table_settings() {
  TPROXY_MARK="1"
  TPROXY_TABLE="100"
  [ -f "$CONFIG" ] && . "$CONFIG"
}

start() {
  load_table_settings
  nft -f "$NFT_RULES"
  while ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null; do :; done
  ip rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE"
  ip route replace local default dev lo table "$TPROXY_TABLE"
}

stop() {
  load_table_settings
  nft delete table inet xray 2>/dev/null || true
  while ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null; do :; done
  ip route del local default dev lo table "$TPROXY_TABLE" 2>/dev/null
}
EOF

  chmod 0755 /etc/init.d/xray /etc/init.d/xray-tproxy
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
DEFAULT_LAN_IFACE="br-lan"
DEFAULT_TPROXY_PORT="10808"
DEFAULT_TPROXY_MARK="1"
DEFAULT_TPROXY_TABLE="100"
DEFAULT_LOCAL_SOCKS_LISTEN="127.0.0.1"
DEFAULT_LOCAL_SOCKS_PORT="10818"

fail() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

state_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

url_decode() {
  encoded="$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"
  printf '%b' "$encoded"
}

is_number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_port() {
  port="${1:-}"
  is_number "$port" || fail "invalid port: $port"
  [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || fail "invalid port: $port"
}

validate_small_number() {
  value="${1:-}"
  name="$2"
  is_number "$value" || fail "invalid ${name}: $value"
  [ "$value" -ge 1 ] 2>/dev/null || fail "invalid ${name}: $value"
}

validate_iface() {
  iface="${1:-}"
  [ -n "$iface" ] || fail "interface name is empty"
  printf '%s' "$iface" | grep -Eq '^[A-Za-z0-9_.:-]+$' || fail "invalid interface name: $iface"
}

json_string_or_empty() {
  printf '"%s"' "$(json_escape "${1:-}")"
}

download_file() {
  url="$1"
  out="$2"

  if command -v uclient-fetch >/dev/null 2>&1; then
    if uclient-fetch -q -O "$out" "$url"; then
      return 0
    fi
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget -q -O "$out" "$url"; then
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
    if curl -fsSL --show-error --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 120 "$url" -o "$out"; then
      return 0
    fi
  fi

  fail "failed to download: $url"
}

load_state() {
  [ -f "$STATE_FILE" ] || fail "state file not found: $STATE_FILE"
  # shellcheck disable=SC1090
  . "$STATE_FILE"

  : "${MODE:=url}"
  : "${CURRENT_URL:=}"
  : "${SUBSCRIPTION_URL:=}"
  : "${SUBSCRIPTION_PICK:=1}"
  : "${BYPASS_MACS:=}"
  : "${BYPASS_RULES:=$DEFAULT_BYPASS_RULES}"
  : "${LAN_IFACE:=$DEFAULT_LAN_IFACE}"
  : "${TPROXY_PORT:=$DEFAULT_TPROXY_PORT}"
  : "${TPROXY_MARK:=$DEFAULT_TPROXY_MARK}"
  : "${TPROXY_TABLE:=$DEFAULT_TPROXY_TABLE}"
  : "${LOCAL_SOCKS_LISTEN:=$DEFAULT_LOCAL_SOCKS_LISTEN}"
  : "${LOCAL_SOCKS_PORT:=$DEFAULT_LOCAL_SOCKS_PORT}"
  : "${LAST_SOURCE:=}"
}

save_state() {
  mkdir -p "$BASE_DIR"
  umask 077
  cat > "$STATE_FILE" <<EOS
MODE="$(state_escape "${MODE:-url}")"
CURRENT_URL="$(state_escape "${CURRENT_URL:-}")"
SUBSCRIPTION_URL="$(state_escape "${SUBSCRIPTION_URL:-}")"
SUBSCRIPTION_PICK="$(state_escape "${SUBSCRIPTION_PICK:-1}")"
BYPASS_MACS="$(state_escape "${BYPASS_MACS:-}")"
BYPASS_RULES="$(state_escape "${BYPASS_RULES:-}")"
LAN_IFACE="$(state_escape "${LAN_IFACE:-$DEFAULT_LAN_IFACE}")"
TPROXY_PORT="$(state_escape "${TPROXY_PORT:-$DEFAULT_TPROXY_PORT}")"
TPROXY_MARK="$(state_escape "${TPROXY_MARK:-$DEFAULT_TPROXY_MARK}")"
TPROXY_TABLE="$(state_escape "${TPROXY_TABLE:-$DEFAULT_TPROXY_TABLE}")"
LOCAL_SOCKS_LISTEN="$(state_escape "${LOCAL_SOCKS_LISTEN:-$DEFAULT_LOCAL_SOCKS_LISTEN}")"
LOCAL_SOCKS_PORT="$(state_escape "${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}")"
LAST_SOURCE="$(state_escape "${LAST_SOURCE:-}")"
EOS
  chmod 0600 "$STATE_FILE"
}

get_query_param() {
  key="$1"
  printf '%s\n' "$QUERY" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n 1
}

get_query_param_decoded() {
  raw="$(get_query_param "$1")"
  [ -n "$raw" ] && url_decode "$raw" || true
}

extract_supported_urls() {
  awk '/^vless:\/\// || /^socks:\/\// || /^socks5:\/\// { print }'
}

decode_subscription_blob() {
  tmp_in="$1"

  if grep -Eq 'vless://|socks://|socks5://' "$tmp_in"; then
    cat "$tmp_in"
    return 0
  fi

  if command -v base64 >/dev/null 2>&1; then
    decoded="$(base64 -d "$tmp_in" 2>/dev/null || true)"
    if printf '%s\n' "$decoded" | grep -Eq 'vless://|socks://|socks5://'; then
      printf '%s\n' "$decoded"
      return 0
    fi
  fi

  if command -v openssl >/dev/null 2>&1; then
    decoded="$(openssl base64 -d -A -in "$tmp_in" 2>/dev/null || true)"
    if printf '%s\n' "$decoded" | grep -Eq 'vless://|socks://|socks5://'; then
      printf '%s\n' "$decoded"
      return 0
    fi
  fi

  fail "subscription format not recognized"
}

fetch_subscription_urls_file() {
  sub_url="$1"
  out_file="$2"
  tmp_raw="$(mktemp)"

  if ! download_file "$sub_url" "$tmp_raw"; then
    rm -f "$tmp_raw"
    fail "failed to download subscription"
  fi

  decode_subscription_blob "$tmp_raw" | tr -d '\r' | extract_supported_urls > "$out_file"
  rm -f "$tmp_raw"

  [ -s "$out_file" ] || fail "no supported vless:// or socks:// entries found in subscription"
}

line_count() {
  wc -l < "$1" | tr -d ' '
}

nth_line() {
  n="$(sanitize_pick "$2")"
  awk -v n="$n" 'NR == n { print; exit }' "$1"
}

sanitize_pick() {
  printf '%s\n' "${1:-}" | awk '
    {
      current = ""
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)
        if (char ~ /[0-9]/) {
          current = current char
        } else if (current != "") {
          pick = current
          current = ""
        }
      }
      if (current != "") {
        pick = current
      }
    }
    END {
      printf "%s", pick
    }
  '
}

validate_pick() {
  pick="$(sanitize_pick "${1:-}")"
  count="${2:-0}"
  is_number "$pick" || fail "node selection must be a number"
  [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "$count" ] 2>/dev/null || fail "node #$pick is out of range (1-$count)"
}

url_kind() {
  case "$1" in
    vless://*) echo "vless" ;;
    socks://*|socks5://*) echo "socks" ;;
    *) echo "unknown" ;;
  esac
}

url_host() {
  raw="${1#*://}"
  main="${raw%%#*}"
  main="${main%%\?*}"
  case "$main" in
    *@*) main="${main#*@}" ;;
  esac
  case "$main" in
    \[*\]:*) host="${main%%]*}"; host="${host#[}" ;;
    *:*) host="${main%:*}" ;;
    *) host="$main" ;;
  esac
  printf '%s' "$host"
}

node_label() {
  url="$1"
  case "$url" in
    *#*) label="$(url_decode "${url##*#}")" ;;
    *) label="$(url_host "$url")" ;;
  esac
  [ -n "$label" ] || label="$(url_host "$url")"
  printf '%s' "$label" | cut -c 1-72
}

describe_url() {
  url="${1:-}"
  [ -n "$url" ] || {
    echo "(not set)"
    return 0
  }
  printf '%s %s' "$(url_kind "$url")" "$(url_host "$url")"
  label="$(node_label "$url")"
  [ "$label" = "$(url_host "$url")" ] || printf ' (%s)' "$label"
  echo
}

print_nodes_file() {
  urls_file="$1"
  i=1
  while IFS= read -r url; do
    printf '%2s) %-5s %s\n' "$i" "$(url_kind "$url")" "$(node_label "$url")"
    i=$((i + 1))
  done < "$urls_file"
}

prompt_pick() {
  default_pick="${1:-1}"
  count="$2"
  validate_pick "$default_pick" "$count" 2>/dev/null || default_pick="1"

  if [ -t 0 ]; then
    printf "Choose node [%s]: " "$default_pick" >&2
    read -r pick
    [ -n "$pick" ] || pick="$default_pick"
  else
    pick="$default_pick"
  fi
  pick="$(sanitize_pick "$pick")"

  validate_pick "$pick" "$count"
  printf '%s' "$pick"
}

choose_subscription_url() {
  urls_file="$1"
  pick="$(sanitize_pick "${2:-1}")"
  count="$(line_count "$urls_file")"
  validate_pick "$pick" "$count"
  nth_line "$urls_file" "$pick"
}

resolve_subscription_to_url() {
  sub_url="$1"
  pick="${2:-1}"
  tmp_urls="$(mktemp)"
  fetch_subscription_urls_file "$sub_url" "$tmp_urls"
  selected="$(choose_subscription_url "$tmp_urls" "$pick")"
  rm -f "$tmp_urls"
  printf '%s\n' "$selected"
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
  echo "MAC added. Run: xray-manager apply"
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
  echo "MAC removed. Run: xray-manager apply"
}

list_mac() {
  load_state
  if [ -z "${BYPASS_MACS:-}" ]; then
    echo "No bypass MACs configured"
    return 0
  fi
  printf '%s\n' "$BYPASS_MACS" | tr ',' '\n'
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
  echo "Bypass rule added. Run: xray-manager apply"
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
  echo "Bypass rule removed. Run: xray-manager apply"
}

list_rules() {
  load_state
  if [ -z "${BYPASS_RULES:-}" ]; then
    echo "No bypass rules configured"
    return 0
  fi
  printf '%s\n' "$BYPASS_RULES" | tr ',' '\n'
}

parse_host_port() {
  value="$1"
  default_port="${2:-}"

  case "$value" in
    \[*\]:*)
      PARSED_HOST="${value%%]*}"
      PARSED_HOST="${PARSED_HOST#[}"
      PARSED_PORT="${value##*:}"
      ;;
    *:*)
      PARSED_HOST="${value%:*}"
      PARSED_PORT="${value##*:}"
      ;;
    *)
      PARSED_HOST="$value"
      PARSED_PORT="$default_port"
      ;;
  esac

  [ -n "$PARSED_HOST" ] || fail "missing host"
  [ -n "$PARSED_PORT" ] || fail "missing port"
  validate_port "$PARSED_PORT"
}

parse_vless() {
  VLESS_URL="$1"

  case "$VLESS_URL" in
    vless://*) ;;
    *) fail "VLESS URL must start with vless://" ;;
  esac

  RAW="${VLESS_URL#vless://}"
  MAIN="${RAW%%#*}"

  case "$MAIN" in
    *@*) ;;
    *) fail "invalid VLESS URL" ;;
  esac

  USERINFO="${MAIN%%@*}"
  REST="${MAIN#*@}"
  HOST_PORT="${REST%%\?*}"

  if [ "$HOST_PORT" = "$REST" ]; then
    QUERY=""
  else
    QUERY="${REST#*\?}"
  fi

  parse_host_port "$HOST_PORT" ""
  HOST="$PARSED_HOST"
  PORT="$PARSED_PORT"

  [ -n "$USERINFO" ] || fail "missing UUID"

  ENCRYPTION="$(get_query_param_decoded encryption)"
  [ -n "$ENCRYPTION" ] || ENCRYPTION="none"

  FLOW="$(get_query_param_decoded flow)"
  SECURITY="$(get_query_param_decoded security)"
  [ -n "$SECURITY" ] || SECURITY="none"
  TYPE="$(get_query_param_decoded type)"
  [ -n "$TYPE" ] || TYPE="tcp"

  SNI="$(get_query_param_decoded sni)"
  [ -n "$SNI" ] || SNI="$HOST"

  FP="$(get_query_param_decoded fp)"
  PBK="$(get_query_param_decoded pbk)"
  SID="$(get_query_param_decoded sid)"
  SPX="$(get_query_param_decoded spx)"
  [ -n "$SPX" ] || SPX="/"

  WS_PATH="$(get_query_param_decoded path)"
  [ -n "$WS_PATH" ] || WS_PATH="/"
  WS_HOST="$(get_query_param_decoded host)"
  GRPC_SERVICE_NAME="$(get_query_param_decoded serviceName)"

  case "$SECURITY" in
    reality)
      [ -n "$PBK" ] || fail "REALITY link is missing pbk"
      ;;
    tls|none) ;;
    *)
      warn "unknown VLESS security '$SECURITY'; passing it to Xray as-is"
      ;;
  esac

  HOST_ESC="$(json_escape "$HOST")"
  UUID_ESC="$(json_escape "$USERINFO")"
  ENCRYPTION_ESC="$(json_escape "$ENCRYPTION")"
  TYPE_ESC="$(json_escape "$TYPE")"
  SECURITY_ESC="$(json_escape "$SECURITY")"
  SNI_ESC="$(json_escape "$SNI")"
  FP_ESC="$(json_escape "$FP")"
  PBK_ESC="$(json_escape "$PBK")"
  SID_ESC="$(json_escape "$SID")"
  SPX_ESC="$(json_escape "$SPX")"
  WS_PATH_ESC="$(json_escape "$WS_PATH")"
  WS_HOST_ESC="$(json_escape "$WS_HOST")"
  GRPC_SERVICE_NAME_ESC="$(json_escape "$GRPC_SERVICE_NAME")"

  FLOW_LINE=""
  [ -n "$FLOW" ] && FLOW_LINE=",
                \"flow\": \"$(json_escape "$FLOW")\""
}

build_vless_stream_extra_json() {
  VLESS_STREAM_EXTRA_JSON=""

  case "$SECURITY" in
    reality)
      VLESS_STREAM_EXTRA_JSON="${VLESS_STREAM_EXTRA_JSON},
        \"realitySettings\": {
          \"serverName\": \"${SNI_ESC}\",
          \"fingerprint\": \"${FP_ESC}\",
          \"show\": false,
          \"publicKey\": \"${PBK_ESC}\",
          \"shortId\": \"${SID_ESC}\",
          \"spiderX\": \"${SPX_ESC}\"
        }"
      ;;
    tls)
      VLESS_STREAM_EXTRA_JSON="${VLESS_STREAM_EXTRA_JSON},
        \"tlsSettings\": {
          \"serverName\": \"${SNI_ESC}\",
          \"fingerprint\": \"${FP_ESC}\"
        }"
      ;;
  esac

  case "$TYPE" in
    ws)
      if [ -n "$WS_HOST" ]; then
        WS_HEADERS_JSON=",
          \"headers\": {
            \"Host\": \"${WS_HOST_ESC}\"
          }"
      else
        WS_HEADERS_JSON=""
      fi
      VLESS_STREAM_EXTRA_JSON="${VLESS_STREAM_EXTRA_JSON},
        \"wsSettings\": {
          \"path\": \"${WS_PATH_ESC}\"${WS_HEADERS_JSON}
        }"
      ;;
    grpc)
      VLESS_STREAM_EXTRA_JSON="${VLESS_STREAM_EXTRA_JSON},
        \"grpcSettings\": {
          \"serviceName\": \"${GRPC_SERVICE_NAME_ESC}\"
        }"
      ;;
  esac
}

build_vless_outbound_json() {
  parse_vless "$1"
  build_vless_stream_extra_json

  cat <<EOS
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
                "encryption": "${ENCRYPTION_ESC}"${FLOW_LINE}
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "${TYPE_ESC}",
        "security": "${SECURITY_ESC}"${VLESS_STREAM_EXTRA_JSON}
      }
    }
EOS
}

parse_socks() {
  SOCKS_URL="$1"

  case "$SOCKS_URL" in
    socks://*|socks5://*) ;;
    *) fail "SOCKS URL must start with socks:// or socks5://" ;;
  esac

  RAW="${SOCKS_URL#*://}"
  MAIN="${RAW%%#*}"
  MAIN="${MAIN%%\?*}"

  AUTH=""
  HOST_PORT="$MAIN"
  case "$MAIN" in
    *@*)
      AUTH="${MAIN%%@*}"
      HOST_PORT="${MAIN#*@}"
      ;;
  esac

  parse_host_port "$HOST_PORT" "1080"
  SOCKS_HOST="$PARSED_HOST"
  SOCKS_PORT="$PARSED_PORT"

  SOCKS_USER=""
  SOCKS_PASS=""
  if [ -n "$AUTH" ]; then
    SOCKS_USER="${AUTH%%:*}"
    if [ "$SOCKS_USER" != "$AUTH" ]; then
      SOCKS_PASS="${AUTH#*:}"
    fi
    SOCKS_USER="$(url_decode "$SOCKS_USER")"
    SOCKS_PASS="$(url_decode "$SOCKS_PASS")"
  fi

  SOCKS_HOST_ESC="$(json_escape "$SOCKS_HOST")"
  SOCKS_USER_ESC="$(json_escape "$SOCKS_USER")"
  SOCKS_PASS_ESC="$(json_escape "$SOCKS_PASS")"
}

build_socks_outbound_json() {
  parse_socks "$1"

  if [ -n "$SOCKS_USER" ]; then
    SOCKS_AUTH_JSON=",
        \"user\": \"${SOCKS_USER_ESC}\",
        \"pass\": \"${SOCKS_PASS_ESC}\""
  else
    SOCKS_AUTH_JSON=""
  fi

  cat <<EOS
    {
      "tag": "proxy",
      "protocol": "socks",
      "settings": {
        "address": "${SOCKS_HOST_ESC}",
        "port": ${SOCKS_PORT}${SOCKS_AUTH_JSON}
      }
    }
EOS
}

build_proxy_outbound_json() {
  case "$1" in
    vless://*) build_vless_outbound_json "$1" ;;
    socks://*|socks5://*) build_socks_outbound_json "$1" ;;
    *) fail "unsupported connection URL. Use vless://, socks://, socks5:// or a subscription URL." ;;
  esac
}

build_nft_bypass_rules() {
  NFT_BYPASS_RULES=""
  if [ -n "${BYPASS_MACS:-}" ]; then
    OLD_IFS="${IFS:- }"
    IFS=','
    for m in $BYPASS_MACS; do
      [ -n "$m" ] || continue
      validate_mac "$m"
      NFT_BYPASS_RULES="${NFT_BYPASS_RULES}    ether saddr $(normalize_mac "$m") return
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
      validate_bypass_rule "$rule"
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

validate_runtime_settings() {
  validate_iface "$LAN_IFACE"
  validate_port "$TPROXY_PORT"
  validate_small_number "$TPROXY_MARK" "TPROXY_MARK"
  validate_small_number "$TPROXY_TABLE" "TPROXY_TABLE"
  validate_port "$LOCAL_SOCKS_PORT"
  [ -n "$LOCAL_SOCKS_LISTEN" ] || fail "LOCAL_SOCKS_LISTEN is empty"
}

write_config_files() {
  connection_url="$1"
  out_config="$2"
  out_nft="$3"

  validate_runtime_settings
  PROXY_OUTBOUND_JSON="$(build_proxy_outbound_json "$connection_url")"
  build_nft_bypass_rules
  build_routing_direct_rule_json

  LOCAL_SOCKS_LISTEN_ESC="$(json_escape "$LOCAL_SOCKS_LISTEN")"

  cat > "$out_config" <<EOS
{
  "inbounds": [
    {
      "tag": "local-socks",
      "port": ${LOCAL_SOCKS_PORT},
      "listen": "${LOCAL_SOCKS_LISTEN_ESC}",
      "protocol": "socks",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      },
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    },
    {
      "tag": "tproxy",
      "port": ${TPROXY_PORT},
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
${PROXY_OUTBOUND_JSON},
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

  cat > "$out_nft" <<EOS
table inet xray {
  chain prerouting {
    type filter hook prerouting priority -150; policy accept;
    iifname "${LAN_IFACE}" jump xray-chain
  }

  chain xray-chain {
    ip daddr 10.0.0.0/8 return
    ip daddr 100.64.0.0/10 return
    ip daddr 172.16.0.0/12 return
    ip daddr 192.168.0.0/16 return
    ip daddr 169.254.0.0/16 return
    ip daddr 224.0.0.0/4 return
    ip daddr 255.255.255.255 return
${NFT_BYPASS_RULES}    meta l4proto tcp tproxy to :${TPROXY_PORT} meta mark set ${TPROXY_MARK}
    meta l4proto udp tproxy to :${TPROXY_PORT} meta mark set ${TPROXY_MARK}
  }
}
EOS
}

validate_config_file() {
  config_path="$1"
  if ! /usr/bin/xray run -test -c "$config_path"; then
    echo "Generated config was kept at: $config_path" >&2
    fail "xray config test failed"
  fi
}

validate_nft_file() {
  nft_path="$1"
  if command -v nft >/dev/null 2>&1; then
    nft -c -f "$nft_path" >/dev/null 2>&1 || fail "nft rules test failed"
  fi
}

restart_services() {
  /etc/init.d/xray-tproxy stop 2>/dev/null || true
  /etc/init.d/xray stop 2>/dev/null || true
  /etc/init.d/xray start || fail "failed to start xray"
  /etc/init.d/xray-tproxy start || fail "failed to start xray-tproxy"
}

apply_url() {
  connection_url="$1"
  tmp_base="$(mktemp)"
  tmp_config="${tmp_base}.json"
  tmp_nft="$(mktemp)"
  rm -f "$tmp_base"

  write_config_files "$connection_url" "$tmp_config" "$tmp_nft"
  validate_config_file "$tmp_config"
  validate_nft_file "$tmp_nft"

  cp "$tmp_config" "$XRAY_CONFIG"
  cp "$tmp_nft" "$NFT_RULES"
  chmod 0644 "$XRAY_CONFIG" "$NFT_RULES"
  rm -f "$tmp_config" "$tmp_nft"

  restart_services
}

configure_direct_url() {
  input="$1"
  case "$input" in
    vless://*|socks://*|socks5://*)
      MODE="url"
      CURRENT_URL="$input"
      LAST_SOURCE="$(url_kind "$input")"
      ;;
    *)
      fail "unsupported URL. Use vless://, socks://, socks5:// or a subscription URL."
      ;;
  esac
}

configure_subscription() {
  sub_url="$1"
  tmp_urls="$(mktemp)"
  fetch_subscription_urls_file "$sub_url" "$tmp_urls"
  count="$(line_count "$tmp_urls")"

  echo "Available nodes:"
  print_nodes_file "$tmp_urls"

  pick="$(prompt_pick "${SUBSCRIPTION_PICK:-1}" "$count")"
  selected="$(nth_line "$tmp_urls" "$pick")"
  rm -f "$tmp_urls"

  MODE="subscription"
  SUBSCRIPTION_URL="$sub_url"
  SUBSCRIPTION_PICK="$pick"
  CURRENT_URL="$selected"
  LAST_SOURCE="subscription-import"
  echo "Selected #${SUBSCRIPTION_PICK}: $(describe_url "$CURRENT_URL")"
}

configure_input() {
  load_state
  input="${1:-}"
  [ -n "$input" ] || fail "usage: xray-manager set <vless://... | socks://... | https://...>"

  case "$input" in
    http://*|https://*) configure_subscription "$input" ;;
    *) configure_direct_url "$input" ;;
  esac
}

cmd_set_internal() {
  configure_input "${1:-}"
  save_state
  echo "Saved."
}

cmd_set() {
  cmd_set_internal "${1:-}"
  echo "Run: xray-manager apply"
}

cmd_use() {
  configure_input "${1:-}"
  cmd_apply_loaded
}

cmd_import() {
  cmd_set "$1"
}

configure_socks_args() {
  if [ "${1:-}" = "" ]; then
    input="socks://127.0.0.1:1080"
  elif printf '%s' "$1" | grep -Eq '^socks5?://'; then
    input="$1"
  else
    host="$1"
    port="${2:-1080}"
    validate_port "$port"
    input="socks://${host}:${port}"
  fi

  configure_direct_url "$input"
}

cmd_set_socks() {
  load_state
  configure_socks_args "${1:-}" "${2:-}"
  save_state
  echo "SOCKS upstream saved: $(describe_url "$CURRENT_URL")"
  echo "Run: xray-manager apply"
}

cmd_use_socks() {
  load_state
  configure_socks_args "${1:-}" "${2:-}"
  echo "SOCKS upstream selected: $(describe_url "$CURRENT_URL")"
  cmd_apply_loaded
}

cmd_set_local_socks() {
  load_state
  LOCAL_SOCKS_LISTEN="${1:-$DEFAULT_LOCAL_SOCKS_LISTEN}"
  LOCAL_SOCKS_PORT="${2:-$DEFAULT_LOCAL_SOCKS_PORT}"
  validate_port "$LOCAL_SOCKS_PORT"
  [ -n "$LOCAL_SOCKS_LISTEN" ] || fail "listen address is empty"
  save_state
  echo "Local SOCKS listener saved: ${LOCAL_SOCKS_LISTEN}:${LOCAL_SOCKS_PORT}"
  echo "Run: xray-manager apply"
}

cmd_set_lan_iface() {
  load_state
  LAN_IFACE="${1:-$DEFAULT_LAN_IFACE}"
  validate_iface "$LAN_IFACE"
  save_state
  echo "LAN interface saved: ${LAN_IFACE}"
  echo "Run: xray-manager apply"
}

cmd_list_nodes() {
  load_state
  [ -n "${SUBSCRIPTION_URL:-}" ] || fail "SUBSCRIPTION_URL is empty"
  tmp_urls="$(mktemp)"
  fetch_subscription_urls_file "$SUBSCRIPTION_URL" "$tmp_urls"
  print_nodes_file "$tmp_urls"
  rm -f "$tmp_urls"
}

cmd_select_node() {
  load_state
  [ -n "${SUBSCRIPTION_URL:-}" ] || fail "SUBSCRIPTION_URL is empty"

  tmp_urls="$(mktemp)"
  fetch_subscription_urls_file "$SUBSCRIPTION_URL" "$tmp_urls"
  count="$(line_count "$tmp_urls")"
  print_nodes_file "$tmp_urls"

  if [ -n "${1:-}" ]; then
    pick="$(sanitize_pick "$1")"
    validate_pick "$pick" "$count"
  else
    pick="$(prompt_pick "${SUBSCRIPTION_PICK:-1}" "$count")"
  fi

  MODE="subscription"
  SUBSCRIPTION_PICK="$pick"
  CURRENT_URL="$(nth_line "$tmp_urls" "$pick")"
  LAST_SOURCE="subscription-select"
  rm -f "$tmp_urls"

  save_state
  echo "Selected #${SUBSCRIPTION_PICK}: $(describe_url "$CURRENT_URL")"
  echo "Run: xray-manager apply"
}

cmd_apply_loaded() {
  next_url="${CURRENT_URL:-}"
  next_source="${LAST_SOURCE:-}"

  case "${MODE:-url}" in
    url)
      [ -n "$next_url" ] || fail "CURRENT_URL is empty"
      ;;
    subscription)
      [ -n "${SUBSCRIPTION_URL:-}" ] || fail "SUBSCRIPTION_URL is empty"
      next_url="$(resolve_subscription_to_url "$SUBSCRIPTION_URL" "${SUBSCRIPTION_PICK:-1}")"
      next_source="subscription-refresh"
      ;;
    *)
      fail "unknown mode: $MODE"
      ;;
  esac

  apply_url "$next_url"
  CURRENT_URL="$next_url"
  LAST_SOURCE="$next_source"
  save_state
  echo "Config applied: $(describe_url "$CURRENT_URL")"
}

cmd_apply() {
  load_state
  cmd_apply_loaded
}

cmd_refresh() {
  load_state
  [ "${MODE:-}" = "subscription" ] || fail "refresh works only in subscription mode"
  [ -n "${SUBSCRIPTION_URL:-}" ] || fail "SUBSCRIPTION_URL is empty"

  next_url="$(resolve_subscription_to_url "$SUBSCRIPTION_URL" "${SUBSCRIPTION_PICK:-1}")"
  apply_url "$next_url"
  CURRENT_URL="$next_url"
  LAST_SOURCE="manual-refresh"
  save_state
  echo "Subscription refreshed and applied: $(describe_url "$CURRENT_URL")"
}

cmd_show() {
  load_state
  echo "MODE=${MODE:-}"
  echo "CURRENT=$(describe_url "${CURRENT_URL:-}")"
  echo "SUBSCRIPTION_URL=${SUBSCRIPTION_URL:-}"
  echo "SUBSCRIPTION_PICK=${SUBSCRIPTION_PICK:-1}"
  echo "LOCAL_SOCKS=${LOCAL_SOCKS_LISTEN:-$DEFAULT_LOCAL_SOCKS_LISTEN}:${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}"
  echo "LAN_IFACE=${LAN_IFACE:-$DEFAULT_LAN_IFACE}"
  echo "TPROXY_PORT=${TPROXY_PORT:-$DEFAULT_TPROXY_PORT}"
  echo "BYPASS_MACS=${BYPASS_MACS:-}"
  echo "BYPASS_RULES=${BYPASS_RULES:-}"
  echo "LAST_SOURCE=${LAST_SOURCE:-}"
}

cmd_show_secret() {
  load_state
  cmd_show
  echo "CURRENT_URL=${CURRENT_URL:-}"
}

cmd_status() {
  /etc/init.d/xray status 2>/dev/null || true
  /etc/init.d/xray-tproxy enabled 2>/dev/null || true
  echo
  cmd_show
}

cmd_on() {
  /etc/init.d/xray start
  /etc/init.d/xray-tproxy start
}

cmd_off() {
  /etc/init.d/xray-tproxy stop
  /etc/init.d/xray stop
}

cmd_test() {
  load_state
  test_host="${LOCAL_SOCKS_LISTEN:-$DEFAULT_LOCAL_SOCKS_LISTEN}"
  [ "$test_host" = "0.0.0.0" ] && test_host="127.0.0.1"

  if ! command -v curl >/dev/null 2>&1 || ! curl --version >/dev/null 2>&1; then
    fail "test needs a working curl. Fix libcurl/curl or test from another client via ${test_host}:${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}"
  fi

  echo "Testing via SOCKS5 ${test_host}:${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}..."
  curl --socks5-hostname "${test_host}:${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}" -m 15 -fsSL https://ifconfig.me || fail "test failed"
  echo
}

cmd_doctor() {
  load_state
  echo "Checking manager state..."
  validate_runtime_settings
  [ -x /usr/bin/xray ] || fail "/usr/bin/xray is missing or not executable"
  [ -f "$XRAY_CONFIG" ] || fail "$XRAY_CONFIG is missing"
  [ -f "$NFT_RULES" ] || fail "$NFT_RULES is missing"
  validate_config_file "$XRAY_CONFIG"
  validate_nft_file "$NFT_RULES"
  echo "OK"
}

cmd_menu() {
  while :; do
    echo
    cmd_show
    echo
    echo "1) Use link/subscription now"
    echo "2) Import subscription / choose node"
    echo "3) Choose subscription node"
    echo "4) Use local SOCKS upstream (127.0.0.1:1080)"
    echo "5) Apply current config"
    echo "6) Refresh subscription"
    echo "7) Test proxy"
    echo "8) Bypass MAC"
    echo "9) Bypass domains"
    echo "10) Service status"
    echo "11) Start"
    echo "12) Stop"
    echo "0) Exit"
    printf "Choose: "
    read -r ans

    case "$ans" in
      1)
        printf "Enter vless://, socks:// or subscription URL: "
        read -r v
        cmd_use "$v"
        ;;
      2)
        printf "Enter subscription URL: "
        read -r v
        cmd_import "$v"
        ;;
      3)
        cmd_select_node
        ;;
      4)
        printf "SOCKS host [127.0.0.1]: "
        read -r h
        [ -n "$h" ] || h="127.0.0.1"
        printf "SOCKS port [1080]: "
        read -r p
        [ -n "$p" ] || p="1080"
        cmd_use_socks "$h" "$p"
        ;;
      5)
        cmd_apply
        ;;
      6)
        cmd_refresh
        ;;
      7)
        cmd_test
        ;;
      8)
        echo "a) add  d) delete  l) list"
        read -r b
        case "$b" in
          a) printf "MAC: "; read -r m; add_mac "$m" ;;
          d) printf "MAC: "; read -r m; del_mac "$m" ;;
          l) list_mac ;;
          *) echo "Unknown choice" ;;
        esac
        ;;
      9)
        echo "a) add  d) delete  l) list"
        read -r b
        case "$b" in
          a) printf "Rule: "; read -r r; add_rule "$r" ;;
          d) printf "Rule: "; read -r r; del_rule "$r" ;;
          l) list_rules ;;
          *) echo "Unknown choice" ;;
        esac
        ;;
      10)
        cmd_status
        ;;
      11)
        cmd_on
        ;;
      12)
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

cmd_help() {
  cat <<'EOS'
xray-manager commands:
  menu
  use <vless://... | socks://... | https://subscription>  save and apply
  set <vless://... | socks://... | https://subscription>  save only
  import <https://subscription>                            list nodes and save selection
  list-nodes                                               list subscription nodes
  select-node [number]                                     choose subscription node
  set-socks [host] [port]                                  use SOCKS upstream, defaults 127.0.0.1:1080
  use-socks [host] [port]                                  set SOCKS upstream and apply
  set-local-socks [listen] [port]                          local SOCKS listener, defaults 127.0.0.1:10818
  set-lan-iface [iface]                                    LAN interface, default br-lan
  apply
  refresh
  test
  doctor
  show
  show-secret
  status
  on | off
  add-bypass-mac aa:bb:cc:dd:ee:ff
  del-bypass-mac aa:bb:cc:dd:ee:ff
  list-bypass-mac
  add-bypass-rule <domain-rule>
  del-bypass-rule <domain-rule>
  list-bypass-rules
EOS
}

cmd="${1:-menu}"
shift || true

case "$cmd" in
  use) cmd_use "${1:-}" ;;
  set) cmd_set "${1:-}" ;;
  import) cmd_import "${1:-}" ;;
  list-nodes) cmd_list_nodes ;;
  select-node) cmd_select_node "${1:-}" ;;
  set-socks|set-upstream-socks) cmd_set_socks "${1:-}" "${2:-}" ;;
  use-socks|use-upstream-socks) cmd_use_socks "${1:-}" "${2:-}" ;;
  set-local-socks) cmd_set_local_socks "${1:-}" "${2:-}" ;;
  set-lan-iface) cmd_set_lan_iface "${1:-}" ;;
  apply) cmd_apply ;;
  refresh) cmd_refresh ;;
  show) cmd_show ;;
  show-secret) cmd_show_secret ;;
  status) cmd_status ;;
  on) cmd_on ;;
  off) cmd_off ;;
  test) cmd_test ;;
  doctor) cmd_doctor ;;
  add-bypass-mac) add_mac "${1:-}" ;;
  del-bypass-mac) del_mac "${1:-}" ;;
  list-bypass-mac) list_mac ;;
  add-bypass-rule) add_rule "${1:-}" ;;
  del-bypass-rule) del_rule "${1:-}" ;;
  list-bypass-rules) list_rules ;;
  menu) cmd_menu ;;
  help|-h|--help) cmd_help ;;
  *) fail "unknown command: $cmd. Run: xray-manager help" ;;
esac
EOF

  chmod 0755 /usr/bin/xray-manager
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
  echo "Quick commands:"
  echo "  xray-manager menu"
  echo "  xray-manager use 'vless://...'"
  echo "  xray-manager use 'https://example.com/subscription'"
  echo "  xray-manager use-socks"
  echo "  xray-manager select-node"
  echo "  xray-manager test"
}

main "$@"

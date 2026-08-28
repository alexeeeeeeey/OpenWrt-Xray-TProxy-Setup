#!/bin/sh

set -eu

XRAY_VERSION="${XRAY_VERSION:-26.7.28}"
XRAY_ARCH="${XRAY_ARCH:-}"
XRAY_URL=""

BASE_DIR="/etc/xray-manager"
STATE_FILE="${BASE_DIR}/config"
XRAY_DIR="/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
NFT_RULES="${XRAY_DIR}/nft.rules"
LINKS_FILE="${BASE_DIR}/links"

DEFAULT_BYPASS_RULES="domain:restream-media.net,.ru,.xn--p1ai"
DEFAULT_LAN_IFACE="br-lan"
DEFAULT_TPROXY_PORT="10808"
DEFAULT_TPROXY_MARK="1"
DEFAULT_TPROXY_TABLE="100"
DEFAULT_LOCAL_SOCKS_LISTEN="127.0.0.1"
DEFAULT_LOCAL_SOCKS_PORT="10818"
DEFAULT_DNS_DOH_URL="https://dns.google/dns-query"
DEFAULT_DNS_LISTEN_PORT="5053"
DEFAULT_DNS_FAIL_MODE="strict"

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
BYPASS_MACS_DISABLED=""
BYPASS_RULES="${DEFAULT_BYPASS_RULES}"
BYPASS_RULES_DISABLED=""
LAN_IFACE="${DEFAULT_LAN_IFACE}"
TPROXY_PORT="${DEFAULT_TPROXY_PORT}"
TPROXY_MARK="${DEFAULT_TPROXY_MARK}"
TPROXY_TABLE="${DEFAULT_TPROXY_TABLE}"
LOCAL_SOCKS_LISTEN="${DEFAULT_LOCAL_SOCKS_LISTEN}"
LOCAL_SOCKS_PORT="${DEFAULT_LOCAL_SOCKS_PORT}"
DNS_TUNNEL_ENABLED="1"
DNS_DOH_URL="${DEFAULT_DNS_DOH_URL}"
DNS_LISTEN_PORT="${DEFAULT_DNS_LISTEN_PORT}"
DNS_FAIL_MODE="${DEFAULT_DNS_FAIL_MODE}"
DNS_PROXY_ENABLED="0"
LAST_SOURCE=""
ACTIVE_PROFILE_ID=""
EOF
    chmod 0600 "$STATE_FILE"
    : > "$LINKS_FILE"
    chmod 0600 "$LINKS_FILE"
    return 0
  fi

  append_state_key MODE "url"
  append_state_key CURRENT_URL ""
  append_state_key SUBSCRIPTION_URL ""
  append_state_key SUBSCRIPTION_PICK "1"
  append_state_key BYPASS_MACS ""
  append_state_key BYPASS_MACS_DISABLED ""
  append_state_key BYPASS_RULES "$DEFAULT_BYPASS_RULES"
  append_state_key BYPASS_RULES_DISABLED ""
  append_state_key LAN_IFACE "$DEFAULT_LAN_IFACE"
  append_state_key TPROXY_PORT "$DEFAULT_TPROXY_PORT"
  append_state_key TPROXY_MARK "$DEFAULT_TPROXY_MARK"
  append_state_key TPROXY_TABLE "$DEFAULT_TPROXY_TABLE"
  append_state_key LOCAL_SOCKS_LISTEN "$DEFAULT_LOCAL_SOCKS_LISTEN"
  append_state_key LOCAL_SOCKS_PORT "$DEFAULT_LOCAL_SOCKS_PORT"
  append_state_key DNS_TUNNEL_ENABLED "1"
  append_state_key DNS_DOH_URL "$DEFAULT_DNS_DOH_URL"
  append_state_key DNS_LISTEN_PORT "$DEFAULT_DNS_LISTEN_PORT"
  append_state_key DNS_FAIL_MODE "$DEFAULT_DNS_FAIL_MODE"
  append_state_key DNS_PROXY_ENABLED "0"
  append_state_key LAST_SOURCE ""
  append_state_key ACTIVE_PROFILE_ID ""
  touch "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"
  chmod 0600 "$STATE_FILE"
}

install_packages() {
  echo "Installing packages"
  opkg update
  opkg install kmod-nft-tproxy kmod-nf-tproxy unzip uclient-fetch ca-bundle ca-certificates openssl-util coreutils-base64 uhttpd https-dns-proxy
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
  installed_xray_version=""
  if [ -x /usr/bin/xray ]; then
    installed_xray_version="$(/usr/bin/xray version 2>/dev/null | awk 'NR == 1 { print $2; exit }')"
  fi
  if [ "$installed_xray_version" = "$XRAY_VERSION" ]; then
    echo "Xray ${XRAY_VERSION} is already installed"
    return 0
  fi
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

  cat > /etc/init.d/xray-dns-watchdog <<'EOF'
#!/bin/sh /etc/rc.common

START=100
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/xray-manager dns-watch
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF

  chmod 0755 /etc/init.d/xray /etc/init.d/xray-tproxy /etc/init.d/xray-dns-watchdog
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
LINKS_FILE="${BASE_DIR}/links"

DEFAULT_BYPASS_RULES="domain:restream-media.net,.ru,.xn--p1ai"
DEFAULT_LAN_IFACE="br-lan"
DEFAULT_TPROXY_PORT="10808"
DEFAULT_TPROXY_MARK="1"
DEFAULT_TPROXY_TABLE="100"
DEFAULT_LOCAL_SOCKS_LISTEN="127.0.0.1"
DEFAULT_LOCAL_SOCKS_PORT="10818"
DEFAULT_DNS_DOH_URL="https://dns.google/dns-query"
DEFAULT_DNS_LISTEN_PORT="5053"
DEFAULT_DNS_FAIL_MODE="strict"
DNS_FALLBACK_FLAG="${BASE_DIR}/dns-fallback"
DNS_DEGRADED_FLAG="/tmp/xray-manager-dns-degraded"
DNS_DHCP_BACKUP="${BASE_DIR}/dhcp-before-doh.uci"

fail() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

json_escape() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

state_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

b64_encode() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

b64_decode() {
  printf '%s' "$1" | base64 -d 2>/dev/null
}

url_decode() {
  encoded="$(printf '%s' "$1" | sed 's/%/\\x/g')"
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

validate_single_line() {
  value="$1"
  cleaned="$(printf '%s' "$value" | tr -d '\r\n')"
  [ "$cleaned" = "$value" ] || fail "value must be a single line"
}

validate_doh_url() {
  value="${1:-}"
  validate_single_line "$value"
  case "$value" in
    https://*) ;;
    *) fail "DoH URL must start with https://" ;;
  esac
  printf '%s' "$value" | grep -Eq '^[A-Za-z0-9:/?&=._%+~-]+$' || fail "DoH URL contains unsupported characters"
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
  : "${BYPASS_MACS_DISABLED:=}"
  if [ "${BYPASS_RULES+x}" != "x" ]; then
    BYPASS_RULES="$DEFAULT_BYPASS_RULES"
  fi
  : "${BYPASS_RULES_DISABLED:=}"
  : "${LAN_IFACE:=$DEFAULT_LAN_IFACE}"
  : "${TPROXY_PORT:=$DEFAULT_TPROXY_PORT}"
  : "${TPROXY_MARK:=$DEFAULT_TPROXY_MARK}"
  : "${TPROXY_TABLE:=$DEFAULT_TPROXY_TABLE}"
  : "${LOCAL_SOCKS_LISTEN:=$DEFAULT_LOCAL_SOCKS_LISTEN}"
  : "${LOCAL_SOCKS_PORT:=$DEFAULT_LOCAL_SOCKS_PORT}"
  : "${DNS_TUNNEL_ENABLED:=1}"
  : "${DNS_DOH_URL:=$DEFAULT_DNS_DOH_URL}"
  : "${DNS_LISTEN_PORT:=$DEFAULT_DNS_LISTEN_PORT}"
  : "${DNS_FAIL_MODE:=$DEFAULT_DNS_FAIL_MODE}"
  : "${DNS_PROXY_ENABLED:=0}"
  : "${LAST_SOURCE:=}"
  : "${ACTIVE_PROFILE_ID:=}"
  touch "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"
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
BYPASS_MACS_DISABLED="$(state_escape "${BYPASS_MACS_DISABLED:-}")"
BYPASS_RULES="$(state_escape "${BYPASS_RULES:-}")"
BYPASS_RULES_DISABLED="$(state_escape "${BYPASS_RULES_DISABLED:-}")"
LAN_IFACE="$(state_escape "${LAN_IFACE:-$DEFAULT_LAN_IFACE}")"
TPROXY_PORT="$(state_escape "${TPROXY_PORT:-$DEFAULT_TPROXY_PORT}")"
TPROXY_MARK="$(state_escape "${TPROXY_MARK:-$DEFAULT_TPROXY_MARK}")"
TPROXY_TABLE="$(state_escape "${TPROXY_TABLE:-$DEFAULT_TPROXY_TABLE}")"
LOCAL_SOCKS_LISTEN="$(state_escape "${LOCAL_SOCKS_LISTEN:-$DEFAULT_LOCAL_SOCKS_LISTEN}")"
LOCAL_SOCKS_PORT="$(state_escape "${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}")"
DNS_TUNNEL_ENABLED="$(state_escape "${DNS_TUNNEL_ENABLED:-1}")"
DNS_DOH_URL="$(state_escape "${DNS_DOH_URL:-$DEFAULT_DNS_DOH_URL}")"
DNS_LISTEN_PORT="$(state_escape "${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}")"
DNS_FAIL_MODE="$(state_escape "${DNS_FAIL_MODE:-$DEFAULT_DNS_FAIL_MODE}")"
DNS_PROXY_ENABLED="$(state_escape "${DNS_PROXY_ENABLED:-0}")"
LAST_SOURCE="$(state_escape "${LAST_SOURCE:-}")"
ACTIVE_PROFILE_ID="$(state_escape "${ACTIVE_PROFILE_ID:-}")"
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
  awk '/^vless:\/\// || /^socks:\/\// || /^socks5:\/\// || /^hysteria2:\/\// || /^hy2:\/\// { print }'
}

decode_subscription_blob() {
  tmp_in="$1"

  if grep -Eq 'vless://|socks://|socks5://|hysteria2://|hy2://' "$tmp_in"; then
    cat "$tmp_in"
    return 0
  fi

  if command -v base64 >/dev/null 2>&1; then
    decoded="$(base64 -d "$tmp_in" 2>/dev/null || true)"
    if printf '%s\n' "$decoded" | grep -Eq 'vless://|socks://|socks5://|hysteria2://|hy2://'; then
      printf '%s\n' "$decoded"
      return 0
    fi
  fi

  if command -v openssl >/dev/null 2>&1; then
    decoded="$(openssl base64 -d -A -in "$tmp_in" 2>/dev/null || true)"
    if printf '%s\n' "$decoded" | grep -Eq 'vless://|socks://|socks5://|hysteria2://|hy2://'; then
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

  [ -s "$out_file" ] || fail "no supported VLESS, Hysteria2 or SOCKS entries found in subscription"
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
    hysteria2://*|hy2://*) echo "hysteria2" ;;
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

validate_profile_id() {
  printf '%s' "${1:-}" | grep -Eq '^[0-9A-Za-z_-]+$' || fail "invalid profile id"
}

profile_url_exists() {
  encoded_url="$(b64_encode "$1")"
  awk -F '|' -v wanted="$encoded_url" '$4 == wanted { found=1 } END { exit !found }' "$LINKS_FILE"
}

profile_id_for_url() {
  encoded_url="$(b64_encode "$1")"
  awk -F '|' -v wanted="$encoded_url" '$4 == wanted { print $1; exit }' "$LINKS_FILE"
}

profile_url_by_id() {
  profile_id="$1"
  validate_profile_id "$profile_id"
  encoded_url="$(awk -F '|' -v wanted="$profile_id" '$1 == wanted { print $4; exit }' "$LINKS_FILE")"
  [ -n "$encoded_url" ] || fail "profile not found: $profile_id"
  b64_decode "$encoded_url"
}

profile_enabled_by_id() {
  profile_id="$1"
  validate_profile_id "$profile_id"
  awk -F '|' -v wanted="$profile_id" '$1 == wanted { print $2; exit }' "$LINKS_FILE"
}

profile_source_by_id() {
  profile_id="$1"
  validate_profile_id "$profile_id"
  encoded_source="$(awk -F '|' -v wanted="$profile_id" '$1 == wanted { print $5; exit }' "$LINKS_FILE")"
  [ -n "$encoded_source" ] || fail "profile not found: $profile_id"
  b64_decode "$encoded_source"
}

sync_subscription_loaded() {
  sub_url="$1"
  urls_file="$2"
  source_b64="$(b64_encode "$sub_url")"
  tmp_links="$(mktemp)"
  tmp_seen="$(mktemp)"
  existing_count="$(awk -F '|' -v source="$source_b64" '$5 == source { count++ } END { print count + 0 }' "$LINKS_FILE")"

  awk -F '|' -v source="$source_b64" '$5 != source { print }' "$LINKS_FILE" > "$tmp_links"
  SYNC_ADDED=0
  SYNC_KEPT=0
  while IFS= read -r profile_url; do
    [ -n "$profile_url" ] || continue
    build_proxy_outbound_json "$profile_url" >/dev/null
    profile_url_b64="$(b64_encode "$profile_url")"
    grep -qxF "$profile_url_b64" "$tmp_seen" 2>/dev/null && continue
    printf '%s\n' "$profile_url_b64" >> "$tmp_seen"

    existing_line="$(awk -F '|' -v source="$source_b64" -v url="$profile_url_b64" '$5 == source && $4 == url { print; exit }' "$LINKS_FILE")"
    if [ -n "$existing_line" ]; then
      printf '%s\n' "$existing_line" >> "$tmp_links"
      SYNC_KEPT=$((SYNC_KEPT + 1))
      continue
    fi

    profile_name="$(node_label "$profile_url")"
    profile_name="$(printf '%s' "$profile_name" | tr '\r\n\t' '   ' | cut -c 1-72)"
    profile_id="$(date +%s)-$$-$((SYNC_ADDED + 1))-$(wc -l < "$tmp_links" | tr -d ' ')"
    printf '%s|1|%s|%s|%s\n' \
      "$profile_id" \
      "$(b64_encode "$profile_name")" \
      "$profile_url_b64" \
      "$source_b64" >> "$tmp_links"
    SYNC_ADDED=$((SYNC_ADDED + 1))
  done < "$urls_file"

  SYNC_REMOVED=$((existing_count - SYNC_KEPT))
  mv "$tmp_links" "$LINKS_FILE"
  rm -f "$tmp_seen"
  chmod 0600 "$LINKS_FILE"

  if [ -n "${ACTIVE_PROFILE_ID:-}" ]; then
    active_exists="$(awk -F '|' -v wanted="$ACTIVE_PROFILE_ID" '$1 == wanted { print 1; exit }' "$LINKS_FILE")"
    if [ "$active_exists" != "1" ]; then
      ACTIVE_PROFILE_ID=""
      CURRENT_URL=""
    fi
  fi

  if [ -z "${ACTIVE_PROFILE_ID:-}" ]; then
    first_profile_id="$(awk -F '|' -v source="$source_b64" '$5 == source && $2 == 1 { print $1; exit }' "$LINKS_FILE")"
    if [ -n "$first_profile_id" ]; then
      ACTIVE_PROFILE_ID="$first_profile_id"
      CURRENT_URL="$(profile_url_by_id "$first_profile_id")"
      MODE="url"
    fi
  fi
}

profile_add_loaded() {
  profile_url="$1"
  profile_name="${2:-}"
  profile_source="${3:-manual}"
  validate_single_line "$profile_url"
  build_proxy_outbound_json "$profile_url" >/dev/null

  if profile_url_exists "$profile_url"; then
    PROFILE_RESULT_ID="$(profile_id_for_url "$profile_url")"
    return 0
  fi

  [ -n "$profile_name" ] || profile_name="$(node_label "$profile_url")"
  profile_name="$(printf '%s' "$profile_name" | tr '\r\n\t' '   ' | cut -c 1-72)"
  PROFILE_RESULT_ID="$(date +%s)-$$-$(wc -l < "$LINKS_FILE" | tr -d ' ')"
  printf '%s|1|%s|%s|%s\n' \
    "$PROFILE_RESULT_ID" \
    "$(b64_encode "$profile_name")" \
    "$(b64_encode "$profile_url")" \
    "$(b64_encode "$profile_source")" >> "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"
}

cmd_add_link() {
  load_state
  profile_url="${1:-}"
  [ -n "$profile_url" ] || fail "usage: xray-manager add-link <url> [name]"
  profile_add_loaded "$profile_url" "${2:-}" "manual"
  if [ -z "${ACTIVE_PROFILE_ID:-}" ]; then
    ACTIVE_PROFILE_ID="$PROFILE_RESULT_ID"
    CURRENT_URL="$profile_url"
    MODE="url"
  fi
  save_state
  echo "Profile saved: $PROFILE_RESULT_ID"
}

cmd_import_links() {
  load_state
  sub_url="${1:-}"
  case "$sub_url" in
    http://*|https://*) ;;
    *) fail "usage: xray-manager import-links <subscription-url>" ;;
  esac

  tmp_urls="$(mktemp)"
  fetch_subscription_urls_file "$sub_url" "$tmp_urls"
  sync_subscription_loaded "$sub_url" "$tmp_urls"
  rm -f "$tmp_urls"
  save_state
  echo "Subscription updated: added $SYNC_ADDED, kept $SYNC_KEPT, removed $SYNC_REMOVED"
}

cmd_refresh_links() {
  load_state
  sub_url="${1:-}"
  case "$sub_url" in
    http://*|https://*) ;;
    *) fail "usage: xray-manager refresh-links <subscription-url>" ;;
  esac
  source_b64="$(b64_encode "$sub_url")"
  existing_count="$(awk -F '|' -v source="$source_b64" '$5 == source { count++ } END { print count + 0 }' "$LINKS_FILE")"
  [ "$existing_count" -gt 0 ] || fail "subscription not found"

  tmp_urls="$(mktemp)"
  fetch_subscription_urls_file "$sub_url" "$tmp_urls"
  sync_subscription_loaded "$sub_url" "$tmp_urls"
  rm -f "$tmp_urls"
  save_state
  echo "Subscription updated: added $SYNC_ADDED, kept $SYNC_KEPT, removed $SYNC_REMOVED"
}

cmd_refresh_all_links() {
  load_state
  tmp_sources="$(mktemp)"
  while IFS='|' read -r _ _ _ _ source_b64; do
    [ -n "$source_b64" ] || continue
    source="$(b64_decode "$source_b64")"
    case "$source" in http://*|https://*) printf '%s\n' "$source_b64" ;; esac
  done < "$LINKS_FILE" | awk '!seen[$0]++' > "$tmp_sources"
  [ -s "$tmp_sources" ] || { rm -f "$tmp_sources"; fail "no subscriptions configured"; }
  while IFS= read -r source_b64; do
    cmd_refresh_links "$(b64_decode "$source_b64")"
  done < "$tmp_sources"
  rm -f "$tmp_sources"
}

cmd_list_links() {
  load_state
  if [ ! -s "$LINKS_FILE" ]; then
    echo "No profiles configured"
    return 0
  fi
  while IFS='|' read -r profile_id profile_enabled profile_name_b64 profile_url_b64 profile_source_b64; do
    [ -n "$profile_id" ] || continue
    profile_url="$(b64_decode "$profile_url_b64")"
    profile_name="$(b64_decode "$profile_name_b64")"
    marker=" "
    [ "$profile_id" = "${ACTIVE_PROFILE_ID:-}" ] && marker="*"
    status="off"
    [ "$profile_enabled" = "1" ] && status="on"
    printf '%s %-22s [%s] %-10s %s\n' "$marker" "$profile_id" "$status" "$(url_kind "$profile_url")" "$profile_name"
  done < "$LINKS_FILE"
}

cmd_select_link() {
  load_state
  profile_id="${1:-}"
  validate_profile_id "$profile_id"
  [ "$(profile_enabled_by_id "$profile_id")" = "1" ] || fail "profile is disabled"
  CURRENT_URL="$(profile_url_by_id "$profile_id")"
  ACTIVE_PROFILE_ID="$profile_id"
  MODE="url"
  LAST_SOURCE="profile-select"
  save_state
  echo "Selected: $(describe_url "$CURRENT_URL")"
  echo "Run: xray-manager apply"
}

cmd_use_link() {
  cmd_select_link "${1:-}"
  cmd_apply
}

cmd_set_link_enabled() {
  load_state
  profile_id="${1:-}"
  requested="${2:-}"
  validate_profile_id "$profile_id"
  case "$requested" in 0|1) ;; *) fail "enabled must be 0 or 1" ;; esac
  profile_exists="$(awk -F '|' -v wanted="$profile_id" '$1 == wanted { print 1; exit }' "$LINKS_FILE")"
  [ "$profile_exists" = "1" ] || fail "profile not found: $profile_id"
  tmp_links="$(mktemp)"
  awk -F '|' -v OFS='|' -v wanted="$profile_id" -v enabled="$requested" '$1 == wanted { $2=enabled } { print }' "$LINKS_FILE" > "$tmp_links"
  mv "$tmp_links" "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"
  if [ "$requested" = "0" ] && [ "$profile_id" = "${ACTIVE_PROFILE_ID:-}" ]; then
    ACTIVE_PROFILE_ID=""
    CURRENT_URL=""
    save_state
  fi
  echo "Profile updated"
}

cmd_del_link() {
  load_state
  profile_id="${1:-}"
  validate_profile_id "$profile_id"
  tmp_links="$(mktemp)"
  awk -F '|' -v wanted="$profile_id" '$1 != wanted { print }' "$LINKS_FILE" > "$tmp_links"
  mv "$tmp_links" "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"
  if [ "$profile_id" = "${ACTIVE_PROFILE_ID:-}" ]; then
    ACTIVE_PROFILE_ID=""
    CURRENT_URL=""
  fi
  save_state
  echo "Profile removed"
}

cmd_del_subscription() {
  load_state
  sub_url="${1:-}"
  case "$sub_url" in
    http://*|https://*) ;;
    *) fail "usage: xray-manager del-subscription <subscription-url>" ;;
  esac

  source_b64="$(b64_encode "$sub_url")"
  removed_count="$(awk -F '|' -v source="$source_b64" '$5 == source { count++ } END { print count + 0 }' "$LINKS_FILE")"
  [ "$removed_count" -gt 0 ] || fail "subscription not found"

  active_source=""
  if [ -n "${ACTIVE_PROFILE_ID:-}" ]; then
    active_source="$(awk -F '|' -v wanted="$ACTIVE_PROFILE_ID" '$1 == wanted { print $5; exit }' "$LINKS_FILE")"
  fi

  tmp_links="$(mktemp)"
  awk -F '|' -v source="$source_b64" '$5 != source { print }' "$LINKS_FILE" > "$tmp_links"
  mv "$tmp_links" "$LINKS_FILE"
  chmod 0600 "$LINKS_FILE"

  if [ "$active_source" = "$source_b64" ]; then
    ACTIVE_PROFILE_ID=""
    CURRENT_URL=""
    MODE="url"
  fi
  if [ "${SUBSCRIPTION_URL:-}" = "$sub_url" ]; then
    SUBSCRIPTION_URL=""
    SUBSCRIPTION_PICK="1"
    if [ "${MODE:-url}" = "subscription" ]; then
      MODE="url"
      ACTIVE_PROFILE_ID=""
      CURRENT_URL=""
    fi
  fi

  save_state
  echo "Subscription removed: $removed_count profiles"
}

cmd_ping_link() {
  load_state
  profile_id="${1:-}"
  profile_url="$(profile_url_by_id "$profile_id")"
  profile_host="$(url_host "$profile_url")"
  [ -n "$profile_host" ] || fail "profile host is empty"
  case "$profile_host" in
    -*|*[!A-Za-z0-9_.:%-]*) fail "profile host contains unsupported characters" ;;
  esac

  ping_output=""
  case "$profile_host" in
    *:*)
      command -v ping6 >/dev/null 2>&1 || fail "IPv6 ping is not available"
      if ! ping_output="$(ping6 -c 1 -W 3 "$profile_host" 2>&1)"; then
        fail "no ping response from $profile_host"
      fi
      ;;
    *)
      command -v ping >/dev/null 2>&1 || fail "ping is not available"
      if ! ping_output="$(ping -c 1 -W 3 "$profile_host" 2>&1)"; then
        fail "no ping response from $profile_host"
      fi
      ;;
  esac

  latency="$(printf '%s\n' "$ping_output" | sed -n 's/.*time[=<]\([0-9.][0-9.]*\)[[:space:]]*ms.*/\1/p' | head -n 1)"
  [ -n "$latency" ] || fail "ping response did not contain latency"
  printf '%s\n' "$latency"
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
  validate_single_line "$rule"
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
  printf '%s,%s\n' "${BYPASS_MACS:-}" "${BYPASS_MACS_DISABLED:-}" | tr ',' '\n' | grep -qx "$m"
}

rule_exists() {
  r="$(normalize_bypass_rule "$1")"
  printf '%s,%s\n' "${BYPASS_RULES:-}" "${BYPASS_RULES_DISABLED:-}" | tr ',' '\n' | grep -Fxq "$r"
}

comma_remove_fixed() {
  list_value="$1"
  item_value="$2"
  printf '%s\n' "$list_value" | tr ',' '\n' | grep -Fvx "$item_value" | join_comma_lines || true
}

comma_append() {
  list_value="$1"
  item_value="$2"
  if [ -n "$list_value" ]; then
    printf '%s,%s' "$list_value" "$item_value"
  else
    printf '%s' "$item_value"
  fi
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

  if [ -z "${BYPASS_MACS:-}${BYPASS_MACS_DISABLED:-}" ]; then
    echo "No bypass MACs configured"
    return 0
  fi

  BYPASS_MACS="$(comma_remove_fixed "${BYPASS_MACS:-}" "$m")"
  BYPASS_MACS_DISABLED="$(comma_remove_fixed "${BYPASS_MACS_DISABLED:-}" "$m")"

  save_state
  echo "MAC removed. Run: xray-manager apply"
}

list_mac() {
  load_state
  if [ -z "${BYPASS_MACS:-}${BYPASS_MACS_DISABLED:-}" ]; then
    echo "No bypass MACs configured"
    return 0
  fi
  printf '%s\n' "${BYPASS_MACS:-}" | tr ',' '\n' | sed '/^$/d; s/^/[on]  /'
  printf '%s\n' "${BYPASS_MACS_DISABLED:-}" | tr ',' '\n' | sed '/^$/d; s/^/[off] /'
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

  if [ -z "${BYPASS_RULES:-}${BYPASS_RULES_DISABLED:-}" ]; then
    echo "No bypass rules configured"
    return 0
  fi

  BYPASS_RULES="$(comma_remove_fixed "${BYPASS_RULES:-}" "$r")"
  BYPASS_RULES_DISABLED="$(comma_remove_fixed "${BYPASS_RULES_DISABLED:-}" "$r")"

  save_state
  echo "Bypass rule removed. Run: xray-manager apply"
}

list_rules() {
  load_state
  if [ -z "${BYPASS_RULES:-}${BYPASS_RULES_DISABLED:-}" ]; then
    echo "No bypass rules configured"
    return 0
  fi
  printf '%s\n' "${BYPASS_RULES:-}" | tr ',' '\n' | sed '/^$/d; s/^/[on]  /'
  printf '%s\n' "${BYPASS_RULES_DISABLED:-}" | tr ',' '\n' | sed '/^$/d; s/^/[off] /'
}

cmd_set_bypass_mac() {
  load_state
  m="${1:-}"
  enabled="${2:-}"
  validate_mac "$m"
  m="$(normalize_mac "$m")"
  case "$enabled" in 0|1) ;; *) fail "enabled must be 0 or 1" ;; esac
  mac_exists "$m" || fail "MAC not found: $m"
  BYPASS_MACS="$(comma_remove_fixed "${BYPASS_MACS:-}" "$m")"
  BYPASS_MACS_DISABLED="$(comma_remove_fixed "${BYPASS_MACS_DISABLED:-}" "$m")"
  if [ "$enabled" = "1" ]; then
    BYPASS_MACS="$(comma_append "$BYPASS_MACS" "$m")"
  else
    BYPASS_MACS_DISABLED="$(comma_append "$BYPASS_MACS_DISABLED" "$m")"
  fi
  save_state
  echo "MAC updated. Run: xray-manager apply"
}

cmd_set_bypass_rule() {
  load_state
  r="${1:-}"
  enabled="${2:-}"
  validate_bypass_rule "$r"
  r="$(normalize_bypass_rule "$r")"
  case "$enabled" in 0|1) ;; *) fail "enabled must be 0 or 1" ;; esac
  rule_exists "$r" || fail "bypass rule not found: $r"
  BYPASS_RULES="$(comma_remove_fixed "${BYPASS_RULES:-}" "$r")"
  BYPASS_RULES_DISABLED="$(comma_remove_fixed "${BYPASS_RULES_DISABLED:-}" "$r")"
  if [ "$enabled" = "1" ]; then
    BYPASS_RULES="$(comma_append "$BYPASS_RULES" "$r")"
  else
    BYPASS_RULES_DISABLED="$(comma_append "$BYPASS_RULES_DISABLED" "$r")"
  fi
  save_state
  echo "Bypass rule updated. Run: xray-manager apply"
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
  XHTTP_MODE="$(get_query_param_decoded mode)"

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
  XHTTP_MODE_ESC="$(json_escape "$XHTTP_MODE")"

  FLOW_LINE=""
  if [ -n "$FLOW" ]; then
    FLOW_LINE=",
                \"flow\": \"$(json_escape "$FLOW")\""
  fi
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
    xhttp|splithttp)
      XHTTP_MODE_JSON=""
      [ -n "$XHTTP_MODE" ] && XHTTP_MODE_JSON=",
          \"mode\": \"${XHTTP_MODE_ESC}\""
      VLESS_STREAM_EXTRA_JSON="${VLESS_STREAM_EXTRA_JSON},
        \"xhttpSettings\": {
          \"path\": \"${WS_PATH_ESC}\",
          \"host\": \"${WS_HOST_ESC}\"${XHTTP_MODE_JSON}
        }"
      TYPE="xhttp"
      TYPE_ESC="xhttp"
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

parse_hysteria2() {
  HYSTERIA_URL="$1"
  case "$HYSTERIA_URL" in
    hysteria2://*|hy2://*) ;;
    *) fail "Hysteria2 URL must start with hysteria2:// or hy2://" ;;
  esac

  RAW="${HYSTERIA_URL#*://}"
  MAIN="${RAW%%#*}"
  AUTHORITY="${MAIN%%\?*}"
  if [ "$AUTHORITY" = "$MAIN" ]; then
    QUERY=""
  else
    QUERY="${MAIN#*\?}"
  fi

  HYSTERIA_AUTH=""
  HOST_PORT="$AUTHORITY"
  case "$AUTHORITY" in
    *@*)
      HYSTERIA_AUTH="$(url_decode "${AUTHORITY%%@*}")"
      HOST_PORT="${AUTHORITY#*@}"
      ;;
  esac
  HOST_PORT="${HOST_PORT%/}"
  parse_host_port "$HOST_PORT" "443"
  HYSTERIA_HOST="$PARSED_HOST"
  HYSTERIA_PORT="$PARSED_PORT"
  HYSTERIA_SNI="$(get_query_param_decoded sni)"
  [ -n "$HYSTERIA_SNI" ] || HYSTERIA_SNI="$HYSTERIA_HOST"
  HYSTERIA_FP="$(get_query_param_decoded fp)"
  HYSTERIA_INSECURE="$(get_query_param_decoded insecure)"
  HYSTERIA_PIN="$(get_query_param_decoded pinSHA256)"
  [ -n "$HYSTERIA_PIN" ] || HYSTERIA_PIN="$(get_query_param_decoded pinsha256)"
  HYSTERIA_OBFS="$(get_query_param_decoded obfs)"
  HYSTERIA_OBFS_PASSWORD="$(get_query_param_decoded obfs-password)"

  HYSTERIA_HOST_ESC="$(json_escape "$HYSTERIA_HOST")"
  HYSTERIA_AUTH_ESC="$(json_escape "$HYSTERIA_AUTH")"
  HYSTERIA_SNI_ESC="$(json_escape "$HYSTERIA_SNI")"
  HYSTERIA_FP_ESC="$(json_escape "$HYSTERIA_FP")"
  HYSTERIA_PIN_ESC="$(json_escape "$HYSTERIA_PIN")"
  HYSTERIA_OBFS_PASSWORD_ESC="$(json_escape "$HYSTERIA_OBFS_PASSWORD")"
}

build_hysteria2_outbound_json() {
  parse_hysteria2 "$1"
  case "$HYSTERIA_INSECURE" in
    1|true|TRUE|yes) HYSTERIA_INSECURE_JSON="true" ;;
    *) HYSTERIA_INSECURE_JSON="false" ;;
  esac

  HYSTERIA_FP_JSON=""
  [ -n "$HYSTERIA_FP" ] && HYSTERIA_FP_JSON=",
          \"fingerprint\": \"${HYSTERIA_FP_ESC}\""
  HYSTERIA_PIN_JSON=""
  [ -n "$HYSTERIA_PIN" ] && HYSTERIA_PIN_JSON=",
          \"pinnedPeerCertSha256\": \"${HYSTERIA_PIN_ESC}\""
  HYSTERIA_MASK_JSON=""
  if [ "$HYSTERIA_OBFS" = "salamander" ] && [ -n "$HYSTERIA_OBFS_PASSWORD" ]; then
    HYSTERIA_MASK_JSON=",
        \"finalmask\": {
          \"udp\": [
            {
              \"type\": \"salamander\",
              \"settings\": { \"password\": \"${HYSTERIA_OBFS_PASSWORD_ESC}\" }
            }
          ]
        }"
  fi

  cat <<EOS
    {
      "tag": "proxy",
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "address": "${HYSTERIA_HOST_ESC}",
        "port": ${HYSTERIA_PORT}
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${HYSTERIA_SNI_ESC}",
          "alpn": ["h3"],
          "allowInsecure": ${HYSTERIA_INSECURE_JSON}${HYSTERIA_FP_JSON}${HYSTERIA_PIN_JSON}
        },
        "hysteriaSettings": {
          "version": 2,
          "auth": "${HYSTERIA_AUTH_ESC}"
        }${HYSTERIA_MASK_JSON}
      }
    }
EOS
}

build_proxy_outbound_json() {
  case "$1" in
    vless://*) build_vless_outbound_json "$1" ;;
    hysteria2://*|hy2://*) build_hysteria2_outbound_json "$1" ;;
    socks://*|socks5://*) build_socks_outbound_json "$1" ;;
    *) fail "unsupported connection URL. Use vless://, hysteria2://, hy2://, socks:// or socks5://." ;;
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
  if [ "${DNS_TUNNEL_ENABLED:-0}" = "1" ] && [ ! -f "$DNS_FALLBACK_FLAG" ]; then
    dns_start_proxy || warn "failed to restart https-dns-proxy"
  fi
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
    vless://*|hysteria2://*|hy2://*|socks://*|socks5://*)
      MODE="url"
      CURRENT_URL="$input"
      LAST_SOURCE="$(url_kind "$input")"
      profile_add_loaded "$input" "" "console"
      ACTIVE_PROFILE_ID="$PROFILE_RESULT_ID"
      ;;
    *)
      fail "unsupported URL. Use vless://, hysteria2://, hy2://, socks://, socks5:// or a subscription URL."
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
  profile_add_loaded "$selected" "" "$sub_url"
  ACTIVE_PROFILE_ID="$PROFILE_RESULT_ID"
  echo "Selected #${SUBSCRIPTION_PICK}: $(describe_url "$CURRENT_URL")"
}

configure_input() {
  load_state
  input="${1:-}"
  validate_single_line "$input"
  [ -n "$input" ] || fail "usage: xray-manager set <vless://... | hysteria2://... | socks://... | https://...>"

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
  validate_single_line "$LOCAL_SOCKS_LISTEN"
  save_state
  echo "Local SOCKS listener saved: ${LOCAL_SOCKS_LISTEN}:${LOCAL_SOCKS_PORT}"
  echo "Run: xray-manager apply"
}

dns_proxy_host() {
  case "${LOCAL_SOCKS_LISTEN:-$DEFAULT_LOCAL_SOCKS_LISTEN}" in
    0.0.0.0|::|::0) echo "127.0.0.1" ;;
    *) echo "${LOCAL_SOCKS_LISTEN:-$DEFAULT_LOCAL_SOCKS_LISTEN}" ;;
  esac
}

dns_backup_dhcp() {
  [ -s "$DNS_DHCP_BACKUP" ] && return 0
  if [ -s /root/dhcp-before-doh.txt ]; then
    cp /root/dhcp-before-doh.txt "$DNS_DHCP_BACKUP"
  else
    umask 077
    uci export dhcp > "$DNS_DHCP_BACKUP"
  fi
  chmod 0600 "$DNS_DHCP_BACKUP"
}

dns_switch_dnsmasq_to_doh() {
  dns_backup_dhcp
  uci set 'dhcp.@dnsmasq[0].noresolv=1'
  uci -q delete 'dhcp.@dnsmasq[0].server' || true
  uci add_list "dhcp.@dnsmasq[0].server=127.0.0.1#${DNS_LISTEN_PORT}"
  uci commit dhcp
  /etc/init.d/dnsmasq restart >/dev/null 2>&1
}

dns_restore_wan_runtime() {
  /etc/init.d/https-dns-proxy stop >/dev/null 2>&1 || true
  /etc/init.d/https-dns-proxy disable >/dev/null 2>&1 || true
  if [ -s "$DNS_DHCP_BACKUP" ]; then
    uci import dhcp < "$DNS_DHCP_BACKUP"
  else
    uci -q delete 'dhcp.@dnsmasq[0].noresolv' || true
    uci -q delete 'dhcp.@dnsmasq[0].server' || true
    uci set 'dhcp.@dnsmasq[0].resolvfile=/tmp/resolv.conf.d/resolv.conf.auto'
  fi
  uci commit dhcp
  /etc/init.d/dnsmasq restart >/dev/null 2>&1
}

dns_write_proxy_config() {
  validate_port "${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}"
  validate_doh_url "${DNS_DOH_URL:-$DEFAULT_DNS_DOH_URL}"
  proxy_option=""
  case "${DNS_PROXY_ENABLED:-0}" in
    0) ;;
    1)
      proxy_host="$(dns_proxy_host)"
      printf '%s' "$proxy_host" | grep -Eq '^[A-Za-z0-9_.:-]+$' || fail "invalid local SOCKS host for DNS: $proxy_host"
      validate_port "${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}"
      case "$proxy_host" in *:*) proxy_uri_host="[${proxy_host}]" ;; *) proxy_uri_host="$proxy_host" ;; esac
      proxy_option="  option proxy_server 'socks5h://${proxy_uri_host}:${LOCAL_SOCKS_PORT}'"
      ;;
    *) fail "DNS proxy enabled must be 0 or 1" ;;
  esac
  tmp_dns_config="$(mktemp)"
  cat > "$tmp_dns_config" <<EOS
config main 'config'
  option dnsmasq_config_update '-'
  option force_dns '0'
  option notrack_dns '0'
  option canary_domains_icloud '1'
  option canary_domains_mozilla '1'
${proxy_option}
  option force_ip_family 'ipv4'
  option heartbeat_domain '-'

config https-dns-proxy 'dns'
  option resolver_url '${DNS_DOH_URL}'
  option bootstrap_dns '8.8.8.8,8.8.4.4'
  option listen_addr '127.0.0.1'
  option listen_port '${DNS_LISTEN_PORT}'
EOS
  mv "$tmp_dns_config" /etc/config/https-dns-proxy
  chmod 0600 /etc/config/https-dns-proxy
}

dns_start_proxy() {
  [ -x /etc/init.d/https-dns-proxy ] || return 1
  /etc/init.d/https-dns-proxy stop >/dev/null 2>&1 || true
  dns_write_proxy_config
  /etc/init.d/https-dns-proxy enable >/dev/null 2>&1
  /etc/init.d/https-dns-proxy start >/dev/null 2>&1
}

dns_probe_doh() {
  if [ "${DNS_PROXY_ENABLED:-0}" = "1" ]; then
    pidof xray >/dev/null 2>&1 || return 1
  fi
  pidof https-dns-proxy >/dev/null 2>&1 || return 1

  if command -v nslookup >/dev/null 2>&1; then
    nslookup www.youtube.com "127.0.0.1:${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}" >/dev/null 2>&1 || \
      nslookup www.youtube.com "127.0.0.1#${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}" >/dev/null 2>&1
    return
  fi

  if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- '-u'; then
    response_bytes="$({
      printf '\130\115\001\000\000\001\000\000\000\000\000\000\003www\007youtube\003com\000\000\001\000\001' |
        nc -u -w 6 127.0.0.1 "${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}" 2>/dev/null
    } | wc -c | tr -d ' ')"
    [ "${response_bytes:-0}" -ge 12 ] 2>/dev/null
    return
  fi

  return 1
}

dns_watchdog_start() {
  /etc/init.d/xray-dns-watchdog enable >/dev/null 2>&1
  /etc/init.d/xray-dns-watchdog restart >/dev/null 2>&1
}

dns_watchdog_stop() {
  /etc/init.d/xray-dns-watchdog stop >/dev/null 2>&1 || true
  /etc/init.d/xray-dns-watchdog disable >/dev/null 2>&1 || true
}

dns_restore_previous_mode() {
  DNS_TUNNEL_ENABLED="$previous_enabled"
  DNS_DOH_URL="$previous_url"
  DNS_LISTEN_PORT="$previous_port"
  DNS_FAIL_MODE="$previous_fail_mode"
  DNS_PROXY_ENABLED="$previous_proxy_enabled"

  if [ "$previous_enabled" = "1" ]; then
    if dns_start_proxy; then
      sleep 2
      if [ "$previous_fail_mode" = "strict" ]; then
        dns_switch_dnsmasq_to_doh || true
      elif dns_probe_doh; then
        dns_switch_dnsmasq_to_doh || true
      else
        touch "$DNS_FALLBACK_FLAG" "$DNS_DEGRADED_FLAG"
        dns_restore_wan_runtime
      fi
    elif [ "$previous_fail_mode" = "strict" ]; then
      touch "$DNS_DEGRADED_FLAG"
      dns_switch_dnsmasq_to_doh || true
    else
      touch "$DNS_FALLBACK_FLAG" "$DNS_DEGRADED_FLAG"
      dns_restore_wan_runtime
    fi
    dns_watchdog_start
  else
    /etc/init.d/https-dns-proxy stop >/dev/null 2>&1 || true
    /etc/init.d/https-dns-proxy disable >/dev/null 2>&1 || true
    if [ -s "$DNS_DHCP_BACKUP" ]; then
      dns_restore_wan_runtime
      rm -f "$DNS_DHCP_BACKUP"
    fi
  fi
  save_state
}

cmd_set_dns() {
  load_state
  previous_enabled="${DNS_TUNNEL_ENABLED:-0}"
  previous_url="${DNS_DOH_URL:-$DEFAULT_DNS_DOH_URL}"
  previous_port="${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}"
  previous_fail_mode="${DNS_FAIL_MODE:-$DEFAULT_DNS_FAIL_MODE}"
  previous_proxy_enabled="${DNS_PROXY_ENABLED:-0}"
  requested_enabled="${1:-0}"
  requested_url="${2:-$previous_url}"
  requested_port="${3:-$previous_port}"
  requested_fail_mode="${4:-$previous_fail_mode}"
  requested_proxy_enabled="${5:-$previous_proxy_enabled}"

  case "$requested_enabled" in 0|1) ;; *) fail "DNS enabled must be 0 or 1" ;; esac
  validate_doh_url "$requested_url"
  validate_port "$requested_port"
  case "$requested_fail_mode" in strict|fallback) ;; *) fail "DNS fail mode must be strict or fallback" ;; esac
  case "$requested_proxy_enabled" in 0|1) ;; *) fail "DNS proxy enabled must be 0 or 1" ;; esac
  if [ "$requested_enabled" = "1" ]; then
    [ -x /usr/sbin/https-dns-proxy ] || fail "https-dns-proxy is not installed; run: opkg update && opkg install https-dns-proxy"
  fi

  if [ "$requested_enabled" != "1" ]; then
    DNS_TUNNEL_ENABLED="0"
    DNS_DOH_URL="$requested_url"
    DNS_LISTEN_PORT="$requested_port"
    DNS_FAIL_MODE="$requested_fail_mode"
    DNS_PROXY_ENABLED="$requested_proxy_enabled"
    save_state
    dns_watchdog_stop
    rm -f "$DNS_FALLBACK_FLAG" "$DNS_DEGRADED_FLAG"
    dns_restore_wan_runtime
    rm -f "$DNS_DHCP_BACKUP"
    echo "DoH disabled; dnsmasq uses WAN resolvers"
    return 0
  fi

  dns_watchdog_stop
  if [ "$previous_enabled" = "1" ]; then
    dns_restore_wan_runtime
  fi

  DNS_TUNNEL_ENABLED="1"
  DNS_DOH_URL="$requested_url"
  DNS_LISTEN_PORT="$requested_port"
  DNS_FAIL_MODE="$requested_fail_mode"
  DNS_PROXY_ENABLED="$requested_proxy_enabled"

  if ! dns_start_proxy; then
    dns_restore_previous_mode
    echo "Error: failed to start https-dns-proxy; previous DNS settings were restored" >&2
    return 1
  fi
  sleep 2

  if ! dns_probe_doh; then
    /etc/init.d/https-dns-proxy stop >/dev/null 2>&1 || true
    /etc/init.d/https-dns-proxy disable >/dev/null 2>&1 || true
    dns_restore_previous_mode
    touch "$DNS_DEGRADED_FLAG"
    echo "Error: DoH on 127.0.0.1:${requested_port} did not answer; dnsmasq was not switched" >&2
    return 1
  fi

  if ! dns_switch_dnsmasq_to_doh; then
    /etc/init.d/https-dns-proxy stop >/dev/null 2>&1 || true
    dns_restore_previous_mode
    echo "Error: failed to switch dnsmasq to local DoH; previous DNS settings were restored" >&2
    return 1
  fi

  save_state
  rm -f "$DNS_FALLBACK_FLAG" "$DNS_DEGRADED_FLAG"
  dns_watchdog_start
  if [ "$DNS_PROXY_ENABLED" = "1" ]; then
    echo "DoH enabled through Xray: dnsmasq -> ${DNS_DOH_URL} -> socks5h://$(dns_proxy_host):${LOCAL_SOCKS_PORT}"
  else
    echo "Direct DoH enabled: dnsmasq -> ${DNS_DOH_URL}"
  fi
}

cmd_dns_test() {
  load_state
  [ "${DNS_TUNNEL_ENABLED:-0}" = "1" ] || fail "DoH is disabled"
  if [ "${DNS_PROXY_ENABLED:-0}" = "1" ]; then
    echo "Testing ${DNS_DOH_URL} via Xray SOCKS..."
  else
    echo "Testing ${DNS_DOH_URL} directly..."
  fi
  if ! dns_probe_doh; then
    touch "$DNS_DEGRADED_FLAG"
    fail "DoH did not answer"
  fi
  rm -f "$DNS_DEGRADED_FLAG"
  echo "OK"
}

cmd_dns_watch() {
  failures=0
  while :; do
    load_state
    [ "${DNS_TUNNEL_ENABLED:-0}" = "1" ] || exit 0

    if [ "${DNS_FAIL_MODE:-strict}" = "strict" ]; then
      if ! pidof https-dns-proxy >/dev/null 2>&1; then
        dns_start_proxy || true
        sleep 3
      fi
      if dns_probe_doh; then
        if [ -f "$DNS_DEGRADED_FLAG" ]; then
          rm -f "$DNS_DEGRADED_FLAG"
          logger -t xray-manager "DoH recovered"
        fi
        failures=0
      else
        failures=$((failures + 1))
        if [ "$failures" -ge 2 ]; then
          touch "$DNS_DEGRADED_FLAG"
          logger -t xray-manager "DoH failed; strict mode keeps WAN DNS closed"
          failures=0
        fi
      fi
      sleep 15
      continue
    fi

    if [ -f "$DNS_FALLBACK_FLAG" ]; then
      if dns_start_proxy; then
        sleep 3
        if dns_probe_doh; then
          if dns_switch_dnsmasq_to_doh; then
            rm -f "$DNS_FALLBACK_FLAG" "$DNS_DEGRADED_FLAG"
            failures=0
            logger -t xray-manager "DoH recovered; WAN DNS fallback disabled"
            sleep 15
            continue
          fi
        fi
      fi
      touch "$DNS_FALLBACK_FLAG"
      touch "$DNS_DEGRADED_FLAG"
      dns_restore_wan_runtime
      sleep 45
      continue
    fi

    if ! pidof https-dns-proxy >/dev/null 2>&1; then
      dns_start_proxy || true
      sleep 3
    fi

    if dns_probe_doh; then
      rm -f "$DNS_DEGRADED_FLAG"
      failures=0
    else
      failures=$((failures + 1))
      if [ "$failures" -ge 2 ]; then
        touch "$DNS_FALLBACK_FLAG"
        touch "$DNS_DEGRADED_FLAG"
        dns_restore_wan_runtime
        logger -t xray-manager "DoH failed; restored WAN DNS fallback"
        failures=0
      fi
    fi
    sleep 15
  done
}

cmd_migrate_dns_state() {
  load_state
  [ "${DNS_TUNNEL_ENABLED:-0}" = "0" ] || return 0
  current_port="$(uci -q get https-dns-proxy.dns.listen_port 2>/dev/null || true)"
  [ -n "$current_port" ] || current_port="$DEFAULT_DNS_LISTEN_PORT"
  current_dnsmasq_servers="$(uci -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null || true)"
  case " $current_dnsmasq_servers " in *" 127.0.0.1#${current_port} "*) ;; *) return 0 ;; esac
  current_proxy="$(uci -q get https-dns-proxy.config.proxy_server 2>/dev/null || true)"
  current_url="$(uci -q get https-dns-proxy.dns.resolver_url 2>/dev/null || true)"
  DNS_TUNNEL_ENABLED="1"
  case "$current_proxy" in socks5h://*|socks5://*) DNS_PROXY_ENABLED="1" ;; *) DNS_PROXY_ENABLED="0" ;; esac
  case "$current_url" in https://*) DNS_DOH_URL="$current_url" ;; esac
  if is_number "$current_port" && [ "$current_port" -ge 1 ] 2>/dev/null && [ "$current_port" -le 65535 ] 2>/dev/null; then DNS_LISTEN_PORT="$current_port"; fi
  DNS_FAIL_MODE="strict"
  if [ ! -s "$DNS_DHCP_BACKUP" ] && [ -s /root/dhcp-before-doh.txt ]; then
    cp /root/dhcp-before-doh.txt "$DNS_DHCP_BACKUP"
    chmod 0600 "$DNS_DHCP_BACKUP"
  fi
  save_state
}

cmd_apply_dns_state() {
  load_state
  saved_enabled="${DNS_TUNNEL_ENABLED:-0}"
  saved_url="${DNS_DOH_URL:-$DEFAULT_DNS_DOH_URL}"
  saved_port="${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}"
  saved_fail_mode="${DNS_FAIL_MODE:-$DEFAULT_DNS_FAIL_MODE}"
  saved_proxy_enabled="${DNS_PROXY_ENABLED:-0}"
  cmd_set_dns "$saved_enabled" "$saved_url" "$saved_port" "$saved_fail_mode" "$saved_proxy_enabled"
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
      if [ -n "${ACTIVE_PROFILE_ID:-}" ]; then
        [ "$(profile_enabled_by_id "$ACTIVE_PROFILE_ID")" = "1" ] || fail "active profile is disabled"
        next_url="$(profile_url_by_id "$ACTIVE_PROFILE_ID")"
        next_source="profile-apply"
      fi
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
  echo "DNS_TUNNEL_ENABLED=${DNS_TUNNEL_ENABLED:-0}"
  echo "DNS_DOH_URL=${DNS_DOH_URL:-$DEFAULT_DNS_DOH_URL}"
  echo "DNS_LISTEN_PORT=${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}"
  echo "DNS_FAIL_MODE=${DNS_FAIL_MODE:-$DEFAULT_DNS_FAIL_MODE}"
  echo "DNS_PROXY_ENABLED=${DNS_PROXY_ENABLED:-0}"
  echo "LAN_IFACE=${LAN_IFACE:-$DEFAULT_LAN_IFACE}"
  echo "TPROXY_PORT=${TPROXY_PORT:-$DEFAULT_TPROXY_PORT}"
  echo "BYPASS_MACS=${BYPASS_MACS:-}"
  echo "BYPASS_MACS_DISABLED=${BYPASS_MACS_DISABLED:-}"
  echo "BYPASS_RULES=${BYPASS_RULES:-}"
  echo "BYPASS_RULES_DISABLED=${BYPASS_RULES_DISABLED:-}"
  echo "LAST_SOURCE=${LAST_SOURCE:-}"
  echo "ACTIVE_PROFILE_ID=${ACTIVE_PROFILE_ID:-}"
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
  load_state
  /etc/init.d/xray start
  /etc/init.d/xray-tproxy start
  if [ "${DNS_TUNNEL_ENABLED:-0}" = "1" ]; then
    dns_start_proxy || warn "failed to start DoH"
    dns_watchdog_start
  fi
}

cmd_off() {
  load_state
  if [ "${DNS_TUNNEL_ENABLED:-0}" = "1" ] && [ "${DNS_PROXY_ENABLED:-0}" = "1" ] && [ "${DNS_FAIL_MODE:-strict}" = "fallback" ]; then
    dns_watchdog_stop
    touch "$DNS_FALLBACK_FLAG"
    touch "$DNS_DEGRADED_FLAG"
    dns_restore_wan_runtime
  fi
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
  if [ "${DNS_TUNNEL_ENABLED:-0}" = "1" ]; then
    [ -x /usr/sbin/https-dns-proxy ] || fail "/usr/sbin/https-dns-proxy is missing"
    [ -f /etc/config/https-dns-proxy ] || fail "/etc/config/https-dns-proxy is missing"
    if [ "${DNS_FAIL_MODE:-strict}" = "strict" ]; then
      dns_probe_doh || fail "DoH does not answer"
    fi
  fi
  echo "OK"
}

api_print_profiles() {
  first=1
  while IFS='|' read -r profile_id profile_enabled profile_name_b64 profile_url_b64 profile_source_b64; do
    [ -n "$profile_id" ] || continue
    profile_url="$(b64_decode "$profile_url_b64")"
    profile_name="$(b64_decode "$profile_name_b64")"
    profile_source="$(b64_decode "$profile_source_b64")"
    [ "$first" -eq 1 ] || printf ','
    first=0
    is_active=false
    [ "$profile_id" = "${ACTIVE_PROFILE_ID:-}" ] && is_active=true
    is_enabled=false
    [ "$profile_enabled" = "1" ] && is_enabled=true
    is_subscription=false
    case "$profile_source" in http://*|https://*) is_subscription=true ;; esac
    printf '{"id":"%s","name":"%s","kind":"%s","host":"%s","source":"%s","subscription":%s,"enabled":%s,"active":%s}' \
      "$(json_escape "$profile_id")" "$(json_escape "$profile_name")" "$(json_escape "$(url_kind "$profile_url")")" \
      "$(json_escape "$(url_host "$profile_url")")" "$(json_escape "$profile_source")" "$is_subscription" "$is_enabled" "$is_active"
  done < "$LINKS_FILE"
}

api_print_subscriptions() {
  tmp_sources="$(mktemp)"
  while IFS='|' read -r _ _ _ _ source_b64; do
    [ -n "$source_b64" ] || continue
    source="$(b64_decode "$source_b64")"
    case "$source" in http://*|https://*) printf '%s\n' "$source_b64" ;; esac
  done < "$LINKS_FILE" | awk '!seen[$0]++' > "$tmp_sources"

  first=1
  while IFS= read -r source_b64; do
    [ -n "$source_b64" ] || continue
    source="$(b64_decode "$source_b64")"
    count="$(awk -F '|' -v wanted="$source_b64" '$5 == wanted { count++ } END { print count + 0 }' "$LINKS_FILE")"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"url":"%s","name":"%s","count":%s}' \
      "$(json_escape "$source")" "$(json_escape "$(url_host "$source")")" "$count"
  done < "$tmp_sources"
  rm -f "$tmp_sources"
}

api_print_bypass_items() {
  active_list="$1"
  disabled_list="$2"
  first=1
  for enabled_and_list in "1|$active_list" "0|$disabled_list"; do
    enabled="${enabled_and_list%%|*}"
    item_list="${enabled_and_list#*|}"
    old_ifs="${IFS:- }"
    IFS=','
    for item in $item_list; do
      [ -n "$item" ] || continue
      [ "$first" -eq 1 ] || printf ','
      first=0
      enabled_json=false
      [ "$enabled" = "1" ] && enabled_json=true
      printf '{"value":"%s","enabled":%s}' "$(json_escape "$item")" "$enabled_json"
    done
    IFS="$old_ifs"
  done
}

cmd_api_state() {
  load_state
  running=false
  pidof xray >/dev/null 2>&1 && running=true
  dns_running=false
  pidof https-dns-proxy >/dev/null 2>&1 && dns_running=true
  dns_fallback=false
  [ -f "$DNS_FALLBACK_FLAG" ] && dns_fallback=true
  dns_degraded=false
  xray_required_and_down=false
  if [ "${DNS_PROXY_ENABLED:-0}" = "1" ] && [ "$running" != "true" ]; then xray_required_and_down=true; fi
  if [ "${DNS_TUNNEL_ENABLED:-0}" = "1" ] && { [ -f "$DNS_DEGRADED_FLAG" ] || [ "$xray_required_and_down" = "true" ] || [ "$dns_running" != "true" ]; }; then dns_degraded=true; fi
  printf '{'
  printf '"service":{"running":%s},' "$running"
  printf '"current":{"summary":"%s","profileId":"%s"},' \
    "$(json_escape "$(describe_url "${CURRENT_URL:-}")")" "$(json_escape "${ACTIVE_PROFILE_ID:-}")"
  printf '"settings":{"lanIface":"%s","tproxyPort":%s,"localSocksListen":"%s","localSocksPort":%s},' \
    "$(json_escape "${LAN_IFACE:-$DEFAULT_LAN_IFACE}")" "${TPROXY_PORT:-$DEFAULT_TPROXY_PORT}" \
    "$(json_escape "${LOCAL_SOCKS_LISTEN:-$DEFAULT_LOCAL_SOCKS_LISTEN}")" "${LOCAL_SOCKS_PORT:-$DEFAULT_LOCAL_SOCKS_PORT}"
  printf '"dns":{"enabled":%s,"url":"%s","listenPort":%s,"failMode":"%s","proxyEnabled":%s,"running":%s,"fallback":%s,"degraded":%s},' \
    "$([ "${DNS_TUNNEL_ENABLED:-0}" = "1" ] && echo true || echo false)" \
    "$(json_escape "${DNS_DOH_URL:-$DEFAULT_DNS_DOH_URL}")" "${DNS_LISTEN_PORT:-$DEFAULT_DNS_LISTEN_PORT}" \
    "$(json_escape "${DNS_FAIL_MODE:-$DEFAULT_DNS_FAIL_MODE}")" \
    "$([ "${DNS_PROXY_ENABLED:-0}" = "1" ] && echo true || echo false)" "$dns_running" "$dns_fallback" "$dns_degraded"
  printf '"profiles":['
  api_print_profiles
  printf '],"subscriptions":['
  api_print_subscriptions
  printf '],"bypass":{"macs":['
  api_print_bypass_items "${BYPASS_MACS:-}" "${BYPASS_MACS_DISABLED:-}"
  printf '],"domains":['
  api_print_bypass_items "${BYPASS_RULES:-}" "${BYPASS_RULES_DISABLED:-}"
  printf ']}}\n'
}

cmd_migrate_state() {
  load_state
  [ -n "${CURRENT_URL:-}" ] || return 0
  if profile_url_exists "$CURRENT_URL"; then
    [ -n "${ACTIVE_PROFILE_ID:-}" ] || ACTIVE_PROFILE_ID="$(profile_id_for_url "$CURRENT_URL")"
  else
    profile_add_loaded "$CURRENT_URL" "" "migration"
    ACTIVE_PROFILE_ID="$PROFILE_RESULT_ID"
  fi
  save_state
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
        printf "Enter vless://, hysteria2://, socks:// or subscription URL: "
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
  use <vless://... | hysteria2://... | socks://... | https://subscription>  save and apply
  set <vless://... | hysteria2://... | socks://... | https://subscription>  save only
  add-link <url> [name]                                   add connection profile
  import-links <https://subscription>                     import all nodes as profiles
  refresh-links <https://subscription>                    refresh one profile subscription
  refresh-all-links                                       refresh all profile subscriptions
  list-links                                               list connection profiles
  select-link <id>                                         select profile
  use-link <id>                                            select profile and apply
  enable-link <id> | disable-link <id>
  del-link <id>
  del-subscription <https://subscription>                  remove a subscription and all of its profiles
  ping-link <id>                                           measure ICMP latency to a profile host
  check-link <url>                                         validate link syntax
  import <https://subscription>                            list nodes and save selection
  list-nodes                                               list subscription nodes
  select-node [number]                                     choose subscription node
  set-socks [host] [port]                                  use SOCKS upstream, defaults 127.0.0.1:1080
  use-socks [host] [port]                                  set SOCKS upstream and apply
  set-local-socks [listen] [port]                          local SOCKS listener, defaults 127.0.0.1:10818
  set-dns <0|1> [DoH URL] [port] [strict|fallback] [proxy:0|1]
  dns-test                                                 test a real answer through direct or proxied DoH
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
  enable-bypass-mac <mac> | disable-bypass-mac <mac>
  del-bypass-mac aa:bb:cc:dd:ee:ff
  list-bypass-mac
  add-bypass-rule <domain-rule>
  enable-bypass-rule <rule> | disable-bypass-rule <rule>
  del-bypass-rule <domain-rule>
  list-bypass-rules
EOS
}

cmd="${1:-menu}"
shift || true

case "$cmd" in
  use) cmd_use "${1:-}" ;;
  set) cmd_set "${1:-}" ;;
  add-link) cmd_add_link "${1:-}" "${2:-}" ;;
  import-links) cmd_import_links "${1:-}" ;;
  refresh-links) cmd_refresh_links "${1:-}" ;;
  refresh-all-links) cmd_refresh_all_links ;;
  list-links) cmd_list_links ;;
  select-link) cmd_select_link "${1:-}" ;;
  use-link) cmd_use_link "${1:-}" ;;
  enable-link) cmd_set_link_enabled "${1:-}" 1 ;;
  disable-link) cmd_set_link_enabled "${1:-}" 0 ;;
  del-link) cmd_del_link "${1:-}" ;;
  del-subscription) cmd_del_subscription "${1:-}" ;;
  ping-link) cmd_ping_link "${1:-}" ;;
  check-link) build_proxy_outbound_json "${1:-}" >/dev/null && echo "OK" ;;
  import) cmd_import "${1:-}" ;;
  list-nodes) cmd_list_nodes ;;
  select-node) cmd_select_node "${1:-}" ;;
  set-socks|set-upstream-socks) cmd_set_socks "${1:-}" "${2:-}" ;;
  use-socks|use-upstream-socks) cmd_use_socks "${1:-}" "${2:-}" ;;
  set-local-socks) cmd_set_local_socks "${1:-}" "${2:-}" ;;
  set-dns) cmd_set_dns "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  dns-test) cmd_dns_test ;;
  dns-watch) cmd_dns_watch ;;
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
  enable-bypass-mac) cmd_set_bypass_mac "${1:-}" 1 ;;
  disable-bypass-mac) cmd_set_bypass_mac "${1:-}" 0 ;;
  del-bypass-mac) del_mac "${1:-}" ;;
  list-bypass-mac) list_mac ;;
  add-bypass-rule) add_rule "${1:-}" ;;
  enable-bypass-rule) cmd_set_bypass_rule "${1:-}" 1 ;;
  disable-bypass-rule) cmd_set_bypass_rule "${1:-}" 0 ;;
  del-bypass-rule) del_rule "${1:-}" ;;
  list-bypass-rules) list_rules ;;
  api-state) cmd_api_state ;;
  migrate-state) cmd_migrate_state ;;
  migrate-dns-state) cmd_migrate_dns_state ;;
  apply-dns-state) cmd_apply_dns_state ;;
  menu) cmd_menu ;;
  help|-h|--help) cmd_help ;;
  *) fail "unknown command: $cmd. Run: xray-manager help" ;;
esac
EOF

  chmod 0755 /usr/bin/xray-manager
}

write_web_ui() {
  mkdir -p /www/xray-manager /www/cgi-bin

  cat > /www/cgi-bin/xray-manager <<'EOF'
#!/bin/sh

MANAGER="/usr/bin/xray-manager"
MAX_BODY=131072

json_escape() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

url_decode() {
  encoded="$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"
  printf '%b' "$encoded"
}

form_value() {
  key="$1"
  raw="$(printf '%s' "$BODY" | tr '&' '\n' | sed -n "s/^${key}=//p" | head -n 1)"
  [ -n "$raw" ] && url_decode "$raw" || true
}

send_json() {
  code="$1"
  payload="$2"
  printf 'Status: %s\r\n' "$code"
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n\r\n'
  printf '%s\n' "$payload"
  exit 0
}

run_manager() {
  LAST_OUTPUT="$($MANAGER "$@" 2>&1)"
  LAST_CODE=$?
}

if [ "${REQUEST_METHOD:-GET}" = "GET" ]; then
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n\r\n'
  exec "$MANAGER" api-state
fi

[ "${REQUEST_METHOD:-}" = "POST" ] || send_json "405 Method Not Allowed" '{"ok":false,"error":"method not allowed"}'
request_scheme="http"
[ "${HTTPS:-off}" = "on" ] && request_scheme="https"
expected_origin="${request_scheme}://${HTTP_HOST:-}"
[ -n "${HTTP_ORIGIN:-}" ] && [ "$HTTP_ORIGIN" = "$expected_origin" ] || send_json "403 Forbidden" '{"ok":false,"error":"request origin rejected"}'
CONTENT_LENGTH="${CONTENT_LENGTH:-0}"
case "$CONTENT_LENGTH" in ''|*[!0-9]*) CONTENT_LENGTH=0 ;; esac
[ "$CONTENT_LENGTH" -le "$MAX_BODY" ] || send_json "413 Payload Too Large" '{"ok":false,"error":"request is too large"}'
BODY="$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)"
action="$(form_value action)"

case "$action" in
  add_links)
    links="$(form_value links)"
    [ -n "$links" ] || send_json "400 Bad Request" '{"ok":false,"error":"Добавьте хотя бы одну ссылку"}'
    tmp_links="$(mktemp)"
    printf '%s\n' "$links" | tr -d '\r' > "$tmp_links"
    total=0
    errors=""
    while IFS= read -r link; do
      link="$(printf '%s' "$link" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$link" ] || continue
      case "$link" in
        http://*|https://*) run_manager import-links "$link" ;;
        *) run_manager add-link "$link" ;;
      esac
      if [ "$LAST_CODE" -eq 0 ]; then
        total=$((total + 1))
      else
        errors="${errors}${LAST_OUTPUT}; "
      fi
    done < "$tmp_links"
    rm -f "$tmp_links"
    [ -z "$errors" ] || send_json "400 Bad Request" "{\"ok\":false,\"error\":\"$(json_escape "$errors")\"}"
    send_json "200 OK" "{\"ok\":true,\"message\":\"Добавлено источников: ${total}\"}"
    ;;
  refresh_subscription)
    run_manager refresh-links "$(form_value source)"
    ;;
  refresh_all_subscriptions)
    run_manager refresh-all-links
    ;;
  select_profile)
    run_manager use-link "$(form_value id)"
    ;;
  delete_profile)
    run_manager del-link "$(form_value id)"
    ;;
  delete_subscription)
    run_manager del-subscription "$(form_value source)"
    ;;
  ping_profile)
    run_manager ping-link "$(form_value id)"
    ;;
  set_profile_enabled)
    id="$(form_value id)"
    enabled="$(form_value enabled)"
    if [ "$enabled" = "1" ]; then run_manager enable-link "$id"; else run_manager disable-link "$id"; fi
    ;;
  add_bypass)
    kind="$(form_value kind)"
    value="$(form_value value)"
    if [ "$kind" = "mac" ]; then run_manager add-bypass-mac "$value"; else run_manager add-bypass-rule "$value"; fi
    ;;
  delete_bypass)
    kind="$(form_value kind)"
    value="$(form_value value)"
    if [ "$kind" = "mac" ]; then run_manager del-bypass-mac "$value"; else run_manager del-bypass-rule "$value"; fi
    ;;
  set_bypass_enabled)
    kind="$(form_value kind)"
    value="$(form_value value)"
    enabled="$(form_value enabled)"
    if [ "$kind" = "mac" ]; then
      if [ "$enabled" = "1" ]; then run_manager enable-bypass-mac "$value"; else run_manager disable-bypass-mac "$value"; fi
    else
      if [ "$enabled" = "1" ]; then run_manager enable-bypass-rule "$value"; else run_manager disable-bypass-rule "$value"; fi
    fi
    ;;
  apply)
    run_manager apply
    ;;
  service)
    requested="$(form_value enabled)"
    if [ "$requested" = "1" ]; then run_manager on; else run_manager off; fi
    ;;
  save_settings)
    run_manager set-lan-iface "$(form_value lan_iface)"
    [ "$LAST_CODE" -eq 0 ] || true
    first_output="$LAST_OUTPUT"
    first_code="$LAST_CODE"
    if [ "$first_code" -eq 0 ]; then
      run_manager set-local-socks "$(form_value socks_listen)" "$(form_value socks_port)"
    fi
    [ "$first_code" -eq 0 ] || { LAST_CODE="$first_code"; LAST_OUTPUT="$first_output"; }
    ;;
  save_dns)
    run_manager set-dns "$(form_value enabled)" "$(form_value url)" "$(form_value port)" "$(form_value fail_mode)" "$(form_value proxy_enabled)"
    ;;
  test_dns)
    run_manager dns-test
    ;;
  *)
    send_json "400 Bad Request" '{"ok":false,"error":"unknown action"}'
    ;;
esac

if [ "${LAST_CODE:-1}" -eq 0 ]; then
  send_json "200 OK" "{\"ok\":true,\"message\":\"$(json_escape "${LAST_OUTPUT:-Готово}")\"}"
fi
send_json "400 Bad Request" "{\"ok\":false,\"error\":\"$(json_escape "${LAST_OUTPUT:-Ошибка}")\"}"
EOF
  chmod 0755 /www/cgi-bin/xray-manager

  cat > /www/xray-manager/index.html <<'EOF'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="color-scheme" content="dark">
  <title>Xray Manager</title>
  <link rel="stylesheet" href="./style.css?v=20260828-2">
</head>
<body>
  <div class="shell">
    <header class="topbar">
      <div class="brand">
        <div class="logo" aria-hidden="true">X</div>
        <div><strong>Xray Manager</strong><span>OpenWrt · TProxy</span></div>
      </div>
      <div class="status-wrap"><span id="statusDot" class="dot"></span><span id="serviceText">Проверка…</span><button id="serviceButton" class="button ghost small">—</button></div>
    </header>

    <main>
      <section class="hero">
        <div><p class="eyebrow">Активное подключение</p><h1 id="currentProfile">Не выбрано</h1><p id="currentSummary" class="muted">Добавьте ссылку или подписку</p></div>
        <button id="applyButton" class="button primary">Применить конфигурацию</button>
      </section>

      <nav class="tabs" aria-label="Разделы">
        <button class="tab active" data-tab="connections">Подключения</button>
        <button class="tab" data-tab="bypass">Обход</button>
        <button class="tab" data-tab="settings">Настройки</button>
      </nav>

      <section id="connections" class="panel active">
        <div class="section-head"><div><h2>Подключения</h2><p>VLESS, XHTTP, REALITY, Hysteria2 и gRPC</p></div><div class="section-actions"><button id="refreshAllSubscriptions" class="button ghost" hidden>↻ Обновить подписки</button><button id="openAddDialog" class="button primary">+ Добавить</button></div></div>
        <div id="profiles" class="list"></div>
        <div id="profilesEmpty" class="empty" hidden><div class="empty-icon">↗</div><h3>Пока нет подключений</h3><p>Вставьте одну или несколько ссылок либо URL подписки.</p></div>
      </section>

      <section id="bypass" class="panel">
        <div class="section-head"><div><h2>Обход прокси</h2><p>Отключённые правила сохраняются, но не попадают в конфигурацию</p></div></div>
        <div class="split">
          <div class="card">
            <div class="card-title"><div><h3>Устройства</h3><p>По MAC-адресу</p></div><span id="macCount" class="counter">0</span></div>
            <form class="inline-form" data-add-kind="mac"><input name="value" placeholder="aa:bb:cc:dd:ee:ff" autocomplete="off"><button class="button">Добавить</button></form>
            <div id="macList" class="rule-list"></div>
          </div>
          <div class="card">
            <div class="card-title"><div><h3>Домены</h3><p>Точные имена и суффиксы</p></div><span id="domainCount" class="counter">0</span></div>
            <form class="inline-form" data-add-kind="domain"><input name="value" placeholder="domain:example.com или .example.com" autocomplete="off"><button class="button">Добавить</button></form>
            <div id="domainList" class="rule-list"></div>
          </div>
        </div>
      </section>

      <section id="settings" class="panel">
        <div class="section-head"><div><h2>Настройки сети</h2><p>TProxy, локальный SOCKS и защищённый DNS</p></div></div>
        <form id="settingsForm" class="settings-grid card">
          <label><span>LAN интерфейс</span><input name="lan_iface" required></label>
          <label><span>TProxy порт</span><input name="tproxy_port" disabled><small>Меняется через консоль</small></label>
          <label><span>SOCKS listen</span><input name="socks_listen" required></label>
          <label><span>SOCKS порт</span><input name="socks_port" inputmode="numeric" required></label>
          <div class="settings-actions"><button class="button primary">Сохранить</button></div>
        </form>
        <form id="dnsForm" class="card dns-card">
          <div class="card-title dns-title"><div><h3>Защищённый DNS</h3><p>dnsmasq → DoH напрямую или через активный Xray</p></div><span id="dnsStatus" class="status-badge off">Выключено</span></div>
          <div class="dns-toggles">
            <label class="toggle-row"><span class="toggle-copy"><strong>Использовать DoH</strong><small>При выключении dnsmasq снова берёт DNS из WAN</small></span><span class="switch"><input name="enabled" type="checkbox"><span></span></span></label>
            <label class="toggle-row"><span class="toggle-copy"><strong>Через прокси</strong><small>DoH подключается через активный Xray; без этой опции — напрямую</small></span><span class="switch"><input name="proxy_enabled" type="checkbox"><span></span></span></label>
          </div>
          <div class="settings-grid dns-fields">
            <label><span>DoH URL</span><input name="url" type="url" required></label>
            <label><span>Локальный порт</span><input name="port" inputmode="numeric" required></label>
            <label class="wide"><span>Если DoH недоступен</span><select name="fail_mode"><option value="strict">Без утечек — DNS временно не работает</option><option value="fallback">Вернуть WAN DNS до восстановления</option></select><small id="dnsFailHint"></small></label>
            <div class="settings-actions"><button id="testDnsButton" type="button" class="button ghost">Проверить DNS</button><button class="button primary">Сохранить DNS</button></div>
          </div>
        </form>
      </section>
    </main>
  </div>

  <dialog id="addDialog">
    <form method="dialog" class="dialog-card" id="addLinksForm">
      <div class="dialog-head"><div><h2>Добавить подключения</h2><p>По одной ссылке на строку. URL подписки импортирует все ноды.</p></div><button value="cancel" formnovalidate class="icon-button" aria-label="Закрыть">×</button></div>
      <textarea name="links" rows="9" placeholder="vless://...&#10;hysteria2://...&#10;https://example.com/subscription" required></textarea>
      <div class="protocols"><span>VLESS</span><span>REALITY</span><span>XHTTP</span><span>gRPC</span><span>Hysteria2</span></div>
      <div class="dialog-actions"><button value="cancel" formnovalidate class="button ghost">Отмена</button><button id="addLinksButton" value="default" class="button primary">Добавить</button></div>
    </form>
  </dialog>

  <div id="toast" class="toast" role="status" aria-live="polite"></div>
  <script src="./app.js?v=20260828-3"></script>
</body>
</html>
EOF

  cat > /www/xray-manager/style.css <<'EOF'
:root{--bg:#0a0c10;--surface:#11151b;--surface-2:#171c24;--line:#252c36;--text:#f5f7fa;--muted:#8e99a8;--accent:#79f2c0;--accent-2:#48d6a0;--danger:#ff6b76;--warning:#ffc66d;--shadow:0 18px 70px rgba(0,0,0,.35)}*{box-sizing:border-box}html{background:var(--bg)}body{margin:0;min-height:100vh;background:radial-gradient(circle at 72% -10%,rgba(121,242,192,.09),transparent 33%),var(--bg);color:var(--text);font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}.shell{width:min(1120px,calc(100% - 32px));margin:auto}.topbar{height:76px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--line)}.brand,.status-wrap,.card-title,.section-head,.section-actions,.subscription-head{display:flex;align-items:center}.brand{gap:12px}.brand strong{display:block;font-size:15px}.brand span{display:block;color:var(--muted);font-size:12px}.logo{display:grid;place-items:center;width:34px;height:34px;border:1px solid rgba(121,242,192,.4);border-radius:10px;color:var(--accent);font-weight:800;background:rgba(121,242,192,.07)}.status-wrap,.section-actions{gap:9px}.status-wrap{color:var(--muted)}.dot{width:8px;height:8px;border-radius:50%;background:#66707c}.dot.on{background:var(--accent);box-shadow:0 0 0 5px rgba(121,242,192,.09)}main{padding:42px 0 64px}.hero{display:flex;align-items:flex-end;justify-content:space-between;gap:24px;padding:18px 0 36px}.eyebrow{text-transform:uppercase;letter-spacing:.14em;color:var(--accent);font-size:11px;font-weight:700;margin:0 0 9px}.hero h1{font-size:clamp(28px,5vw,48px);letter-spacing:-.04em;line-height:1.05;margin:0 0 9px;max-width:720px}.muted,.section-head p,.card-title p,.dialog-head p{color:var(--muted);margin:0}.tabs{display:flex;gap:24px;border-bottom:1px solid var(--line);margin-bottom:28px}.tab{appearance:none;border:0;border-bottom:2px solid transparent;background:none;color:var(--muted);padding:13px 2px;font:inherit;font-weight:600;cursor:pointer}.tab.active{color:var(--text);border-color:var(--accent)}.panel{display:none}.panel.active{display:block}.section-head{justify-content:space-between;gap:20px;margin-bottom:18px}.section-head h2,.dialog-head h2{font-size:20px;margin:0 0 2px}.button{appearance:none;border:1px solid var(--line);border-radius:10px;background:var(--surface-2);color:var(--text);padding:10px 15px;font:inherit;font-weight:650;cursor:pointer;transition:.18s ease}.button:hover{border-color:#3c4654;transform:translateY(-1px)}.button:disabled{opacity:.5;cursor:wait}.button.primary{background:var(--accent);border-color:var(--accent);color:#082117}.button.primary:hover{background:var(--accent-2)}.button.ghost{background:transparent}.button.small{padding:6px 10px;font-size:12px}.list{display:grid;gap:22px}.subscription-group{display:grid;gap:10px}.subscription-head{justify-content:space-between;gap:16px;padding:0 4px}.subscription-title{min-width:0}.subscription-title h3{margin:0;font-size:14px}.subscription-title p{margin:1px 0 0;color:var(--muted);font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:720px}.subscription-nodes{display:grid;gap:10px}.group-count{color:var(--muted);font-size:12px;margin-left:6px}.profile{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:16px;align-items:center;padding:17px 18px;background:linear-gradient(110deg,var(--surface),rgba(17,21,27,.72));border:1px solid var(--line);border-radius:14px}.profile.active{border-color:rgba(121,242,192,.48);box-shadow:inset 3px 0 var(--accent)}.profile.off{opacity:.58}.profile-main{display:flex;align-items:center;gap:14px;min-width:0}.protocol-icon{display:grid;place-items:center;flex:0 0 auto;width:42px;height:42px;border-radius:12px;background:#1d252d;color:var(--accent);font-weight:800;text-transform:uppercase}.profile h3{margin:0;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.meta{display:flex;gap:8px;align-items:center;color:var(--muted);font-size:12px}.badge{padding:2px 7px;border-radius:99px;background:rgba(121,242,192,.09);color:var(--accent);font-size:10px;text-transform:uppercase;letter-spacing:.08em}.profile-actions,.rule-actions{display:flex;align-items:center;gap:8px}.icon-button{appearance:none;border:0;background:transparent;color:var(--muted);font-size:22px;line-height:1;padding:6px;cursor:pointer}.icon-button.danger:hover{color:var(--danger)}.empty{text-align:center;padding:64px 20px;border:1px dashed var(--line);border-radius:16px;color:var(--muted)}.empty h3{color:var(--text);margin:12px 0 4px}.empty p{margin:0}.empty-icon{font-size:24px;color:var(--accent)}.split{display:grid;grid-template-columns:1fr 1fr;gap:16px}.card{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:20px}.card-title{justify-content:space-between;margin-bottom:16px}.card-title h3{margin:0;font-size:16px}.counter{display:grid;place-items:center;min-width:28px;height:28px;padding:0 8px;border-radius:99px;background:var(--surface-2);color:var(--muted)}.inline-form{display:flex;gap:8px;margin-bottom:15px}input,textarea,select{width:100%;border:1px solid var(--line);border-radius:10px;background:#0c1015;color:var(--text);padding:10px 12px;font:inherit;outline:0}input:focus,textarea:focus,select:focus{border-color:rgba(121,242,192,.65);box-shadow:0 0 0 3px rgba(121,242,192,.07)}input:disabled{opacity:.48}.rule-list{display:grid;gap:6px}.rule{display:flex;align-items:center;justify-content:space-between;gap:10px;min-height:42px;padding:7px 8px 7px 11px;border-radius:9px;background:var(--surface-2)}.rule.off .rule-value{text-decoration:line-through;color:var(--muted)}.rule-value{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12px}.switch{position:relative;width:36px;height:21px;flex:0 0 auto}.switch input{position:absolute;opacity:0}.switch span{position:absolute;inset:0;border-radius:99px;background:#303844;cursor:pointer}.switch span:after{content:"";position:absolute;width:15px;height:15px;left:3px;top:3px;border-radius:50%;background:#9ca5b1;transition:.18s}.switch input:checked+span{background:rgba(121,242,192,.25)}.switch input:checked+span:after{transform:translateX(15px);background:var(--accent)}.settings-grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}.settings-grid label span{display:block;font-weight:650;margin-bottom:7px}.settings-grid small,.toggle-row small{display:block;color:var(--muted);margin-top:5px}.settings-actions{grid-column:1/-1;display:flex;justify-content:flex-end;gap:8px}.dns-card{margin-top:16px}.dns-title{gap:16px}.dns-toggles{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin-bottom:18px}.dns-card .toggle-row{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:16px;min-width:0;padding:14px;border:1px solid var(--line);border-radius:12px;background:var(--surface-2);cursor:pointer}.toggle-copy{display:block;min-width:0}.toggle-copy strong,.toggle-copy small{display:block}.toggle-row>.switch{display:block}.dns-fields .wide{grid-column:1/-1}.status-badge{white-space:nowrap;padding:4px 9px;border-radius:99px;background:var(--surface-2);color:var(--muted);font-size:11px}.status-badge.on{background:rgba(121,242,192,.1);color:var(--accent)}.status-badge.warn{background:rgba(255,198,109,.1);color:var(--warning)}dialog{width:min(650px,calc(100% - 28px));padding:0;border:1px solid var(--line);border-radius:18px;background:var(--surface);color:var(--text);box-shadow:var(--shadow)}dialog::backdrop{background:rgba(3,5,8,.74);backdrop-filter:blur(5px)}.dialog-card{padding:24px}.dialog-head{display:flex;justify-content:space-between;gap:18px;margin-bottom:18px}.dialog-card textarea{resize:vertical;min-height:180px}.protocols{display:flex;flex-wrap:wrap;gap:6px;margin-top:12px}.protocols span{font-size:10px;color:var(--muted);border:1px solid var(--line);border-radius:99px;padding:3px 7px}.dialog-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:20px}.toast{position:fixed;right:24px;bottom:24px;max-width:min(420px,calc(100% - 48px));padding:12px 15px;border:1px solid var(--line);border-radius:11px;background:#1a2028;box-shadow:var(--shadow);opacity:0;transform:translateY(10px);pointer-events:none;transition:.2s}.toast.show{opacity:1;transform:none}.toast.error{border-color:rgba(255,107,118,.5);color:#ffb1b7}@media(max-width:760px){.shell{width:min(100% - 22px,1120px)}.topbar{height:66px}.status-wrap>#serviceText{display:none}main{padding-top:24px}.hero{align-items:flex-start;flex-direction:column}.hero .button{width:100%}.split,.settings-grid,.dns-toggles{grid-template-columns:1fr}.profile{grid-template-columns:1fr}.profile-actions{justify-content:flex-end}.section-head{align-items:flex-start}.section-actions{flex-wrap:wrap;justify-content:flex-end}.inline-form{flex-direction:column}.tabs{gap:16px;overflow:auto}.dns-fields .wide{grid-column:auto}}
.subscription-actions{display:flex;align-items:center;gap:8px}.button.danger{color:var(--danger)}.button.danger:hover{border-color:rgba(255,107,118,.55)}.ping-button{min-width:64px}
EOF

  cat > /www/xray-manager/app.js <<'EOF'
const api='/cgi-bin/xray-manager';
const $=(s,r=document)=>r.querySelector(s);
const $$=(s,r=document)=>[...r.querySelectorAll(s)];
let state=null, busy=false, toastTimer;
const pingResults=new Map();

function escapeHtml(value=''){return String(value).replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));}
function formatLatency(value){const milliseconds=Number(value);return Number.isFinite(milliseconds)?String(Math.round(milliseconds)):String(value);}
function toast(message,error=false){const el=$('#toast');el.textContent=message||'Готово';el.className='toast show'+(error?' error':'');clearTimeout(toastTimer);toastTimer=setTimeout(()=>el.className='toast',3600);}
async function request(action,data={}){if(busy)return;busy=true;document.body.classList.add('busy');try{const body=new URLSearchParams({action,...data});const response=await fetch(api,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body});const result=await response.json();if(!result.ok)throw new Error(result.error||'Ошибка');toast(result.message);await load();return result;}catch(error){toast(error.message,true);throw error;}finally{busy=false;document.body.classList.remove('busy');}}
async function pingProfile(id,button){if(busy)return;busy=true;document.body.classList.add('busy');const previous=button.textContent;button.disabled=true;button.textContent='…';try{const body=new URLSearchParams({action:'ping_profile',id});const response=await fetch(api,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body});const result=await response.json();if(!result.ok)throw new Error(result.error||'Нет ответа');const rawLatency=String(result.message||'').trim();if(!/^\d+(?:\.\d+)?$/.test(rawLatency))throw new Error('Некорректный ответ ping');const latency=formatLatency(rawLatency);pingResults.set(id,latency);button.textContent=`${latency} мс`;button.title='ICMP-задержка до сервера';}catch(error){pingResults.delete(id);button.textContent='Нет ответа';button.title=error.message;toast(error.message,true);}finally{busy=false;button.disabled=false;document.body.classList.remove('busy');if(button.textContent==='…')button.textContent=previous;}}
async function load(){try{const response=await fetch(api,{cache:'no-store'});state=await response.json();render();}catch(error){toast('Не удалось получить состояние: '+error.message,true);}}

function render(){
  const running=state.service.running;$('#statusDot').classList.toggle('on',running);$('#serviceText').textContent=running?'Xray работает':'Xray остановлен';$('#serviceButton').textContent=running?'Остановить':'Запустить';$('#serviceButton').dataset.enabled=running?'0':'1';
  const active=state.profiles.find(p=>p.active);$('#currentProfile').textContent=active?active.name:'Не выбрано';$('#currentSummary').textContent=state.current.summary||'Добавьте ссылку или подписку';
  const subscriptions=state.subscriptions||[];const manual=state.profiles.filter(profile=>!profile.subscription);const groups=[];
  if(manual.length)groups.push(renderProfileGroup('Добавленные вручную','Отдельные подключения',manual));
  subscriptions.forEach(subscription=>{const profiles=state.profiles.filter(profile=>profile.source===subscription.url);if(profiles.length)groups.push(renderProfileGroup(subscription.name,'Подписка',profiles,subscription.url));});
  const container=$('#profiles');container.innerHTML=groups.join('');
  $('#refreshAllSubscriptions').hidden=subscriptions.length===0;
  $('#profilesEmpty').hidden=state.profiles.length>0;
  renderRules('mac',state.bypass.macs,$('#macList'));renderRules('domain',state.bypass.domains,$('#domainList'));$('#macCount').textContent=state.bypass.macs.length;$('#domainCount').textContent=state.bypass.domains.length;
  const form=$('#settingsForm');form.lan_iface.value=state.settings.lanIface;form.tproxy_port.value=state.settings.tproxyPort;form.socks_listen.value=state.settings.localSocksListen;form.socks_port.value=state.settings.localSocksPort;
  const dnsForm=$('#dnsForm');dnsForm.enabled.checked=state.dns.enabled;dnsForm.proxy_enabled.checked=state.dns.proxyEnabled;dnsForm.url.value=state.dns.url;dnsForm.port.value=state.dns.listenPort;dnsForm.fail_mode.value=state.dns.failMode;
  const dnsStatus=$('#dnsStatus');dnsStatus.className='status-badge '+(!state.dns.enabled?'off':state.dns.fallback||state.dns.degraded?'warn':'on');dnsStatus.textContent=!state.dns.enabled?'WAN DNS':state.dns.fallback?'Резервный WAN DNS':state.dns.degraded?'DNS недоступен':state.dns.proxyEnabled?'DoH через Xray':'DoH напрямую';
  $('#dnsFailHint').textContent=state.dns.failMode==='fallback'?'При аварии DNS временно станет виден провайдеру. Watchdog вернёт DoH после восстановления.':'При аварии утечки не будет, но новые имена перестанут открываться до восстановления Xray.';
}
function renderProfile(profile){const latency=pingResults.get(profile.id);return `<article class="profile ${profile.active?'active':''} ${profile.enabled?'':'off'}"><div class="profile-main"><div class="protocol-icon">${escapeHtml(profile.kind.slice(0,2))}</div><div style="min-width:0"><h3>${escapeHtml(profile.name)}</h3><div class="meta"><span class="badge">${escapeHtml(profile.kind)}</span><span>${escapeHtml(profile.host)}</span>${profile.active?'<span>· активно</span>':''}</div></div></div><div class="profile-actions"><button class="button ghost small ping-button" data-ping-profile="${escapeHtml(profile.id)}" title="Проверить ICMP-задержку">${latency?`${escapeHtml(latency)} мс`:'Пинг'}</button><label class="switch" title="Включить профиль"><input type="checkbox" data-profile-toggle="${escapeHtml(profile.id)}" ${profile.enabled?'checked':''}><span></span></label><button class="button small" data-select="${escapeHtml(profile.id)}" ${!profile.enabled||profile.active?'disabled':''}>Выбрать</button><button class="icon-button danger" data-delete-profile="${escapeHtml(profile.id)}" title="Удалить">×</button></div></article>`;}
function renderProfileGroup(title,subtitle,profiles,source=''){return `<section class="subscription-group"><div class="subscription-head"><div class="subscription-title"><h3>${escapeHtml(title)} <span class="group-count">${profiles.length}</span></h3><p title="${escapeHtml(subtitle)}">${escapeHtml(subtitle)}</p></div>${source?`<div class="subscription-actions"><button class="button ghost small" data-refresh-subscription="${escapeHtml(source)}">↻ Обновить</button><button class="button ghost small danger" data-delete-subscription="${escapeHtml(source)}" data-subscription-count="${profiles.length}">Удалить</button></div>`:''}</div><div class="subscription-nodes">${profiles.map(renderProfile).join('')}</div></section>`;}
function renderRules(kind,items,container){container.innerHTML=items.length?items.map(item=>`<div class="rule ${item.enabled?'':'off'}"><span class="rule-value">${escapeHtml(item.value)}</span><span class="rule-actions"><label class="switch"><input type="checkbox" data-rule-toggle="${escapeHtml(kind)}" data-value="${escapeHtml(item.value)}" ${item.enabled?'checked':''}><span></span></label><button class="icon-button danger" data-rule-delete="${escapeHtml(kind)}" data-value="${escapeHtml(item.value)}" title="Удалить">×</button></span></div>`).join(''):'<div class="muted" style="padding:10px 2px">Список пуст</div>';}

$$('.tab').forEach(tab=>tab.addEventListener('click',()=>{$$('.tab').forEach(x=>x.classList.toggle('active',x===tab));$$('.panel').forEach(panel=>panel.classList.toggle('active',panel.id===tab.dataset.tab));}));
$('#openAddDialog').addEventListener('click',()=>$('#addDialog').showModal());
$('#addLinksForm').addEventListener('submit',async event=>{if(event.submitter?.value==='cancel')return;event.preventDefault();const form=event.currentTarget;try{await request('add_links',{links:form.links.value});form.reset();$('#addDialog').close();}catch{}});
$('#applyButton').addEventListener('click',()=>request('apply'));
$('#serviceButton').addEventListener('click',event=>{const enabling=event.currentTarget.dataset.enabled==='1';if(!enabling&&state.dns.enabled&&state.dns.proxyEnabled&&state.dns.failMode==='strict'&&!confirm('DNS настроен через Xray: после его остановки DNS перестанет отвечать. Остановить?'))return;request('service',{enabled:enabling?'1':'0'});});
$('#refreshAllSubscriptions').addEventListener('click',()=>request('refresh_all_subscriptions'));
$('#profiles').addEventListener('click',event=>{const select=event.target.closest('[data-select]');const del=event.target.closest('[data-delete-profile]');const ping=event.target.closest('[data-ping-profile]');const refresh=event.target.closest('[data-refresh-subscription]');const delSubscription=event.target.closest('[data-delete-subscription]');if(select)request('select_profile',{id:select.dataset.select});if(del&&confirm('Удалить это подключение?'))request('delete_profile',{id:del.dataset.deleteProfile});if(ping)pingProfile(ping.dataset.pingProfile,ping);if(refresh)request('refresh_subscription',{source:refresh.dataset.refreshSubscription});if(delSubscription&&confirm(`Удалить подписку и все её подключения (${delSubscription.dataset.subscriptionCount})?`))request('delete_subscription',{source:delSubscription.dataset.deleteSubscription});});
$('#profiles').addEventListener('change',event=>{const input=event.target.closest('[data-profile-toggle]');if(input)request('set_profile_enabled',{id:input.dataset.profileToggle,enabled:input.checked?'1':'0'}).catch(()=>load());});
$$('[data-add-kind]').forEach(form=>form.addEventListener('submit',async event=>{event.preventDefault();const value=form.value.value.trim();if(!value)return;try{await request('add_bypass',{kind:form.dataset.addKind,value});form.reset();}catch{}}));
$('#bypass').addEventListener('change',event=>{const input=event.target.closest('[data-rule-toggle]');if(input)request('set_bypass_enabled',{kind:input.dataset.ruleToggle,value:input.dataset.value,enabled:input.checked?'1':'0'}).catch(()=>load());});
$('#bypass').addEventListener('click',event=>{const button=event.target.closest('[data-rule-delete]');if(button&&confirm('Удалить правило?'))request('delete_bypass',{kind:button.dataset.ruleDelete,value:button.dataset.value});});
$('#settingsForm').addEventListener('submit',async event=>{event.preventDefault();const form=event.currentTarget;await request('save_settings',{lan_iface:form.lan_iface.value,socks_listen:form.socks_listen.value,socks_port:form.socks_port.value});});
$('#dnsForm').addEventListener('submit',async event=>{event.preventDefault();const form=event.currentTarget;try{await request('save_dns',{enabled:form.enabled.checked?'1':'0',proxy_enabled:form.proxy_enabled.checked?'1':'0',url:form.url.value,port:form.port.value,fail_mode:form.fail_mode.value});}catch{await load();}});
$('#dnsForm').fail_mode.addEventListener('change',event=>{$('#dnsFailHint').textContent=event.currentTarget.value==='fallback'?'При аварии DNS временно станет виден провайдеру. Watchdog вернёт DoH после восстановления.':'При аварии утечки не будет, но новые имена перестанут открываться до восстановления Xray.';});
$('#testDnsButton').addEventListener('click',()=>request('test_dns'));
load();
EOF

  touch /etc/httpd.conf
  grep -qF '/xray-manager:root:$p$root' /etc/httpd.conf || echo '/xray-manager:root:$p$root' >> /etc/httpd.conf
  grep -qF '/cgi-bin/xray-manager:root:$p$root' /etc/httpd.conf || echo '/cgi-bin/xray-manager:root:$p$root' >> /etc/httpd.conf
  /etc/init.d/uhttpd enable
  /etc/init.d/uhttpd restart
}

main() {
  need_root
  ensure_dirs
  write_state_defaults
  install_packages
  install_xray_core
  write_init_scripts
  write_manager
  /usr/bin/xray-manager migrate-state
  write_web_ui

  /etc/init.d/xray enable
  /etc/init.d/xray-tproxy enable

  # Bring Xray up before restoring an optional proxied DoH setup. Otherwise
  # its health check necessarily fails and can leave dnsmasq pointing at a
  # dead local resolver after an interrupted upgrade.
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  if [ -n "${CURRENT_URL:-}" ]; then
    /usr/bin/xray-manager apply
  fi

  /usr/bin/xray-manager migrate-dns-state
  if /usr/bin/xray-manager show | grep -q '^DNS_TUNNEL_ENABLED=1$'; then
    /usr/bin/xray-manager apply-dns-state
  else
    /etc/init.d/https-dns-proxy stop >/dev/null 2>&1 || true
    /etc/init.d/https-dns-proxy disable >/dev/null 2>&1 || true
  fi

  echo
  echo "Installed."
  echo
  echo "Quick commands:"
  echo "  xray-manager menu"
  echo "  xray-manager use 'vless://...'"
  echo "  xray-manager use 'https://example.com/subscription'"
  echo "  xray-manager use-socks"
  echo "  xray-manager set-dns 1 'https://dns.google/dns-query' 5053 strict 0"
  echo "  xray-manager select-node"
  echo "  xray-manager test"
  echo "  Web UI: http://$(uci -q get network.lan.ipaddr || echo 192.168.1.1)/xray-manager/"
}

main "$@"

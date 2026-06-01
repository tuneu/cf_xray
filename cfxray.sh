#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${CXN_CONFIG_DIR:-/usr/local/etc/xray}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_DIR="${CONFIG_DIR}/certs"
XRAY_LOG_DIR="${CXN_XRAY_LOG_DIR:-/var/log/xray}"
STATE_DIR="${CXN_STATE_DIR:-/etc/cloudflare-xray-node}"
STATE_FILE="${STATE_DIR}/state.json"
LINKS_FILE="${CXN_LINKS_FILE:-/root/xray-node-links.txt}"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
XRAY_CORE_LATEST_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_CORE_RELEASES_URL="https://github.com/XTLS/Xray-core/releases"
XRAY_DAT_DIR="${CXN_XRAY_DAT_DIR:-/usr/local/share/xray}"
XRAY_GEOIP_LATEST_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
XRAY_GEOSITE_LATEST_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
XRAY_SERVICE_NAME="${CXN_XRAY_SERVICE_NAME:-xray}"
DEFAULT_WS_CLIENT_ADDR="${CXN_DEFAULT_WS_CLIENT_ADDR:-www.wto.org}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
cyan='\033[0;36m'
bold='\033[1m'
dim='\033[2m'
plain='\033[0m'

tmp_dir=""
xray_bin=""
uuid=""
ws_domain=""
ws_cert_file=""
ws_key_file=""
ws_client_addr=""
ws_client_port=443
show_qr_in_links=1
vless_ws_enabled=0
vmess_ws_enabled=0
vless_xhttp_enabled=0
reality_enabled=0

vless_ws_port=8443
vless_ws_public_port=""
vless_ws_path=""
vless_ws_host=""
vless_ws_tag=""

vmess_ws_port=2096
vmess_ws_public_port=""
vmess_ws_path=""
vmess_ws_host=""
vmess_ws_tag=""

vless_xhttp_port=2083
vless_xhttp_public_port=""
vless_xhttp_path=""
vless_xhttp_host=""
vless_xhttp_tag=""

reality_port=443
reality_addr=""
reality_target="apple.com"
reality_target_port=443
reality_private_key=""
reality_public_key=""
reality_short_id=""
reality_fingerprint="chrome"
reality_spider_x="/"
reality_tag=""

xray_update_checked=0
xray_current_version_cache=""
xray_latest_version_cache=""
xray_update_state_cache=""

CLOUDFLARE_WS_TLS_PORTS="443 8443 2053 2083 2087 2096"
UI_LINE="----------------------------------------------------------------------"

ui_line() {
  printf '%b%s%b\n' "${dim}" "${UI_LINE}" "${plain}"
}

ui_title() {
  local title="$1"
  local subtitle="${2:-}"

  echo
  ui_line
  printf '%b%s%b\n' "${bold}${cyan}" "${title}" "${plain}"
  if [[ -n "${subtitle}" ]]; then
    printf '%b%s%b\n' "${dim}" "${subtitle}" "${plain}"
  fi
  ui_line
}

ui_section() {
  echo
  printf '%b== %s ==%b\n' "${bold}${cyan}" "$*" "${plain}"
}

ui_group() {
  printf '%b-- %s --%b\n' "${cyan}" "$*" "${plain}"
}

ui_kv() {
  local key="$1"
  local value="$2"

  printf '  %b%-16s%b %s\n' "${cyan}" "${key}:" "${plain}" "${value}"
}

ui_option() {
  local number="$1"
  local label="$2"
  local detail="${3:-}"

  if [[ -n "${detail}" ]]; then
    printf '  %b%2s%b) %-22s %b%s%b\n' "${yellow}" "${number}" "${plain}" "${label}" "${dim}" "${detail}" "${plain}"
  else
    printf '  %b%2s%b) %s\n' "${yellow}" "${number}" "${plain}" "${label}"
  fi
}

ui_note() {
  printf '  %b%s%b\n' "${dim}" "$*" "${plain}"
}

ui_clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033[H\033[2J\033[3J'
  fi
}

pause_for_enter() {
  local message="${1:-按 Enter 返回主菜单}"
  local _

  echo
  read -r -p "$(printf '%b%s%b' "${cyan}" "${message}" "${plain}")" _ || true
}

run_menu_action() {
  "$@"
  pause_for_enter
  ui_clear_screen
}

log() {
  printf '%b[INFO]%b %s\n' "${blue}" "${plain}" "$*" >&2
}

warn() {
  printf '%b[WARN]%b %s\n' "${yellow}" "${plain}" "$*" >&2
}

err() {
  printf '%b[ERR]%b %s\n' "${red}" "${plain}" "$*" >&2
}

die() {
  err "$*"
  exit 1
}

cleanup() {
  if [[ -n "${tmp_dir}" && -d "${tmp_dir}" ]]; then
    rm -rf "${tmp_dir}"
  fi
}
trap cleanup EXIT

prompt() {
  local message="$1"
  local default="${2:-}"
  local value
  local prompt_text

  if [[ -n "${default}" ]]; then
    prompt_text="$(printf '%b%s%b %b[%s]%b: ' "${cyan}" "${message}" "${plain}" "${dim}" "${default}" "${plain}")"
    read -r -p "${prompt_text}" value
    printf '%s' "${value:-$default}"
  else
    prompt_text="$(printf '%b%s%b: ' "${cyan}" "${message}" "${plain}")"
    read -r -p "${prompt_text}" value
    printf '%s' "${value}"
  fi
}

confirm() {
  local message="$1"
  local default="${2:-y}"
  local suffix="[Y/n]"
  local value
  local prompt_text

  [[ "${default}" == "n" ]] && suffix="[y/N]"
  prompt_text="$(printf '%b%s%b %b%s%b: ' "${cyan}" "${message}" "${plain}" "${dim}" "${suffix}" "${plain}")"
  read -r -p "${prompt_text}" value
  value="${value:-$default}"
  [[ "${value}" =~ ^[Yy]$ ]]
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行此脚本。"
}

desired_xray_install_user() {
  printf '%s' "${CXN_XRAY_INSTALL_USER:-root}"
}

effective_xray_service_user() {
  local user=""

  if [[ -n "${CXN_EFFECTIVE_XRAY_USER:-}" ]]; then
    printf '%s' "${CXN_EFFECTIVE_XRAY_USER}"
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    user="$(systemctl show -p User --value "${XRAY_SERVICE_NAME}" 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -z "${user}" ]]; then
    user="$(desired_xray_install_user)"
  fi

  printf '%s' "${user:-root}"
}

effective_xray_service_group() {
  local user="$1"

  if [[ -n "${CXN_EFFECTIVE_XRAY_GROUP:-}" ]]; then
    printf '%s' "${CXN_EFFECTIVE_XRAY_GROUP}"
    return
  fi

  if id -gn "${user}" >/dev/null 2>&1; then
    id -gn "${user}"
    return
  fi

  printf '%s' "${user:-root}"
}

check_system() {
  local version_major

  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，暂不支持当前系统。"
  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      die "当前仅支持 Debian/Ubuntu，检测到系统 ID: ${ID:-unknown}"
      ;;
  esac

  version_major="${VERSION_ID:-0}"
  version_major="${version_major%%.*}"
  if [[ "${ID}" == "debian" ]] && (( version_major < 10 )); then
    die "当前仅支持 Debian 10+，检测到版本：${VERSION_ID:-unknown}"
  fi
  if [[ "${ID}" == "ubuntu" ]] && (( version_major < 20 )); then
    die "当前仅支持 Ubuntu 20.04+，检测到版本：${VERSION_ID:-unknown}"
  fi

  command -v systemctl >/dev/null 2>&1 || die "当前脚本需要 systemd/systemctl。"
}

install_dependencies() {
  log "安装基础依赖..."
  apt-get update
  apt-get install -y curl wget jq qrencode ca-certificates openssl lsof iproute2 coreutils unzip
}

download_with_fallback() {
  local url="$1"
  local output="$2"

  if curl -fL --connect-timeout 5 --max-time 600 --retry 3 --retry-delay 2 -o "${output}" "${url}" >/dev/null 2>&1; then
    return 0
  fi

  wget -q --tries=3 --timeout=20 -O "${output}" "${url}"
}

xray_release_arch() {
  case "$(uname -m)" in
    i386|i686)
      printf '%s\n' "32"
      ;;
    amd64|x86_64)
      printf '%s\n' "64"
      ;;
    armv5tel)
      printf '%s\n' "arm32-v5"
      ;;
    armv6l)
      printf '%s\n' "arm32-v6"
      ;;
    armv7|armv7l)
      printf '%s\n' "arm32-v7a"
      ;;
    armv8|aarch64|arm64)
      printf '%s\n' "arm64-v8a"
      ;;
    mips)
      printf '%s\n' "mips32"
      ;;
    mipsle)
      printf '%s\n' "mips32le"
      ;;
    mips64)
      printf '%s\n' "mips64"
      ;;
    mips64le)
      printf '%s\n' "mips64le"
      ;;
    ppc64)
      printf '%s\n' "ppc64"
      ;;
    ppc64le)
      printf '%s\n' "ppc64le"
      ;;
    riscv64)
      printf '%s\n' "riscv64"
      ;;
    s390x)
      printf '%s\n' "s390x"
      ;;
    *)
      return 1
      ;;
  esac
}

xray_release_archive_name() {
  local arch

  arch="$(xray_release_arch)" || return 1
  printf '%s\n' "Xray-linux-${arch}.zip"
}

xray_release_download_url() {
  local version="${1:-}"
  local archive_name

  archive_name="$(xray_release_archive_name)" || return 1

  if [[ -n "${version}" ]]; then
    printf '%s/download/%s/%s\n' "${XRAY_CORE_RELEASES_URL}" "${version}" "${archive_name}"
  else
    printf '%s/latest/download/%s\n' "${XRAY_CORE_RELEASES_URL}" "${archive_name}"
  fi
}

xray_latest_version_from_redirect() {
  local download_url
  local location
  local version

  download_url="$(xray_release_download_url "")" || return 1
  location="$(curl -fsSI --connect-timeout 3 --max-time 8 "${download_url}" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}' | tail -n 1)"
  [[ -n "${location}" ]] || return 1

  version="$(sed -n 's#.*releases/download/\(v[^/]*\)/.*#\1#p' <<<"${location}" | head -n 1)"
  [[ -n "${version}" ]] || return 1
  printf '%s\n' "${version}"
}

resolve_xray_install_user() {
  local install_user

  install_user="$(desired_xray_install_user)"
  if ! id -u "${install_user}" >/dev/null 2>&1; then
    warn "Xray 安装用户 ${install_user} 不存在，回退使用 root。"
    install_user="root"
  fi

  printf '%s\n' "${install_user}"
}

install_xray_service_files() {
  local install_user="$1"
  local install_uid
  local capability_bounding_set="CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE"
  local ambient_capabilities="AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE"
  local no_new_privileges="NoNewPrivileges=true"

  install_uid="$(id -u "${install_user}" 2>/dev/null || printf '0')"
  if [[ "${install_uid}" == "0" ]]; then
    capability_bounding_set="#${capability_bounding_set}"
    ambient_capabilities="#${ambient_capabilities}"
    no_new_privileges="#${no_new_privileges}"
  fi

  cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=${install_user}
${capability_bounding_set}
${ambient_capabilities}
${no_new_privileges}
ExecStart=/usr/local/bin/xray run -config ${CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/xray@.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=${install_user}
${capability_bounding_set}
${ambient_capabilities}
${no_new_privileges}
ExecStart=/usr/local/bin/xray run -config ${CONFIG_DIR}/%i.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray-%i
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  systemctl daemon-reload
}

install_xray_geodata_direct() {
  local work_dir
  local geoip_tmp
  local geosite_tmp

  work_dir="$(mktemp -d)"
  geoip_tmp="${work_dir}/geoip.dat"
  geosite_tmp="${work_dir}/geosite.dat"

  if ! download_with_fallback "${XRAY_GEOIP_LATEST_URL}" "${geoip_tmp}"; then
    rm -rf "${work_dir}"
    return 1
  fi

  if ! download_with_fallback "${XRAY_GEOSITE_LATEST_URL}" "${geosite_tmp}"; then
    rm -rf "${work_dir}"
    return 1
  fi

  install -d "${XRAY_DAT_DIR}"
  install -m 644 "${geoip_tmp}" "${XRAY_DAT_DIR}/geoip.dat"
  install -m 644 "${geosite_tmp}" "${XRAY_DAT_DIR}/geosite.dat"
  rm -rf "${work_dir}"
}

install_xray_direct() {
  local install_user="$1"
  local version=""
  local download_url
  local archive_name
  local work_dir
  local archive_path
  local extract_dir
  local service_group
  local access_log
  local error_log

  archive_name="$(xray_release_archive_name)" || die "当前架构 $(uname -m) 暂不支持自动安装 Xray。"
  work_dir="$(mktemp -d)"
  archive_path="${work_dir}/${archive_name}"
  extract_dir="${work_dir}/extract"
  mkdir -p "${extract_dir}"

  version="$(xray_latest_version 2>/dev/null || true)"
  download_url="$(xray_release_download_url "${version}")" || {
    rm -rf "${work_dir}"
    die "无法生成 Xray 下载地址。"
  }

  if ! download_with_fallback "${download_url}" "${archive_path}"; then
    if [[ -n "${version}" ]]; then
      warn "按版本 ${version} 下载 Xray 失败，尝试 latest/download 直链。"
      download_url="$(xray_release_download_url "")" || true
      if [[ -z "${download_url}" ]] || ! download_with_fallback "${download_url}" "${archive_path}"; then
        rm -rf "${work_dir}"
        die "通过 release 直链下载 Xray 失败，请检查服务器到 github.com 的连通性。"
      fi
    else
      rm -rf "${work_dir}"
      die "通过 release 直链下载 Xray 失败，请检查服务器到 github.com 的连通性。"
    fi
  fi

  unzip -qo "${archive_path}" -d "${extract_dir}" || {
    rm -rf "${work_dir}"
    die "解压 Xray 安装包失败：${archive_name}"
  }

  [[ -x "${extract_dir}/xray" ]] || {
    rm -rf "${work_dir}"
    die "安装包中未找到 xray 可执行文件。"
  }

  install -d "${CONFIG_DIR}" "${CERT_DIR}" "${XRAY_DAT_DIR}" "${XRAY_LOG_DIR}"
  install -m 755 "${extract_dir}/xray" /usr/local/bin/xray

  if ! install_xray_geodata_direct; then
    if [[ -f "${extract_dir}/geoip.dat" && -f "${extract_dir}/geosite.dat" ]]; then
      warn "独立下载 geodata 失败，回退使用 Xray 压缩包内置 geodata。"
      install -m 644 "${extract_dir}/geoip.dat" "${XRAY_DAT_DIR}/geoip.dat"
      install -m 644 "${extract_dir}/geosite.dat" "${XRAY_DAT_DIR}/geosite.dat"
    else
      rm -rf "${work_dir}"
      die "无法安装 geodata，且压缩包内未包含 geoip.dat/geosite.dat。"
    fi
  fi

  [[ -f "${CONFIG_FILE}" ]] || printf '{}\n' >"${CONFIG_FILE}"
  access_log="${XRAY_LOG_DIR}/access.log"
  error_log="${XRAY_LOG_DIR}/error.log"
  touch "${access_log}" "${error_log}"

  install_xray_service_files "${install_user}"

  service_group="$(effective_xray_service_group "${install_user}")"
  apply_runtime_ownership "${CONFIG_DIR}" 750 "${install_user}" "${service_group}"
  apply_runtime_ownership "${CONFIG_FILE}" 640 "${install_user}" "${service_group}"
  apply_runtime_ownership "${CERT_DIR}" 750 "${install_user}" "${service_group}"
  apply_runtime_ownership "${XRAY_LOG_DIR}" 750 "${install_user}" "${service_group}"
  apply_runtime_ownership "${access_log}" 640 "${install_user}" "${service_group}"
  apply_runtime_ownership "${error_log}" 640 "${install_user}" "${service_group}"
  apply_runtime_ownership "${XRAY_DAT_DIR}" 755 "${install_user}" "${service_group}"
  apply_runtime_ownership "${XRAY_DAT_DIR}/geoip.dat" 644 "${install_user}" "${service_group}"
  apply_runtime_ownership "${XRAY_DAT_DIR}/geosite.dat" 644 "${install_user}" "${service_group}"

  rm -rf "${work_dir}"
}

install_xray_via_official_script() {
  local install_user="$1"
  local script_body=""

  script_body="$(curl -fsSL --connect-timeout 5 --max-time 30 "${XRAY_INSTALL_URL}" 2>/dev/null || true)"
  [[ -n "${script_body}" ]] || return 1

  bash -c "${script_body}" @ install -u "${install_user}" || return 1
  if ! bash -c "${script_body}" @ install-geodata; then
    warn "官方 geodata 安装失败，尝试直链更新 geodata。"
    install_xray_geodata_direct || return 1
  fi
}

install_xray() {
  local install_user

  log "安装或更新 Xray 最新稳定版..."
  install_user="$(resolve_xray_install_user)"

  if ! install_xray_via_official_script "${install_user}"; then
    warn "官方安装链路不可用，改为直链安装 Xray Core。"
    install_xray_direct "${install_user}"
  fi

  resolve_xray_bin

  mkdir -p "${CONFIG_DIR}" "${CERT_DIR}"
  xray_update_checked=0
}

find_xray_bin() {
  if command -v xray >/dev/null 2>&1; then
    command -v xray
  elif [[ -x /usr/local/bin/xray ]]; then
    printf '%s\n' "/usr/local/bin/xray"
  else
    return 1
  fi
}

resolve_xray_bin() {
  if ! xray_bin="$(find_xray_bin)"; then
    die "未找到 xray 可执行文件，请先运行 install 或确认 Xray 已安装。"
  fi
}

xray_current_version() {
  local bin
  local raw
  local version

  bin="$(find_xray_bin)" || return 1
  raw="$("${bin}" version 2>/dev/null | head -n 1 || true)"
  if [[ -z "${raw}" ]]; then
    raw="$("${bin}" --version 2>/dev/null | head -n 1 || true)"
  fi
  version="$(awk '{print $2}' <<<"${raw}")"
  [[ -n "${version}" ]] || return 1
  [[ "${version}" == v* ]] || version="v${version}"
  printf '%s\n' "${version}"
}

xray_latest_version() {
  local response
  local version

  command -v curl >/dev/null 2>&1 || return 1
  response="$(curl -fsSL --connect-timeout 3 --max-time 8 "${XRAY_CORE_LATEST_API}" 2>/dev/null || true)"
  [[ -n "${response}" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    version="$(jq -r '.tag_name // empty' <<<"${response}" 2>/dev/null || true)"
  else
    version="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"${response}" | head -n 1)"
  fi

  if [[ -n "${version}" && "${version}" != "null" ]]; then
    printf '%s\n' "${version}"
    return 0
  fi

  xray_latest_version_from_redirect
}

normalize_xray_version() {
  local version="$1"
  version="${version#v}"
  printf '%s\n' "${version}"
}

refresh_xray_update_check() {
  local current
  local latest

  current="$(xray_current_version 2>/dev/null || true)"
  latest="$(xray_latest_version 2>/dev/null || true)"

  xray_update_checked=1
  xray_current_version_cache="${current}"
  xray_latest_version_cache="${latest}"

  if [[ -z "${current}" ]]; then
    xray_update_state_cache="not-installed"
  elif [[ -z "${latest}" ]]; then
    xray_update_state_cache="unknown"
  elif [[ "$(normalize_xray_version "${current}")" == "$(normalize_xray_version "${latest}")" ]]; then
    xray_update_state_cache="latest"
  else
    xray_update_state_cache="available"
  fi
}

ensure_xray_update_check() {
  if (( ! xray_update_checked )); then
    refresh_xray_update_check
  fi
}

xray_update_status_text() {
  ensure_xray_update_check

  case "${xray_update_state_cache}" in
    available)
      printf '%b%s -> %s，可选择 9 更新%b' "${yellow}" "${xray_current_version_cache}" "${xray_latest_version_cache}" "${plain}"
      ;;
    latest)
      printf '%b%s 已是最新%b' "${green}" "${xray_current_version_cache}" "${plain}"
      ;;
    not-installed)
      printf '%b未安装，可选择 1 安装%b' "${dim}" "${plain}"
      ;;
    *)
      if [[ -n "${xray_current_version_cache}" ]]; then
        printf '%b%s，暂时无法检查最新版本%b' "${yellow}" "${xray_current_version_cache}" "${plain}"
      else
        printf '%b暂时无法检查最新版本%b' "${dim}" "${plain}"
      fi
      ;;
  esac
}

update_xray_core() {
  need_root
  check_system

  ui_title "更新 Xray Core" "只更新 Xray 核心和 geodata，不重新初始化节点。"
  refresh_xray_update_check
  ui_kv "当前版本" "${xray_current_version_cache:-未安装}"
  ui_kv "最新版本" "${xray_latest_version_cache:-未知}"

  if [[ "${xray_update_state_cache}" == "latest" ]]; then
    confirm "当前版本与最新版相同，是否重新安装 Xray Core" "n" || die "已取消。"
  elif [[ "${xray_update_state_cache}" == "available" ]]; then
    confirm "检测到新版 ${xray_latest_version_cache}，是否更新 Xray Core" "y" || die "已取消。"
  elif [[ "${xray_update_state_cache}" == "not-installed" ]]; then
    confirm "未检测到 Xray，是否安装最新稳定版 Xray Core" "y" || die "已取消。"
  else
    confirm "无法确认最新版本，是否仍然继续更新 Xray Core" "n" || die "已取消。"
  fi

  install_xray

  if [[ -s "${CONFIG_FILE}" ]]; then
    test_xray_config "${CONFIG_FILE}"
    restart_xray
  else
    warn "未找到现有配置文件 ${CONFIG_FILE}，已跳过配置测试和服务重启。"
  fi

  refresh_xray_update_check
  ui_title "Xray Core 更新完成"
  ui_kv "当前版本" "${xray_current_version_cache:-未知}"
  ui_kv "最新版本" "${xray_latest_version_cache:-未知}"
}

validate_port_number() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\])${port}$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

ask_port() {
  local label="$1"
  local default="$2"
  local value
  local prompt_label="${label}"

  [[ "${prompt_label}" == *"端口"* ]] || prompt_label="${prompt_label}端口"

  while true; do
    value="$(prompt "${prompt_label}" "${default}")"
    if ! validate_port_number "${value}"; then
      warn "端口必须是 1-65535 的数字。"
      continue
    fi

    if port_in_use "${value}"; then
      warn "端口 ${value} 当前已被监听。"
      if ! confirm "仍然继续使用这个端口吗" "n"; then
        continue
      fi
    fi

    printf '%s' "${value}"
    return
  done
}

generate_random_port() {
  local port
  local attempts=0

  while (( attempts < 64 )); do
    port=$((1000 + (((RANDOM << 15) | RANDOM) % 64536)))
    if ! port_in_use "${port}"; then
      printf '%s' "${port}"
      return
    fi
    attempts=$((attempts + 1))
  done

  die "无法生成可用的随机端口，请稍后重试。"
}

ask_port_with_random_default() {
  local label="$1"
  local value
  local prompt_label="${label}"
  local prompt_text

  [[ "${prompt_label}" == *"端口"* ]] || prompt_label="${prompt_label}端口"

  while true; do
    prompt_text="$(printf '%b%s%b %b[回车随机端口]%b: ' "${cyan}" "${prompt_label}" "${plain}" "${dim}" "${plain}")"
    read -r -p "${prompt_text}" value

    if [[ -z "${value}" ]]; then
      value="$(generate_random_port)"
      ui_note "已随机生成端口：${value}"
    fi

    if ! validate_port_number "${value}"; then
      warn "端口必须是 1-65535 的数字。"
      continue
    fi

    if port_in_use "${value}"; then
      warn "端口 ${value} 当前已被监听。"
      if ! confirm "仍然继续使用这个端口吗" "n"; then
        continue
      fi
    fi

    printf '%s' "${value}"
    return
  done
}

is_cloudflare_ws_tls_port() {
  local port="$1"
  local candidate
  for candidate in ${CLOUDFLARE_WS_TLS_PORTS}; do
    [[ "${candidate}" == "${port}" ]] && return 0
  done
  return 1
}

ask_ws_client_port() {
  local default_port="${1:-443}"
  local value

  while true; do
    value="$(prompt "客户端访问节点时使用的端口，填写 Cloudflare HTTPS 端口 443/8443/2053/2083/2087/2096" "${default_port}")"
    if ! validate_port_number "${value}"; then
      warn "客户端连接端口必须是 1-65535 的数字。"
      continue
    fi

    if ! is_cloudflare_ws_tls_port "${value}"; then
      warn "端口 ${value} 不是常见的 Cloudflare HTTPS 代理端口。"
      if ! confirm "继续使用客户端连接端口 ${value} 吗" "n"; then
        continue
      fi
    fi

    printf '%s' "${value}"
    return
  done
}

validate_domain_like() {
  local value="$1"
  [[ "${value}" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "${value}" == *.* ]]
}

ask_domain() {
  local label="$1"
  local default="${2:-}"
  local value

  while true; do
    value="$(prompt "${label}" "${default}")"
    if validate_domain_like "${value}"; then
      printf '%s' "${value}"
      return
    fi
    warn "请输入不带 http://、路径和端口的域名，例如 example.com。"
  done
}

normalize_ws_path() {
  local value="$1"
  [[ -z "${value}" ]] && value="/"
  [[ "${value}" != /* ]] && value="/${value}"
  printf '%s' "${value}"
}

validate_ws_path() {
  local value="$1"
  [[ "${value}" == /* ]] && [[ "${value}" != "/" ]] && [[ ! "${value}" =~ [[:space:]] ]]
}

ask_ws_path() {
  local label="$1"
  local default="$2"
  local value

  while true; do
    value="$(normalize_ws_path "$(prompt "${label} Path，回车使用随机路径" "${default}")")"
    if validate_ws_path "${value}"; then
      printf '%s' "${value}"
      return
    fi
    warn "Path 必须以 / 开头，不能只填 /，也不能包含空白字符。"
  done
}

ask_ws_public_port() {
  local label="$1"
  local listen_port="$2"
  local default_port="${3:-$listen_port}"
  local value

  while true; do
    value="$(prompt "${label} 客户端公开端口，回车使用实际监听端口；如已配置 Cloudflare Origin Rule，可填 443/8443/2053/2083/2087/2096" "${default_port}")"
    if ! validate_port_number "${value}"; then
      warn "公开端口必须是 1-65535 的数字。"
      continue
    fi

    if [[ "${value}" != "${listen_port}" ]]; then
      if is_cloudflare_ws_tls_port "${value}"; then
        warn "已为 ${label} 指定公开端口 ${value}。请确认你已经在 Cloudflare Origin Rule 或其他前置代理中把 ${value} 回源到 ${listen_port}。"
      else
        warn "公开端口 ${value} 与实际监听端口 ${listen_port} 不一致，且不是 Cloudflare 常用 HTTPS 代理端口。"
      fi

      if ! confirm "继续使用公开端口 ${value} 吗" "n"; then
        continue
      fi
    fi

    printf '%s' "${value}"
    return
  done
}

resolve_ws_public_port() {
  local label="$1"
  local listen_port="$2"
  local current_port="${3:-}"
  local default_port="${current_port:-$listen_port}"

  if [[ "${default_port}" == "${listen_port}" ]] && is_cloudflare_ws_tls_port "${listen_port}"; then
    printf '%s' "${listen_port}"
    return
  fi

  ask_ws_public_port "${label}" "${listen_port}" "${default_port}"
}

generate_random_ws_path() {
  local protocol="${1:-ws}"
  local value=""
  local attempts=0

  while :; do
    if command -v openssl >/dev/null 2>&1; then
      value="$(openssl rand -hex 8 2>/dev/null || true)"
    fi
    if [[ -z "${value}" ]]; then
      value="$(date +%s%N | hash_sha256 | head -c 16)"
    fi

    # v2ray-agent 的前置分流路径会追加 ws/vws 后缀；随机路径避开这些后缀，方便后续迁移或扩展。
    if [[ ! "${value}" =~ (ws|vws)$ ]]; then
      printf '/%s' "${value}"
      return
    fi

    attempts=$((attempts + 1))
    (( attempts < 8 )) || {
      printf '/%s%s' "${value}" "${protocol:0:1}"
      return
    }
  done
}

validate_uuid() {
  local value="$1"
  [[ "${value}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

generate_uuid() {
  local value=""
  if [[ -n "${xray_bin}" ]]; then
    value="$("${xray_bin}" uuid 2>/dev/null | head -n 1 || true)"
  fi
  if ! validate_uuid "${value}" && [[ -r /proc/sys/kernel/random/uuid ]]; then
    value="$(cat /proc/sys/kernel/random/uuid)"
  fi
  validate_uuid "${value}" || die "无法生成 UUID。"
  printf '%s' "${value}"
}

ask_uuid() {
  local default="$1"
  local value

  while true; do
    value="$(prompt "请输入 UUID，回车使用自动生成值" "${default}")"
    if validate_uuid "${value}"; then
      printf '%s' "${value}"
      return
    fi
    warn "UUID 格式不正确。"
  done
}

abs_path() {
  local value="$1"
  if [[ "${value}" == /* ]]; then
    printf '%s' "${value}"
  else
    printf '%s/%s' "$(pwd)" "${value}"
  fi
}

validate_cert_pair() {
  local cert_file="$1"
  local key_file="$2"
  local cert_pub
  local key_pub

  [[ -s "${cert_file}" ]] || die "证书文件不存在或为空：${cert_file}"
  [[ -s "${key_file}" ]] || die "私钥文件不存在或为空：${key_file}"

  cert_pub="$(openssl x509 -in "${cert_file}" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')"
  key_pub="$(openssl pkey -in "${key_file}" -pubout -outform DER 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')"

  [[ -n "${cert_pub}" ]] || die "无法解析证书文件：${cert_file}"
  [[ -n "${key_pub}" ]] || die "无法解析私钥文件：${key_file}"
  [[ "${cert_pub}" == "${key_pub}" ]] || die "证书和私钥不匹配。"
}

read_pem_block() {
  local label="$1"
  local output_file="$2"
  local pem_kind="$3"
  local line
  local content=""
  local normalized

  echo
  printf '%b%s%b\n' "${yellow}" "请粘贴 ${label} PEM 内容；脚本会在检测到 END 边界行后自动结束。支持标准多行 PEM，也支持单行内容。" "${plain}" >&2
  while IFS= read -r line; do
    content+="${line}"$'\n'
    if [[ "${pem_kind}" == "PRIVATE KEY" && "${line}" == *"-----END "*"PRIVATE KEY-----"* ]]; then
      break
    fi
    if [[ "${line}" == *"-----END ${pem_kind}-----"* ]]; then
      break
    fi
    [[ "${line}" == "END" ]] && break
  done

  if [[ "${pem_kind}" == "PRIVATE KEY" ]]; then
    normalized="$(normalize_private_key "${content}")" || die "${label} 内容看起来不是有效 PEM 私钥。"
  else
    normalized="$(normalize_pem "${content}" "${pem_kind}")" || die "${label} 内容看起来不是有效 PEM。"
  fi

  umask 077
  printf '%s' "${normalized}" >"${output_file}"
}

normalize_pem() {
  local raw="$1"
  local pem_kind="$2"
  local content

  content="${raw//$'\r'/}"
  content="${content//\\r/}"
  content="${content//\\n/$'\n'}"
  content="$(printf '%s' "${content}" | sed \
    -e "s/-----BEGIN ${pem_kind}-----/\\
-----BEGIN ${pem_kind}-----\\
/g" \
    -e "s/-----END ${pem_kind}-----/\\
-----END ${pem_kind}-----\\
/g")"

  awk -v kind="${pem_kind}" '
    BEGIN {
      begin = "-----BEGIN " kind "-----"
      end = "-----END " kind "-----"
      in_block = 0
      count = 0
    }
    {
      line = $0
      gsub(/\r/, "", line)
      if (line == begin) {
        print begin
        in_block = 1
        next
      }
      if (line == end && in_block == 1) {
        print end
        count++
        in_block = 0
        next
      }
      if (in_block == 1) {
        gsub(/[[:space:]]/, "", line)
        if (length(line) > 0) {
          while (length(line) > 64) {
            print substr(line, 1, 64)
            line = substr(line, 65)
          }
          print line
        }
      }
    }
    END {
      if (count == 0 || in_block == 1) {
        exit 1
      }
    }
  ' <<<"${content}"
}

normalize_private_key() {
  local raw="$1"
  local kind

  if grep -q -- "-----BEGIN PRIVATE KEY-----" <<<"${raw}"; then
    kind="PRIVATE KEY"
  elif grep -q -- "-----BEGIN RSA PRIVATE KEY-----" <<<"${raw}"; then
    kind="RSA PRIVATE KEY"
  elif grep -q -- "-----BEGIN EC PRIVATE KEY-----" <<<"${raw}"; then
    kind="EC PRIVATE KEY"
  else
    return 1
  fi

  normalize_pem "${raw}" "${kind}"
}

safe_file_name() {
  local value="$1"
  printf '%s' "${value}" | tr -c 'A-Za-z0-9._-' '_'
}

managed_cert_basename() {
  local source_cert="${1:-}"
  local base=""

  if [[ -n "${ws_domain}" ]]; then
    base="$(safe_file_name "${ws_domain}")"
  elif [[ -n "${source_cert}" ]]; then
    base="$(safe_file_name "$(basename "${source_cert%.*}")")"
  else
    base="ws"
  fi

  printf '%s' "${base:-ws}"
}

managed_cert_path() {
  local extension="$1"
  local source_cert="${2:-}"
  printf '%s/%s.%s' "${CERT_DIR}" "$(managed_cert_basename "${source_cert}")" "${extension}"
}

is_managed_cert_path() {
  local path="$1"
  [[ "${path}" == "${CERT_DIR}/"* ]]
}

ensure_managed_ws_cert_pair() {
  local source_cert="$1"
  local source_key="$2"
  local target_cert
  local target_key

  target_cert="$(managed_cert_path "crt" "${source_cert}")"
  target_key="$(managed_cert_path "key" "${source_cert}")"

  mkdir -p "${CERT_DIR}"

  if [[ "${source_cert}" != "${target_cert}" ]]; then
    install -m 600 "${source_cert}" "${target_cert}"
  else
    chmod 600 "${target_cert}" 2>/dev/null || true
  fi

  if [[ "${source_key}" != "${target_key}" ]]; then
    install -m 600 "${source_key}" "${target_key}"
  else
    chmod 600 "${target_key}" 2>/dev/null || true
  fi

  ws_cert_file="${target_cert}"
  ws_key_file="${target_key}"
}

apply_runtime_ownership() {
  local path="$1"
  local mode="$2"
  local user="$3"
  local group="$4"

  chmod "${mode}" "${path}" 2>/dev/null || true
  if id -u "${user}" >/dev/null 2>&1; then
    chown "${user}:${group}" "${path}" 2>/dev/null || true
  fi
}

prepare_runtime_environment() {
  local service_user
  local service_group
  local access_log
  local error_log

  service_user="$(effective_xray_service_user)"
  service_group="$(effective_xray_service_group "${service_user}")"
  access_log="${XRAY_LOG_DIR}/access.log"
  error_log="${XRAY_LOG_DIR}/error.log"

  mkdir -p "${CONFIG_DIR}" "${CERT_DIR}" "${XRAY_LOG_DIR}"
  touch "${access_log}" "${error_log}"

  apply_runtime_ownership "${XRAY_LOG_DIR}" 750 "${service_user}" "${service_group}"
  apply_runtime_ownership "${access_log}" 640 "${service_user}" "${service_group}"
  apply_runtime_ownership "${error_log}" 640 "${service_user}" "${service_group}"

  if [[ -n "${ws_cert_file}" && -n "${ws_key_file}" ]]; then
    if is_managed_cert_path "${ws_cert_file}"; then
      apply_runtime_ownership "${ws_cert_file}" 600 "${service_user}" "${service_group}"
    fi
    if is_managed_cert_path "${ws_key_file}"; then
      apply_runtime_ownership "${ws_key_file}" 600 "${service_user}" "${service_group}"
    fi
  fi
}

server_display_hostname() {
  local value=""

  if [[ -n "${CXN_NODE_HOSTNAME:-}" ]]; then
    printf '%s' "${CXN_NODE_HOSTNAME}"
    return
  fi

  if command -v hostnamectl >/dev/null 2>&1; then
    value="$(hostnamectl --static 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -z "${value}" ]] && command -v hostname >/dev/null 2>&1; then
    value="$(hostname -s 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -z "${value}" ]] && command -v hostname >/dev/null 2>&1; then
    value="$(hostname 2>/dev/null | head -n 1 || true)"
  fi

  value="${value%% *}"
  printf '%s' "${value:-server}"
}

configure_certificate() {
  local mode
  local safe_domain
  local cert_path
  local key_path

  mkdir -p "${CERT_DIR}"
  ui_section "证书配置"
  ui_note "CDN TLS 节点需要证书和私钥；脚本会统一保存到 ${CERT_DIR}。"
  ui_option "1" "粘贴 PEM 内容" "适合 Cloudflare Origin Certificate"
  ui_option "2" "填写文件路径" "使用服务器上已有证书文件"

  while true; do
    mode="$(prompt "请选择证书输入方式" "1")"
    case "${mode}" in
      1)
        safe_domain="$(safe_file_name "${ws_domain}")"
        cert_path="${CERT_DIR}/${safe_domain}.crt"
        key_path="${CERT_DIR}/${safe_domain}.key"
        read_pem_block "证书 certificate" "${cert_path}" "CERTIFICATE"
        read_pem_block "私钥 private key" "${key_path}" "PRIVATE KEY"
        chmod 600 "${cert_path}" "${key_path}"
        validate_cert_pair "${cert_path}" "${key_path}"
        ws_cert_file="${cert_path}"
        ws_key_file="${key_path}"
        return
        ;;
      2)
        cert_path="$(abs_path "$(prompt "请输入证书文件路径 certificateFile")")"
        key_path="$(abs_path "$(prompt "请输入私钥文件路径 keyFile")")"
        validate_cert_pair "${cert_path}" "${key_path}"
        ensure_managed_ws_cert_pair "${cert_path}" "${key_path}"
        return
        ;;
      *)
        warn "请输入 1 或 2。"
        ;;
    esac
  done
}

select_protocols() {
  local selected
  local item
  local prompt_text

  ui_section "选择节点类型"
  ui_note "多个选项可用逗号或空格分隔，例如 1,3。"
  ui_option "1" "VLESS XHTTP TLS" "经 Cloudflare CDN 回源"
  ui_option "2" "VLESS WS TLS" "经 Cloudflare CDN 回源"
  ui_option "3" "VMess WS TLS" "经 Cloudflare CDN 回源"
  ui_option "4" "VLESS Reality Vision" "直连 TCP，不走 CDN"
  prompt_text="$(printf '%b%s%b: ' "${cyan}" "选择 [1,2,3,4，回车默认1,4]" "${plain}")"
  read -r -p "${prompt_text}" selected
  selected="${selected:-1,4}"

  selected="${selected//,/ }"
  for item in ${selected}; do
    case "${item}" in
      1) vless_xhttp_enabled=1 ;;
      2) vless_ws_enabled=1 ;;
      3) vmess_ws_enabled=1 ;;
      4) reality_enabled=1 ;;
      *) die "未知选项：${item}" ;;
    esac
  done

  (( vless_ws_enabled || vmess_ws_enabled || vless_xhttp_enabled || reality_enabled )) || die "至少需要选择一个节点。"
}

detect_public_ip() {
  local value=""
  value="$(curl -4s --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}' || true)"
  if [[ -z "${value}" ]]; then
    value="$(curl -6s --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}' || true)"
  fi
  printf '%s' "${value}"
}

parse_reality_target() {
  local value="$1"
  if [[ "${value}" == *:* && "${value}" != *::* ]]; then
    reality_target="${value%%:*}"
    reality_target_port="${value##*:}"
  else
    reality_target="${value}"
    reality_target_port=443
  fi

  validate_domain_like "${reality_target}" || die "Reality 目标域名格式不正确：${reality_target}"
  validate_port_number "${reality_target_port}" || die "Reality 目标端口不正确：${reality_target_port}"
}

parse_x25519_output() {
  local output="$1"
  reality_private_key="$(awk 'tolower($0) ~ /private/ {print $NF; exit}' <<<"${output}")"
  reality_public_key="$(awk 'tolower($0) ~ /(public|password)/ {print $NF; exit}' <<<"${output}")"

  [[ -n "${reality_private_key}" ]] || die "无法从 xray x25519 输出中解析私钥。"
  [[ -n "${reality_public_key}" ]] || die "无法从 xray x25519 输出中解析公钥。"
}

hash_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | awk '{print $1}'
  else
    md5 -q
  fi
}

hash_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum | awk '{print $1}'
  else
    shasum -a 1 | awk '{print $1}'
  fi
}

hash_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

generate_reality_keys() {
  local output
  local key_seed

  key_seed="$(printf '%s' "${uuid}" | hash_md5 | head -c 32 | base64_one_line | tr '+/' '-_' | tr -d '=')"
  output="$("${xray_bin}" x25519 -i "${key_seed}" 2>/dev/null)"
  parse_x25519_output "${output}"
}

generate_short_id() {
  printf '%s' "${uuid}" | hash_sha1 | head -c 16
}

validate_short_id() {
  local value="$1"
  [[ "${value}" =~ ^[0-9a-fA-F]*$ ]] && (( ${#value} <= 16 )) && (( ${#value} % 2 == 0 ))
}

ask_short_id() {
  local default="$1"
  local value

  while true; do
    value="$(prompt "Reality ShortId，回车使用自动生成值" "${default}")"
    if validate_short_id "${value}"; then
      printf '%s' "${value}"
      return
    fi
    warn "ShortId 只能是偶数长度十六进制字符串，最长 16 个字符；也可以留空。"
  done
}

collect_ws_settings() {
  local default_path
  local cert_label

  if (( vless_ws_enabled || vmess_ws_enabled || vless_xhttp_enabled )); then
    ui_section "CDN TLS 节点"
    ui_note "用于 Cloudflare CDN 回源。domain/Host/SNI 通常填写已接入 Cloudflare 的域名。"
    ui_note "客户端公开端口会写入分享链接；源站监听端口用于 Xray inbound。"
    ws_domain="$(ask_domain "请输入已接入 Cloudflare 的域名" "${ws_domain}")"
    ws_client_addr="$(prompt "客户端连接地址，可填优选域名/IP" "${DEFAULT_WS_CLIENT_ADDR}")"
    ws_client_port="$(ask_ws_client_port "${ws_client_port:-443}")"

    if (( vless_ws_enabled )); then
      ui_group "VLESS WS TLS"
      vless_ws_port="$(ask_port_with_random_default "连接到服务器的端口，也就是重写到的端口")"
      vless_ws_public_port="${ws_client_port}"
      default_path="${vless_ws_path:-$(generate_random_ws_path vless)}"
      vless_ws_path="$(ask_ws_path "VLESS" "${default_path}")"
      vless_ws_host="$(ask_domain "VLESS WS Host/SNI" "${ws_domain}")"
      vless_ws_tag="vless-ws-tls-${vless_ws_port}"
    fi

    if (( vless_xhttp_enabled )); then
      ui_group "VLESS XHTTP TLS"
      vless_xhttp_port="$(ask_port_with_random_default "连接到服务器的端口，也就是重写到的端口")"
      vless_xhttp_public_port="${ws_client_port}"
      default_path="${vless_xhttp_path:-$(generate_random_ws_path xhttp)}"
      vless_xhttp_path="$(ask_ws_path "VLESS XHTTP" "${default_path}")"
      vless_xhttp_host="$(ask_domain "VLESS XHTTP Host/SNI" "${ws_domain}")"
      vless_xhttp_tag="vless-xhttp-tls-${vless_xhttp_port}"
    fi

    if (( vmess_ws_enabled )); then
      ui_group "VMess WS TLS"
      vmess_ws_port="$(ask_port_with_random_default "连接到服务器的端口，也就是重写到的端口")"
      vmess_ws_public_port="${ws_client_port}"
      default_path="${vmess_ws_path:-$(generate_random_ws_path vmess)}"
      vmess_ws_path="$(ask_ws_path "VMess" "${default_path}")"
      vmess_ws_host="$(ask_domain "VMess WS Host/SNI" "${ws_domain}")"
      vmess_ws_tag="vmess-ws-tls-${vmess_ws_port}"
    fi

    if [[ -n "${ws_cert_file}" && -n "${ws_key_file}" && -s "${ws_cert_file}" && -s "${ws_key_file}" ]]; then
      cert_label="${ws_cert_file} / ${ws_key_file}"
      if confirm "检测到已有证书配置，继续使用 ${cert_label} 吗" "y"; then
        validate_cert_pair "${ws_cert_file}" "${ws_key_file}"
      else
        configure_certificate
      fi
    else
      configure_certificate
    fi
  fi
}

collect_reality_settings() {
  local detected_ip
  local target_input
  local default_short_id

  if (( reality_enabled )); then
    ui_section "Reality Vision"
    ui_note "Reality 是直连 TCP 节点，不适合套 Cloudflare CDN。"
    ui_note "客户端地址通常填写 VPS 公网 IP；目标域名用于 Reality serverNames/dest。"
    detected_ip="$(detect_public_ip)"
    reality_addr="$(prompt "Reality 客户端连接地址/IP" "${detected_ip}")"
    [[ -n "${reality_addr}" ]] || die "Reality 客户端连接地址不能为空。"

    reality_port="$(ask_port "Reality" "443")"
    target_input="$(prompt "Reality 目标域名，可带端口" "apple.com")"
    parse_reality_target "${target_input}"

    generate_reality_keys
    default_short_id="$(generate_short_id)"
    reality_short_id="$(ask_short_id "${default_short_id}")"
    reality_tag="vless-reality-vision-${reality_port}"
  fi
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "缺少 jq，请先安装 jq。"
}

blank_state_json() {
  jq -n '{
    version: 1,
    uuid: "",
    ws: {
      domain: "",
      client_addr: "",
      client_port: 443,
      certificate_file: "",
      key_file: ""
    },
    nodes: []
  }'
}

ensure_state() {
  require_jq
  mkdir -p "${STATE_DIR}"
  if [[ ! -s "${STATE_FILE}" ]]; then
    blank_state_json >"${STATE_FILE}"
    chmod 600 "${STATE_FILE}" 2>/dev/null || true
  fi
  jq -e '.version == 1 and (.nodes | type == "array")' "${STATE_FILE}" >/dev/null \
    || die "状态文件格式不正确：${STATE_FILE}"
}

state_exists() {
  [[ -s "${STATE_FILE}" ]] && jq -e '.version == 1 and (.nodes | type == "array")' "${STATE_FILE}" >/dev/null 2>&1
}

reset_state_file() {
  local tmp_state
  require_jq
  mkdir -p "${STATE_DIR}"
  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq -n \
    --arg uuid "${uuid}" \
    --arg domain "${ws_domain}" \
    --arg client_addr "${ws_client_addr}" \
    --argjson client_port "${ws_client_port}" \
    --arg cert "${ws_cert_file}" \
    --arg key "${ws_key_file}" \
    '{
      version: 1,
      uuid: $uuid,
      ws: {
        domain: $domain,
        client_addr: $client_addr,
        client_port: $client_port,
        certificate_file: $cert,
        key_file: $key
      },
      nodes: []
    }' >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"
}

load_state_globals() {
  state_exists || return 0
  uuid="$(jq -r '.uuid // ""' "${STATE_FILE}")"
  ws_domain="$(jq -r '.ws.domain // ""' "${STATE_FILE}")"
  ws_client_addr="$(jq -r '.ws.client_addr // ""' "${STATE_FILE}")"
  ws_client_port="$(jq -r '(.ws.client_port // ([.nodes[]? | select(.type == "vless-ws-tls" or .type == "vmess-ws-tls" or .type == "vless-xhttp-tls") | (.public_port // .port)] | first) // 443)' "${STATE_FILE}")"
  ws_cert_file="$(jq -r '.ws.certificate_file // ""' "${STATE_FILE}")"
  ws_key_file="$(jq -r '.ws.key_file // ""' "${STATE_FILE}")"
}

update_state_ws_metadata() {
  local tmp_state
  ensure_state
  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq \
    --arg uuid "${uuid}" \
    --arg domain "${ws_domain}" \
    --arg client_addr "${ws_client_addr}" \
    --argjson client_port "${ws_client_port}" \
    --arg cert "${ws_cert_file}" \
    --arg key "${ws_key_file}" \
    '.uuid = $uuid
     | .ws.domain = $domain
     | .ws.client_addr = $client_addr
     | .ws.client_port = $client_port
     | .ws.certificate_file = $cert
     | .ws.key_file = $key' \
    "${STATE_FILE}" >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"
}

sync_ws_public_port_in_state() {
  local tmp_state

  ensure_state
  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq --argjson client_port "${ws_client_port}" '
    .ws.client_port = $client_port
    | .nodes |= map(
        if .type == "vless-ws-tls" or .type == "vmess-ws-tls" or .type == "vless-xhttp-tls" then
          .public_port = $client_port
        else
          .
        end
      )' "${STATE_FILE}" >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"
}

update_state_uuid() {
  local tmp_state
  ensure_state
  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq --arg uuid "${uuid}" '.uuid = $uuid' "${STATE_FILE}" >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"
}

make_unique_tag() {
  local base="$1"
  local candidate="$base"
  local suffix=2

  ensure_state
  while jq -e --arg tag "${candidate}" '.nodes[]? | select(.tag == $tag)' "${STATE_FILE}" >/dev/null; do
    candidate="${base}-${suffix}"
    suffix=$((suffix + 1))
  done
  printf '%s' "${candidate}"
}

append_node_json_to_state() {
  local node_json="$1"
  local tmp_state

  ensure_state
  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq --argjson node "${node_json}" '.nodes += [$node]' "${STATE_FILE}" >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"
}

vless_ws_node_json() {
  jq -n \
    --arg tag "${vless_ws_tag}" \
    --arg uuid "${uuid}" \
    --argjson port "${vless_ws_port}" \
    --argjson public_port "${vless_ws_public_port:-$vless_ws_port}" \
    --arg path "${vless_ws_path}" \
    --arg host "${vless_ws_host}" \
    '{
      tag: $tag,
      type: "vless-ws-tls",
      port: $port,
      public_port: $public_port,
      path: $path,
      host: $host,
      uuid: $uuid
    }'
}

vmess_ws_node_json() {
  jq -n \
    --arg tag "${vmess_ws_tag}" \
    --arg uuid "${uuid}" \
    --argjson port "${vmess_ws_port}" \
    --argjson public_port "${vmess_ws_public_port:-$vmess_ws_port}" \
    --arg path "${vmess_ws_path}" \
    --arg host "${vmess_ws_host}" \
    '{
      tag: $tag,
      type: "vmess-ws-tls",
      port: $port,
      public_port: $public_port,
      path: $path,
      host: $host,
      uuid: $uuid
    }'
}

vless_xhttp_node_json() {
  jq -n \
    --arg tag "${vless_xhttp_tag}" \
    --arg uuid "${uuid}" \
    --argjson port "${vless_xhttp_port}" \
    --argjson public_port "${vless_xhttp_public_port:-$vless_xhttp_port}" \
    --arg path "${vless_xhttp_path}" \
    --arg host "${vless_xhttp_host}" \
    '{
      tag: $tag,
      type: "vless-xhttp-tls",
      port: $port,
      public_port: $public_port,
      path: $path,
      host: $host,
      uuid: $uuid
    }'
}

reality_node_json() {
  jq -n \
    --arg tag "${reality_tag}" \
    --arg uuid "${uuid}" \
    --argjson port "${reality_port}" \
    --arg addr "${reality_addr}" \
    --arg target "${reality_target}" \
    --argjson target_port "${reality_target_port}" \
    --arg private_key "${reality_private_key}" \
    --arg public_key "${reality_public_key}" \
    --arg short_id "${reality_short_id}" \
    --arg fingerprint "${reality_fingerprint}" \
    --arg spider_x "${reality_spider_x}" \
    '{
      tag: $tag,
      type: "vless-reality-vision",
      port: $port,
      addr: $addr,
      target: $target,
      target_port: $target_port,
      uuid: $uuid,
      private_key: $private_key,
      public_key: $public_key,
      short_id: $short_id,
      fingerprint: $fingerprint,
      spider_x: $spider_x
    }'
}

append_selected_nodes_to_state() {
  if (( vless_ws_enabled )); then
    vless_ws_tag="$(make_unique_tag "vless-ws-tls-${vless_ws_port}")"
    append_node_json_to_state "$(vless_ws_node_json)"
  fi

  if (( vmess_ws_enabled )); then
    vmess_ws_tag="$(make_unique_tag "vmess-ws-tls-${vmess_ws_port}")"
    append_node_json_to_state "$(vmess_ws_node_json)"
  fi

  if (( vless_xhttp_enabled )); then
    vless_xhttp_tag="$(make_unique_tag "vless-xhttp-tls-${vless_xhttp_port}")"
    append_node_json_to_state "$(vless_xhttp_node_json)"
  fi

  if (( reality_enabled )); then
    reality_tag="$(make_unique_tag "vless-reality-vision-${reality_port}")"
    append_node_json_to_state "$(reality_node_json)"
  fi
}

validate_state_for_rebuild() {
  ensure_state
  load_state_globals
  if jq -e '.nodes[]? | select(.type == "vless-ws-tls" or .type == "vmess-ws-tls" or .type == "vless-xhttp-tls")' "${STATE_FILE}" >/dev/null; then
    validate_cert_pair "${ws_cert_file}" "${ws_key_file}"
    if ! is_managed_cert_path "${ws_cert_file}" || ! is_managed_cert_path "${ws_key_file}"; then
      ensure_managed_ws_cert_pair "${ws_cert_file}" "${ws_key_file}"
      update_state_ws_metadata
    fi
  fi
  prepare_runtime_environment
}

rebuild_config_from_state() {
  local config_tmp

  ensure_state
  [[ -n "${tmp_dir}" ]] || tmp_dir="$(mktemp -d)"
  mkdir -p "${CONFIG_DIR}"
  config_tmp="${tmp_dir}/config.json"

  build_config_from_state_to_file "${config_tmp}"
  test_xray_config "${config_tmp}"

  if [[ -f "${CONFIG_FILE}" ]]; then
    cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "${config_tmp}" "${CONFIG_FILE}"
}

build_config_from_state_to_file() {
  local output_file="$1"

  ensure_state
  validate_state_for_rebuild
  jq --arg xray_log_dir "${XRAY_LOG_DIR}" '
    . as $state
    | def sniffing:
        {
          enabled: true,
          destOverride: ["http", "tls", "quic"]
        };
      def vless_ws($node):
        {
          listen: "0.0.0.0",
          port: $node.port,
          protocol: "vless",
          tag: $node.tag,
          settings: {
            clients: [{ id: $node.uuid, email: $node.tag }],
            decryption: "none"
          },
          streamSettings: {
            network: "ws",
            security: "tls",
            tlsSettings: {
              rejectUnknownSni: false,
              minVersion: "1.2",
              alpn: ["http/1.1"],
              certificates: [{
                certificateFile: $state.ws.certificate_file,
                keyFile: $state.ws.key_file,
                ocspStapling: 3600
              }]
            },
            wsSettings: {
              path: $node.path,
              headers: { Host: $node.host }
            }
          },
          sniffing: sniffing
        };
      def vmess_ws($node):
        {
          listen: "0.0.0.0",
          port: $node.port,
          protocol: "vmess",
          tag: $node.tag,
          settings: {
            clients: [{ id: $node.uuid, alterId: 0, email: $node.tag }]
          },
          streamSettings: {
            network: "ws",
            security: "tls",
            tlsSettings: {
              rejectUnknownSni: false,
              minVersion: "1.2",
              alpn: ["http/1.1"],
              certificates: [{
                certificateFile: $state.ws.certificate_file,
                keyFile: $state.ws.key_file,
                ocspStapling: 3600
              }]
            },
            wsSettings: {
              path: $node.path,
              headers: { Host: $node.host }
            }
          },
          sniffing: sniffing
        };
      def vless_xhttp($node):
        {
          listen: "0.0.0.0",
          port: $node.port,
          protocol: "vless",
          tag: $node.tag,
          settings: {
            clients: [{ id: $node.uuid, email: $node.tag }],
            decryption: "none"
          },
          streamSettings: {
            network: "xhttp",
            security: "tls",
            tlsSettings: {
              rejectUnknownSni: false,
              minVersion: "1.2",
              alpn: ["h2", "http/1.1"],
              certificates: [{
                certificateFile: $state.ws.certificate_file,
                keyFile: $state.ws.key_file,
                ocspStapling: 3600
              }]
            },
            xhttpSettings: {
              path: $node.path
            }
          },
          sniffing: sniffing
        };
      def reality($node):
        {
          listen: "0.0.0.0",
          port: $node.port,
          protocol: "vless",
          tag: $node.tag,
          settings: {
            clients: [{ id: $node.uuid, flow: "xtls-rprx-vision", email: $node.tag }],
            decryption: "none"
          },
          streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
              show: false,
              dest: ($node.target + ":" + ($node.target_port | tostring)),
              xver: 0,
              serverNames: [$node.target],
              privateKey: $node.private_key,
              shortIds: [$node.short_id]
            }
          },
          sniffing: sniffing
        };
      {
        log: {
          access: ($xray_log_dir + "/access.log"),
          error: ($xray_log_dir + "/error.log"),
          loglevel: "warning"
        },
        inbounds: [
          $state.nodes[]
          | if .type == "vless-ws-tls" then vless_ws(.)
            elif .type == "vmess-ws-tls" then vmess_ws(.)
            elif .type == "vless-xhttp-tls" then vless_xhttp(.)
            elif .type == "vless-reality-vision" then reality(.)
            else empty
            end
        ],
        outbounds: [
          { protocol: "freedom", tag: "direct" },
          { protocol: "blackhole", tag: "block" }
        ],
        dns: {
          servers: [
            "1.1.1.1",
            "8.8.8.8",
            "2606:4700:4700::1111",
            "2001:4860:4860::8888",
            "localhost"
          ]
        },
        routing: {
          domainStrategy: "IPIfNonMatch",
          rules: [
            {
              type: "field",
              ip: ["geoip:private"],
              outboundTag: "block"
            }
          ]
        }
      }' "${STATE_FILE}" >"${output_file}"
}

node_count() {
  state_exists || {
    printf '0'
    return
  }
  jq -r '.nodes | length' "${STATE_FILE}"
}

test_xray_config() {
  local config_file="$1"
  local output=""
  local fallback_output=""

  if [[ "${CXN_SKIP_XRAY_TEST:-0}" == "1" ]]; then
    jq empty "${config_file}"
    return
  fi

  [[ -n "${xray_bin}" ]] || resolve_xray_bin

  if output="$("${xray_bin}" run -test -c "${config_file}" 2>&1)"; then
    [[ -n "${output}" ]] && echo "${output}"
    return 0
  fi

  if fallback_output="$("${xray_bin}" run -test -config "${config_file}" 2>&1)"; then
    [[ -n "${fallback_output}" ]] && echo "${fallback_output}"
    return 0
  fi

  err "Xray 配置验证失败。"
  [[ -n "${output}" ]] && err "${output}"
  [[ -n "${fallback_output}" ]] && err "${fallback_output}"
  return 1
}

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

base64_one_line() {
  base64 | tr -d '\n'
}

format_address_for_url() {
  local value="$1"
  if [[ "${value}" == *:* && "${value}" != \[*\] ]]; then
    printf '[%s]' "${value}"
  else
    printf '%s' "${value}"
  fi
}

node_display_name_from_json() {
  local node_json="$1"
  local type
  local host_value

  type="$(jq -r '.type' <<<"${node_json}")"
  host_value="$(server_display_hostname)"
  case "${type}" in
    vless-ws-tls)
      printf 'vl_%s' "${host_value}"
      ;;
    vmess-ws-tls)
      printf 'vm_%s' "${host_value}"
      ;;
    vless-xhttp-tls)
      printf 'xhttp_%s' "${host_value}"
      ;;
    vless-reality-vision)
      printf 'real_%s' "${host_value}"
      ;;
    *)
      jq -r '.tag // .type // "node"' <<<"${node_json}"
      ;;
  esac
}

write_links_from_state() {
  local node_json
  local type
  local tag
  local display_name
  local node_uuid
  local addr
  local port
  local host
  local path
  local path_encoded
  local tag_encoded
  local link
  local vmess_json
  local target
  local public_key
  local short_id
  local fingerprint
  local spider_x
  local spider_encoded

  ensure_state
  mkdir -p "$(dirname "${LINKS_FILE}")"
  : >"${LINKS_FILE}"
  chmod 600 "${LINKS_FILE}" 2>/dev/null || true

  while IFS= read -r node_json; do
    type="$(jq -r '.type' <<<"${node_json}")"
    tag="$(jq -r '.tag' <<<"${node_json}")"
    display_name="$(node_display_name_from_json "${node_json}")"
    node_uuid="$(jq -r '.uuid' <<<"${node_json}")"

    case "${type}" in
      vless-ws-tls)
        addr="$(format_address_for_url "$(jq -r '.ws.client_addr // .ws.domain // ""' "${STATE_FILE}")")"
        port="$(jq -r '.public_port // .port' <<<"${node_json}")"
        host="$(jq -r '.host' <<<"${node_json}")"
        path="$(jq -r '.path' <<<"${node_json}")"
        path_encoded="$(urlencode "${path}")"
        tag_encoded="$(urlencode "${display_name}")"
        link="vless://${node_uuid}@${addr}:${port}?encryption=none&type=ws&security=tls&sni=${host}&host=${host}&path=${path_encoded}#${tag_encoded}"
        {
          echo "---------- ${display_name} ----------"
          echo "${link}"
          append_qr "${link}"
          echo
        } >>"${LINKS_FILE}"
        ;;
      vmess-ws-tls)
        addr="$(jq -r '.ws.client_addr // .ws.domain // ""' "${STATE_FILE}")"
        port="$(jq -r '.public_port // .port' <<<"${node_json}")"
        host="$(jq -r '.host' <<<"${node_json}")"
        path="$(jq -r '.path' <<<"${node_json}")"
        vmess_json="$(jq -nc \
          --arg add "${addr}" \
          --arg port "${port}" \
          --arg id "${node_uuid}" \
          --arg host "${host}" \
          --arg path "${path}" \
          --arg ps "${display_name}" \
          '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
        link="vmess://$(printf '%s' "${vmess_json}" | base64_one_line)"
        {
          echo "---------- ${display_name} ----------"
          echo "${link}"
          append_qr "${link}"
          echo
        } >>"${LINKS_FILE}"
        ;;
      vless-xhttp-tls)
        addr="$(format_address_for_url "$(jq -r '.ws.client_addr // .ws.domain // ""' "${STATE_FILE}")")"
        port="$(jq -r '.public_port // .port' <<<"${node_json}")"
        host="$(jq -r '.host' <<<"${node_json}")"
        path="$(jq -r '.path' <<<"${node_json}")"
        path_encoded="$(urlencode "${path}")"
        tag_encoded="$(urlencode "${display_name}")"
        link="vless://${node_uuid}@${addr}:${port}?encryption=none&type=xhttp&security=tls&sni=${host}&host=${host}&path=${path_encoded}&alpn=h2,http/1.1#${tag_encoded}"
        {
          echo "---------- ${display_name} ----------"
          echo "${link}"
          append_qr "${link}"
          echo
        } >>"${LINKS_FILE}"
        ;;
      vless-reality-vision)
        addr="$(format_address_for_url "$(jq -r '.addr' <<<"${node_json}")")"
        port="$(jq -r '.port' <<<"${node_json}")"
        target="$(jq -r '.target' <<<"${node_json}")"
        public_key="$(jq -r '.public_key' <<<"${node_json}")"
        short_id="$(jq -r '.short_id' <<<"${node_json}")"
        fingerprint="$(jq -r '.fingerprint' <<<"${node_json}")"
        spider_x="$(jq -r '.spider_x' <<<"${node_json}")"
        spider_encoded="$(urlencode "${spider_x}")"
        tag_encoded="$(urlencode "${display_name}")"
        link="vless://${node_uuid}@${addr}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${target}&fp=${fingerprint}&pbk=${public_key}&sid=${short_id}&spx=${spider_encoded}#${tag_encoded}"
        {
          echo "---------- ${display_name} ----------"
          echo "${link}"
          append_qr "${link}"
          echo
        } >>"${LINKS_FILE}"
        ;;
    esac
  done < <(jq -c '.nodes[]?' "${STATE_FILE}")
}

append_qr() {
  local link="$1"

  if (( show_qr_in_links )) && command -v qrencode >/dev/null 2>&1; then
    echo
    qrencode -t UTF8 "${link}"
  fi
}

restart_xray() {
  log "重启 Xray 服务..."
  systemctl daemon-reload
  systemctl enable "${XRAY_SERVICE_NAME}" >/dev/null 2>&1 || true
  if ! systemctl restart "${XRAY_SERVICE_NAME}"; then
    warn "Xray 服务重启失败，输出最近的 systemd 诊断信息："
    systemctl --no-pager --full -l status "${XRAY_SERVICE_NAME}" 2>&1 || true
    if command -v journalctl >/dev/null 2>&1; then
      echo
      journalctl -u "${XRAY_SERVICE_NAME}" -n 50 --no-pager 2>&1 || true
    fi
    return 1
  fi

  if ! systemctl --quiet is-active "${XRAY_SERVICE_NAME}"; then
    warn "Xray 服务未进入 active 状态，输出最近的 systemd 诊断信息："
    systemctl --no-pager --full -l status "${XRAY_SERVICE_NAME}" 2>&1 || true
    if command -v journalctl >/dev/null 2>&1; then
      echo
      journalctl -u "${XRAY_SERVICE_NAME}" -n 50 --no-pager 2>&1 || true
    fi
    return 1
  fi
}

xray_service_status_text() {
  if command -v systemctl >/dev/null 2>&1 && systemctl --quiet is-active "${XRAY_SERVICE_NAME}" 2>/dev/null; then
    printf '%bactive%b' "${green}" "${plain}"
  elif command -v xray >/dev/null 2>&1 || [[ -x /usr/local/bin/xray ]]; then
    printf '%binstalled%b' "${yellow}" "${plain}"
  else
    printf '%bnot installed%b' "${dim}" "${plain}"
  fi
}

state_status_text() {
  if state_exists; then
    printf '%bready%b' "${green}" "${plain}"
  else
    printf '%bnot initialized%b' "${dim}" "${plain}"
  fi
}

links_status_text() {
  if [[ -s "${LINKS_FILE}" ]]; then
    printf '%bready%b' "${green}" "${plain}"
  else
    printf '%bempty%b' "${dim}" "${plain}"
  fi
}

menu_node_count() {
  if state_exists; then
    node_count
  else
    printf '0'
  fi
}

node_type_label() {
  case "$1" in
    vless-ws-tls)
      printf 'VLESS WS TLS'
      ;;
    vmess-ws-tls)
      printf 'VMess WS TLS'
      ;;
    vless-xhttp-tls)
      printf 'VLESS XHTTP TLS'
      ;;
    vless-reality-vision)
      printf 'Reality Vision'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

print_state_summary() {
  local action="${1:-操作完成}"
  local count

  count="$(node_count)"
  ui_title "${action}" "Cloudflare Xray Node 状态摘要"
  ui_kv "状态文件" "${STATE_FILE}"
  ui_kv "Xray 配置" "${CONFIG_FILE}"
  ui_kv "节点链接" "${LINKS_FILE}"
  ui_kv "节点数量" "${count}"

  if (( count > 0 )); then
    ui_section "Cloudflare 提醒"
    ui_note "WS/XHTTP TLS 节点用于 Cloudflare 代理；Reality 节点是直连 TCP，不走 CDN。"
    ui_note "Cloudflare HTTPS 标准端口：443、2053、2083、2087、2096、8443。"
    ui_note "listen 是源站实际监听端口；public 是分享链接里的客户端公开端口。"
    ui_note "当 public 与 listen 不一致时，请确认 Origin Rule 或前置代理已完成回源映射。"
    list_nodes
    if [[ -s "${LINKS_FILE}" ]]; then
      ui_section "节点链接"
      cat "${LINKS_FILE}"
    fi
  fi
}

reset_selection_flags() {
  vless_ws_enabled=0
  vmess_ws_enabled=0
  vless_xhttp_enabled=0
  reality_enabled=0
  ws_client_port=443
  vless_ws_port=8443
  vless_ws_public_port=""
  vless_ws_path=""
  vless_ws_host=""
  vless_ws_tag=""
  vmess_ws_port=2096
  vmess_ws_public_port=""
  vmess_ws_path=""
  vmess_ws_host=""
  vmess_ws_tag=""
  vless_xhttp_port=2083
  vless_xhttp_public_port=""
  vless_xhttp_path=""
  vless_xhttp_host=""
  vless_xhttp_tag=""
  reality_port=443
  reality_addr=""
  reality_target="apple.com"
  reality_target_port=443
  reality_private_key=""
  reality_public_key=""
  reality_short_id=""
  reality_fingerprint="chrome"
  reality_spider_x="/"
  reality_tag=""
}

list_nodes() {
  local index=0
  local node_json
  local node_name
  local type
  local type_label
  local port
  local public_port
  local host
  local path
  local addr
  local target
  local target_port
  local short_id
  local detail

  if ! state_exists; then
    warn "尚未发现状态文件：${STATE_FILE}"
    return 0
  fi

  if (( $(node_count) == 0 )); then
    warn "当前没有已管理节点。"
    return 0
  fi

  ui_section "节点列表"
  printf '  %b%-4s %-18s %-16s %s%b\n' "${bold}" "ID" "名称" "类型" "详情" "${plain}"
  printf '  %b%s%b\n' "${dim}" "${UI_LINE}" "${plain}"

  while IFS= read -r node_json; do
    index=$((index + 1))
    node_name="$(node_display_name_from_json "${node_json}")"
    type="$(jq -r '.type' <<<"${node_json}")"
    type_label="$(node_type_label "${type}")"

    case "${type}" in
      vless-ws-tls|vmess-ws-tls|vless-xhttp-tls)
        port="$(jq -r '.port' <<<"${node_json}")"
        public_port="$(jq -r '.public_port // .port' <<<"${node_json}")"
        host="$(jq -r '.host' <<<"${node_json}")"
        path="$(jq -r '.path' <<<"${node_json}")"
        detail="listen:${port} public:${public_port} host:${host} path:${path}"
        printf '  %b%-4s%b %-18s %-16s %s\n' "${yellow}" "${index}" "${plain}" "${node_name}" "${type_label}" "${detail}"
        ;;
      vless-reality-vision)
        addr="$(jq -r '.addr' <<<"${node_json}")"
        port="$(jq -r '.port' <<<"${node_json}")"
        target="$(jq -r '.target' <<<"${node_json}")"
        target_port="$(jq -r '.target_port' <<<"${node_json}")"
        short_id="$(jq -r '.short_id' <<<"${node_json}")"
        detail="addr:${addr}:${port} target:${target}:${target_port} sid:${short_id}"
        printf '  %b%-4s%b %-18s %-16s %s\n' "${yellow}" "${index}" "${plain}" "${node_name}" "${type_label}" "${detail}"
        ;;
      *)
        printf '  %b%-4s%b %-18s %-16s %s\n' "${yellow}" "${index}" "${plain}" "${node_name}" "${type_label}" ""
        ;;
    esac
  done < <(jq -c '.nodes[]?' "${STATE_FILE}")
}

select_node_index() {
  local value
  local count
  local index
  local server_name

  ensure_state
  count="$(node_count)"
  (( count > 0 )) || die "当前没有可操作节点。"
  server_name="$(server_display_hostname)"
  list_nodes >&2

  while true; do
    value="$(prompt "请输入节点编号、名字或 tag")"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
      index=$((value - 1))
      if (( index >= 0 && index < count )); then
        printf '%s' "${index}"
        return
      fi
    else
      index="$(jq -r --arg value "${value}" --arg server_name "${server_name}" '
        def display_name($node):
          if $node.type == "vless-ws-tls" then
            "vl_" + $server_name
          elif $node.type == "vmess-ws-tls" then
            "vm_" + $server_name
          elif $node.type == "vless-xhttp-tls" then
            "xhttp_" + $server_name
          elif $node.type == "vless-reality-vision" then
            "real_" + $server_name
          else
            ($node.tag // $node.type // "node")
          end;
        .nodes
        | to_entries[]
        | select(.value.tag == $value or display_name(.value) == $value)
        | .key' "${STATE_FILE}" | head -n 1)"
      if [[ -n "${index}" ]]; then
        printf '%s' "${index}"
        return
      fi
    fi
    warn "未找到对应节点。"
  done
}

prompt_existing_or_new_ws_metadata() {
  if [[ -n "${ws_domain}" && -n "${ws_cert_file}" && -n "${ws_key_file}" ]]; then
    if confirm "继续使用当前 CDN TLS 域名和证书配置吗" "y"; then
      validate_cert_pair "${ws_cert_file}" "${ws_key_file}"
      return
    fi
  fi

  ws_domain=""
  ws_client_addr=""
  ws_client_port=443
  ws_cert_file=""
  ws_key_file=""
}

ensure_uuid_for_state() {
  load_state_globals
  if validate_uuid "${uuid}"; then
    return
  fi
  uuid="$(ask_uuid "$(generate_uuid)")"
  update_state_uuid
}

confirm_reinitialize_existing_nodes() {
  local count

  state_exists || return 0
  count="$(node_count)"
  (( count > 0 )) || return 0

  ui_section "检测到已有节点"
  ui_note "当前已有 ${count} 个本脚本管理的节点。选择继续后会重新初始化状态并重建节点配置。"
  list_nodes
  confirm "是否继续安装/重新初始化（回车默认继续）" "y" || die "已取消。"
}

cmd_install() {
  need_root
  check_system

  ui_title "安装/重新初始化" "安装或更新 Xray，并重新初始化本脚本管理的节点。"
  confirm_reinitialize_existing_nodes
  tmp_dir="$(mktemp -d)"
  install_dependencies
  install_xray

  reset_selection_flags
  select_protocols
  uuid="$(ask_uuid "$(generate_uuid)")"
  collect_ws_settings
  collect_reality_settings

  reset_state_file
  append_selected_nodes_to_state
  rebuild_config_from_state
  restart_xray
  write_links_from_state
  print_state_summary "安装完成"
}

cmd_add() {
  need_root
  check_system
  resolve_xray_bin
  tmp_dir="$(mktemp -d)"
  ensure_state
  load_state_globals
  ensure_uuid_for_state

  ui_title "新增节点" "在现有状态上追加节点，并重建 Xray 配置。"
  reset_selection_flags
  load_state_globals
  select_protocols
  if (( vless_ws_enabled || vmess_ws_enabled || vless_xhttp_enabled )); then
    prompt_existing_or_new_ws_metadata
  fi
  collect_ws_settings
  collect_reality_settings
  update_state_ws_metadata
  append_selected_nodes_to_state
  rebuild_config_from_state
  restart_xray
  write_links_from_state
  print_state_summary "新增节点完成"
}

cmd_list() {
  list_nodes
}

modify_ws_node() {
  local index="$1"
  local type="$2"
  local current_port
  local current_public_port
  local current_path
  local current_host
  local new_port
  local new_public_port
  local new_path
  local new_host
  local tmp_state
  local label

  load_state_globals
  current_port="$(jq -r --argjson index "${index}" '.nodes[$index].port' "${STATE_FILE}")"
  current_public_port="$(jq -r --argjson index "${index}" '.nodes[$index].public_port // .nodes[$index].port' "${STATE_FILE}")"
  current_path="$(jq -r --argjson index "${index}" '.nodes[$index].path' "${STATE_FILE}")"
  current_host="$(jq -r --argjson index "${index}" '.nodes[$index].host' "${STATE_FILE}")"
  case "${type}" in
    vless-ws-tls) label="VLESS WS" ;;
    vmess-ws-tls) label="VMess WS" ;;
    vless-xhttp-tls) label="VLESS XHTTP" ;;
    *) label="${type}" ;;
  esac

  ui_section "修改 ${label} TLS"
  new_port="$(ask_port "连接到服务器的端口，也就是重写到的端口" "${current_port}")"
  new_public_port="${current_public_port}"
  new_path="$(ask_ws_path "${label}" "${current_path}")"
  new_host="$(ask_domain "${label} Host/SNI" "${current_host}")"

  if confirm "是否同时更新 CDN TLS 全局域名、客户端地址、客户端端口或证书" "n"; then
    ws_domain="$(ask_domain "请输入已接入 Cloudflare 的域名" "${ws_domain}")"
    ws_client_addr="$(prompt "客户端连接地址，可填优选域名/IP" "${DEFAULT_WS_CLIENT_ADDR}")"
    ws_client_port="$(ask_ws_client_port "${ws_client_port:-443}")"
    configure_certificate
    update_state_ws_metadata
    sync_ws_public_port_in_state
    new_public_port="${ws_client_port}"
  elif [[ -n "${ws_client_port:-}" ]]; then
    new_public_port="${ws_client_port}"
  fi

  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq \
    --argjson index "${index}" \
    --argjson port "${new_port}" \
    --argjson public_port "${new_public_port}" \
    --arg path "${new_path}" \
    --arg host "${new_host}" \
    '.nodes[$index].port = $port
     | .nodes[$index].public_port = $public_port
     | .nodes[$index].path = $path
     | .nodes[$index].host = $host
     | .nodes[$index].tag = (.nodes[$index].type + "-" + ($port | tostring))' \
    "${STATE_FILE}" >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"
}

modify_reality_node() {
  local index="$1"
  local current_addr
  local current_port
  local current_target
  local current_target_port
  local current_short_id
  local target_input
  local new_addr
  local new_port
  local new_short_id
  local tmp_state

  current_addr="$(jq -r --argjson index "${index}" '.nodes[$index].addr' "${STATE_FILE}")"
  current_port="$(jq -r --argjson index "${index}" '.nodes[$index].port' "${STATE_FILE}")"
  current_target="$(jq -r --argjson index "${index}" '.nodes[$index].target' "${STATE_FILE}")"
  current_target_port="$(jq -r --argjson index "${index}" '.nodes[$index].target_port' "${STATE_FILE}")"
  current_short_id="$(jq -r --argjson index "${index}" '.nodes[$index].short_id' "${STATE_FILE}")"

  ui_section "修改 Reality Vision"
  new_addr="$(prompt "Reality 客户端连接地址/IP" "${current_addr}")"
  [[ -n "${new_addr}" ]] || die "Reality 客户端连接地址不能为空。"
  new_port="$(ask_port "Reality" "${current_port}")"
  target_input="$(prompt "Reality 目标域名，可带端口" "${current_target}:${current_target_port}")"
  parse_reality_target "${target_input}"
  new_short_id="$(ask_short_id "${current_short_id}")"

  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq \
    --argjson index "${index}" \
    --argjson port "${new_port}" \
    --arg addr "${new_addr}" \
    --arg target "${reality_target}" \
    --argjson target_port "${reality_target_port}" \
    --arg short_id "${new_short_id}" \
    '.nodes[$index].port = $port
     | .nodes[$index].addr = $addr
     | .nodes[$index].target = $target
     | .nodes[$index].target_port = $target_port
     | .nodes[$index].short_id = $short_id
     | .nodes[$index].tag = ("vless-reality-vision-" + ($port | tostring))' \
    "${STATE_FILE}" >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"
}

cmd_modify() {
  local index
  local type

  need_root
  check_system
  resolve_xray_bin
  tmp_dir="$(mktemp -d)"
  ensure_state
  ui_title "修改节点" "选择一个已有节点后更新端口、Path、Host/SNI 或 Reality 参数。"
  index="$(select_node_index)"
  type="$(jq -r --argjson index "${index}" '.nodes[$index].type' "${STATE_FILE}")"

  case "${type}" in
    vless-ws-tls|vmess-ws-tls|vless-xhttp-tls)
      modify_ws_node "${index}" "${type}"
      ;;
    vless-reality-vision)
      modify_reality_node "${index}"
      ;;
    *)
      die "暂不支持修改未知节点类型：${type}"
      ;;
  esac

  rebuild_config_from_state
  restart_xray
  write_links_from_state
  print_state_summary "修改节点完成"
}

cmd_delete() {
  local index
  local node_json
  local node_name
  local tmp_state

  need_root
  check_system
  resolve_xray_bin
  tmp_dir="$(mktemp -d)"
  ensure_state
  ui_title "删除节点" "选择一个已管理节点并重建 Xray 配置，不卸载 Xray。"
  index="$(select_node_index)"
  node_json="$(jq -c --argjson index "${index}" '.nodes[$index]' "${STATE_FILE}")"
  node_name="$(node_display_name_from_json "${node_json}")"

  confirm "确认删除节点 ${node_name}（不卸载 Xray）吗" "n" || die "已取消。"
  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq --argjson index "${index}" 'del(.nodes[$index])' "${STATE_FILE}" >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"

  rebuild_config_from_state
  restart_xray
  write_links_from_state
  print_state_summary "删除节点完成"
}

cmd_delete_all() {
  local tmp_state

  need_root
  check_system
  resolve_xray_bin
  tmp_dir="$(mktemp -d)"
  ensure_state
  ui_title "清空节点" "此操作只清空本脚本管理的节点并重建空配置，不卸载 Xray。"
  list_nodes

  confirm "确认清空所有已管理节点（不卸载 Xray）并重建空配置吗" "n" || die "已取消。"
  tmp_state="$(mktemp "${STATE_DIR}/state.XXXXXX")"
  jq '.nodes = []' "${STATE_FILE}" >"${tmp_state}"
  chmod 600 "${tmp_state}" 2>/dev/null || true
  mv "${tmp_state}" "${STATE_FILE}"

  rebuild_config_from_state
  restart_xray
  write_links_from_state
  print_state_summary "已删除所有节点"
}

cmd_links() {
  show_qr_in_links=0
  ensure_state
  if confirm "是否显示二维码" "n"; then
    show_qr_in_links=1
  fi
  write_links_from_state
  ui_title "节点链接" "链接文件：${LINKS_FILE}"
  cat "${LINKS_FILE}"
}

cmd_restart() {
  need_root
  restart_xray
  log "Xray 服务已重启。"
}

cmd_update_xray() {
  update_xray_core
}

cmd_uninstall() {
  need_root
  ui_title "卸载 Xray" "将调用官方脚本移除 Xray，并删除状态、链接和配置目录。"
  confirm "确认卸载 Xray，并移除状态文件、链接文件和配置目录 ${CONFIG_DIR} 吗" "y" || die "已取消。"

  if [[ -x /usr/local/bin/xray ]]; then
    bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ remove || true
  fi
  rm -f "${STATE_FILE}" "${LINKS_FILE}"
  rm -rf "${CONFIG_DIR}"

  warn "已移除状态文件、链接文件和配置目录 ${CONFIG_DIR}。"
}

print_usage() {
  cat <<'EOF'
Cloudflare Xray Node 管理脚本

用法：
  install.sh [command]

命令：
  menu        打开交互菜单，默认命令
  install     安装/更新 Xray，并重新初始化已管理节点
  update-xray 独立检查并更新 Xray Core，不重新初始化节点
  list        查看已安装节点
  add         新增 VLESS WS TLS、VMess WS TLS、VLESS XHTTP TLS 或 Reality 节点
  modify      修改已有节点配置
  delete      删除一个已管理节点（不卸载 Xray）并重建配置
  delete-all  清空所有已管理节点（不卸载 Xray）并重建空配置
  links       重新生成并显示节点链接
  restart     重启 Xray 服务
  uninstall   卸载 Xray，并移除本脚本状态和链接文件
  help        显示帮助
EOF
}

show_menu() {
  local choice
  local count

  ui_clear_screen
  while true; do
    count="$(menu_node_count)"
    ui_title "Cloudflare Xray Node" "VLESS/VMess WS TLS + VLESS XHTTP TLS + Reality Vision 管理脚本"
    ui_kv "Xray 服务" "$(xray_service_status_text)"
    ui_kv "Xray 版本" "$(xray_update_status_text)"
    ui_kv "状态文件" "$(state_status_text)  ${STATE_FILE}"
    ui_kv "节点数量" "${count}"
    ui_kv "链接文件" "$(links_status_text)  ${LINKS_FILE}"

    echo
    ui_group "节点管理"
    ui_option "1" "安装/重新初始化"
    ui_option "2" "查看节点"
    ui_option "3" "新增节点"
    ui_option "4" "修改节点"
    ui_option "5" "删除节点"

    echo
    ui_group "服务管理"
    ui_option "6" "显示节点链接"
    ui_option "7" "重启 Xray"
    ui_option "9" "更新 Xray"

    echo
    ui_group "危险操作"
    ui_option "8" "卸载"
    ui_option "10" "清空所有节点"
    ui_option "0" "退出"
    choice="$(prompt "请选择")"
    case "${choice}" in
      1) run_menu_action cmd_install ;;
      2) run_menu_action cmd_list ;;
      3) run_menu_action cmd_add ;;
      4) run_menu_action cmd_modify ;;
      5) run_menu_action cmd_delete ;;
      6) run_menu_action cmd_links ;;
      7) run_menu_action cmd_restart ;;
      8) run_menu_action cmd_uninstall ;;
      9) run_menu_action cmd_update_xray ;;
      10) run_menu_action cmd_delete_all ;;
      0) return ;;
      *)
        warn "未知选项：${choice}"
        pause_for_enter
        ui_clear_screen
        ;;
    esac
  done
}

dispatch_command() {
  local command="${1:-menu}"

  case "${command}" in
    menu) show_menu ;;
    install) cmd_install ;;
    update-xray) cmd_update_xray ;;
    list) cmd_list ;;
    add) cmd_add ;;
    modify) cmd_modify ;;
    delete) cmd_delete ;;
    delete-all) cmd_delete_all ;;
    links) cmd_links ;;
    restart) cmd_restart ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) print_usage ;;
    *)
      print_usage
      die "未知命令：${command}"
      ;;
  esac
}

if [[ "${CXN_TEST_MODE:-0}" != "1" ]]; then
  dispatch_command "$@"
fi

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
XRAY_SERVICE_NAME="${CXN_XRAY_SERVICE_NAME:-xray}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
cyan='\033[0;36m'
plain='\033[0m'

tmp_dir=""
xray_bin=""
uuid=""
ws_domain=""
ws_cert_file=""
ws_key_file=""
ws_client_addr=""
vless_ws_enabled=0
vmess_ws_enabled=0
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

reality_port=443
reality_addr=""
reality_target="learn.microsoft.com"
reality_target_port=443
reality_private_key=""
reality_public_key=""
reality_short_id=""
reality_fingerprint="chrome"
reality_spider_x="/"
reality_tag=""

CLOUDFLARE_WS_TLS_PORTS="443 8443 2053 2083 2087 2096"

log() {
  echo -e "${green}$*${plain}" >&2
}

warn() {
  echo -e "${yellow}$*${plain}" >&2
}

err() {
  echo -e "${red}$*${plain}" >&2
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

  if [[ -n "${default}" ]]; then
    read -r -p "$(echo -e "${cyan}${message}${plain} [${default}]: ")" value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$(echo -e "${cyan}${message}${plain}: ")" value
    printf '%s' "${value}"
  fi
}

confirm() {
  local message="$1"
  local default="${2:-y}"
  local suffix="[Y/n]"
  local value

  [[ "${default}" == "n" ]] && suffix="[y/N]"
  read -r -p "$(echo -e "${cyan}${message}${plain} ${suffix}: ")" value
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
  apt-get install -y curl wget jq qrencode ca-certificates openssl lsof iproute2 coreutils
}

install_xray() {
  local install_user

  log "安装或更新 Xray 最新稳定版..."
  install_user="$(desired_xray_install_user)"
  bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ install -u "${install_user}"
  bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ install-geodata

  resolve_xray_bin

  mkdir -p "${CONFIG_DIR}" "${CERT_DIR}"
}

resolve_xray_bin() {
  if command -v xray >/dev/null 2>&1; then
    xray_bin="$(command -v xray)"
  elif [[ -x /usr/local/bin/xray ]]; then
    xray_bin="/usr/local/bin/xray"
  else
    die "未找到 xray 可执行文件，请先运行 install 或确认 Xray 已安装。"
  fi
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

  while true; do
    value="$(prompt "${label}端口" "${default}")"
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
    value="$(normalize_ws_path "$(prompt "${label} WS Path，回车使用随机路径" "${default}")")"
    if validate_ws_path "${value}"; then
      printf '%s' "${value}"
      return
    fi
    warn "WS Path 必须以 / 开头，不能只填 /，也不能包含空白字符。"
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
  warn "请粘贴 ${label} PEM 内容；脚本会在检测到 END 边界行后自动结束。"
  printf '%b\n' "${yellow}支持标准多行 PEM，也支持带字面 \\n 的单行内容。${plain}" >&2
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

configure_certificate() {
  local mode
  local safe_domain
  local cert_path
  local key_path

  mkdir -p "${CERT_DIR}"
  echo
  echo "证书输入方式："
  echo "  1) 填写已有证书/私钥文件路径"
  echo "  2) 粘贴证书/私钥 PEM 内容并由脚本保存"

  while true; do
    mode="$(prompt "请选择证书输入方式" "1")"
    case "${mode}" in
      1)
        cert_path="$(abs_path "$(prompt "请输入证书文件路径 certificateFile")")"
        key_path="$(abs_path "$(prompt "请输入私钥文件路径 keyFile")")"
        validate_cert_pair "${cert_path}" "${key_path}"
        ensure_managed_ws_cert_pair "${cert_path}" "${key_path}"
        return
        ;;
      2)
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
      *)
        warn "请输入 1 或 2。"
        ;;
    esac
  done
}

select_protocols() {
  local selected

  echo
  echo "请选择要启用的节点，多个选项可用逗号或空格分隔："
  echo "  1) VLESS + WebSocket + TLS"
  echo "  2) VMess + WebSocket + TLS"
  echo "  3) VLESS + Reality + Vision"
  selected="$(prompt "选择" "1,2,3")"

  selected="${selected//,/ }"
  for item in ${selected}; do
    case "${item}" in
      1) vless_ws_enabled=1 ;;
      2) vmess_ws_enabled=1 ;;
      3) reality_enabled=1 ;;
      *) die "未知选项：${item}" ;;
    esac
  done

  (( vless_ws_enabled || vmess_ws_enabled || reality_enabled )) || die "至少需要选择一个节点。"
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

  if (( vless_ws_enabled || vmess_ws_enabled )); then
    echo
    log "配置 WebSocket + TLS 节点..."
    ws_domain="$(ask_domain "请输入已接入 Cloudflare 的域名" "${ws_domain}")"
    ws_client_addr="$(prompt "客户端连接地址，可填优选域名/IP，回车使用上面的域名" "${ws_client_addr:-$ws_domain}")"

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

    if (( vless_ws_enabled )); then
      vless_ws_port="$(ask_port "VLESS WS TLS" "8443")"
      vless_ws_public_port="$(resolve_ws_public_port "VLESS WS TLS" "${vless_ws_port}" "${vless_ws_public_port}")"
      default_path="${vless_ws_path:-$(generate_random_ws_path vless)}"
      vless_ws_path="$(ask_ws_path "VLESS" "${default_path}")"
      vless_ws_host="$(ask_domain "VLESS WS Host/SNI" "${ws_domain}")"
      vless_ws_tag="vless-ws-tls-${vless_ws_port}"
    fi

    if (( vmess_ws_enabled )); then
      vmess_ws_port="$(ask_port "VMess WS TLS" "2096")"
      vmess_ws_public_port="$(resolve_ws_public_port "VMess WS TLS" "${vmess_ws_port}" "${vmess_ws_public_port}")"
      default_path="${vmess_ws_path:-$(generate_random_ws_path vmess)}"
      vmess_ws_path="$(ask_ws_path "VMess" "${default_path}")"
      vmess_ws_host="$(ask_domain "VMess WS Host/SNI" "${ws_domain}")"
      vmess_ws_tag="vmess-ws-tls-${vmess_ws_port}"
    fi
  fi
}

collect_reality_settings() {
  local detected_ip
  local target_input
  local default_short_id

  if (( reality_enabled )); then
    echo
    log "配置 Reality 节点..."
    detected_ip="$(detect_public_ip)"
    reality_addr="$(prompt "Reality 客户端连接地址/IP" "${detected_ip}")"
    [[ -n "${reality_addr}" ]] || die "Reality 客户端连接地址不能为空。"

    reality_port="$(ask_port "Reality" "443")"
    target_input="$(prompt "Reality 目标域名，可带端口" "learn.microsoft.com:443")"
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
    --arg cert "${ws_cert_file}" \
    --arg key "${ws_key_file}" \
    '{
      version: 1,
      uuid: $uuid,
      ws: {
        domain: $domain,
        client_addr: $client_addr,
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
    --arg cert "${ws_cert_file}" \
    --arg key "${ws_key_file}" \
    '.uuid = $uuid
     | .ws.domain = $domain
     | .ws.client_addr = $client_addr
     | .ws.certificate_file = $cert
     | .ws.key_file = $key' \
    "${STATE_FILE}" >"${tmp_state}"
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

  if (( reality_enabled )); then
    reality_tag="$(make_unique_tag "vless-reality-vision-${reality_port}")"
    append_node_json_to_state "$(reality_node_json)"
  fi
}

validate_state_for_rebuild() {
  ensure_state
  load_state_globals
  if jq -e '.nodes[]? | select(.type == "vless-ws-tls" or .type == "vmess-ws-tls")' "${STATE_FILE}" >/dev/null; then
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

write_links_from_state() {
  local node_json
  local type
  local tag
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
    node_uuid="$(jq -r '.uuid' <<<"${node_json}")"

    case "${type}" in
      vless-ws-tls)
        addr="$(format_address_for_url "$(jq -r '.ws.client_addr // .ws.domain // ""' "${STATE_FILE}")")"
        port="$(jq -r '.public_port // .port' <<<"${node_json}")"
        host="$(jq -r '.host' <<<"${node_json}")"
        path="$(jq -r '.path' <<<"${node_json}")"
        path_encoded="$(urlencode "${path}")"
        tag_encoded="$(urlencode "${tag}")"
        link="vless://${node_uuid}@${addr}:${port}?encryption=none&type=ws&security=tls&sni=${host}&host=${host}&path=${path_encoded}#${tag_encoded}"
        {
          echo "---------- ${tag} ----------"
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
          --arg ps "${tag}" \
          '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
        link="vmess://$(printf '%s' "${vmess_json}" | base64_one_line)"
        {
          echo "---------- ${tag} ----------"
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
        tag_encoded="$(urlencode "${tag}")"
        link="vless://${node_uuid}@${addr}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${target}&fp=${fingerprint}&pbk=${public_key}&sid=${short_id}&spx=${spider_encoded}#${tag_encoded}"
        {
          echo "---------- ${tag} ----------"
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

  if command -v qrencode >/dev/null 2>&1; then
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

print_state_summary() {
  local action="${1:-操作完成}"
  local count

  count="$(node_count)"
  echo
  log "${action}。"
  echo "状态文件：${STATE_FILE}"
  echo "Xray 配置文件：${CONFIG_FILE}"
  echo "节点链接文件：${LINKS_FILE}"
  echo "当前节点数量：${count}"

  if (( count > 0 )); then
    echo
    warn "Cloudflare CDN 提醒："
    echo "  - WS+TLS 节点用于 Cloudflare 代理；Reality 节点是直连 TCP，不走 CDN。"
    echo "  - Cloudflare HTTPS 标准端口：443、2053、2083、2087、2096、8443。"
    echo "  - 节点列表里的 port 是源站实际监听端口；public 是分享链接里的客户端公开端口。"
    echo "  - 当 public 与 port 不一致时，请确认你已在 Cloudflare Origin Rule 或前置代理里完成回源映射。"
    echo
    echo "节点列表："
    list_nodes
    if [[ -s "${LINKS_FILE}" ]]; then
      echo
      echo "节点链接："
      cat "${LINKS_FILE}"
    fi
  fi
}

reset_selection_flags() {
  vless_ws_enabled=0
  vmess_ws_enabled=0
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
  reality_port=443
  reality_addr=""
  reality_target="learn.microsoft.com"
  reality_target_port=443
  reality_private_key=""
  reality_public_key=""
  reality_short_id=""
  reality_fingerprint="chrome"
  reality_spider_x="/"
  reality_tag=""
}

list_nodes() {
  if ! state_exists; then
    warn "尚未发现状态文件：${STATE_FILE}"
    return 0
  fi

  if (( $(node_count) == 0 )); then
    warn "当前没有已管理节点。"
    return 0
  fi

  jq -r '
    .nodes
    | to_entries[]
    | .key as $idx
    | .value as $node
    | if $node.type == "vless-ws-tls" or $node.type == "vmess-ws-tls" then
        "\($idx + 1)) \($node.tag)  \($node.type)  port:\($node.port) public:\($node.public_port // $node.port) host:\($node.host) path:\($node.path)"
      elif $node.type == "vless-reality-vision" then
        "\($idx + 1)) \($node.tag)  \($node.type)  addr:\($node.addr):\($node.port) target:\($node.target):\($node.target_port) sid:\($node.short_id)"
      else
        "\($idx + 1)) \($node.tag)  \($node.type)"
      end' "${STATE_FILE}"
}

select_node_index() {
  local value
  local count
  local index

  ensure_state
  count="$(node_count)"
  (( count > 0 )) || die "当前没有可操作节点。"
  list_nodes

  while true; do
    value="$(prompt "请输入节点编号或 tag")"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
      index=$((value - 1))
      if (( index >= 0 && index < count )); then
        printf '%s' "${index}"
        return
      fi
    else
      index="$(jq -r --arg tag "${value}" '
        .nodes
        | to_entries[]
        | select(.value.tag == $tag)
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
    if confirm "继续使用当前 WS 域名和证书配置吗" "y"; then
      validate_cert_pair "${ws_cert_file}" "${ws_key_file}"
      return
    fi
  fi

  ws_domain=""
  ws_client_addr=""
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

cmd_install() {
  need_root
  check_system

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

  reset_selection_flags
  load_state_globals
  select_protocols
  if (( vless_ws_enabled || vmess_ws_enabled )); then
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
  [[ "${type}" == "vless-ws-tls" ]] && label="VLESS WS TLS" || label="VMess WS TLS"

  new_port="$(ask_port "${label}" "${current_port}")"
  new_public_port="$(resolve_ws_public_port "${label}" "${new_port}" "${current_public_port}")"
  new_path="$(ask_ws_path "${label}" "${current_path}")"
  new_host="$(ask_domain "${label} Host/SNI" "${current_host}")"

  if confirm "是否同时更新 WS 全局域名、客户端地址或证书" "n"; then
    ws_domain="$(ask_domain "请输入已接入 Cloudflare 的域名" "${ws_domain}")"
    ws_client_addr="$(prompt "客户端连接地址，可填优选域名/IP，回车使用上面的域名" "${ws_client_addr:-$ws_domain}")"
    configure_certificate
    update_state_ws_metadata
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
  index="$(select_node_index)"
  type="$(jq -r --argjson index "${index}" '.nodes[$index].type' "${STATE_FILE}")"

  case "${type}" in
    vless-ws-tls|vmess-ws-tls)
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

cmd_delete_all() {
  local tmp_state

  need_root
  check_system
  resolve_xray_bin
  tmp_dir="$(mktemp -d)"
  ensure_state
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
  ensure_state
  write_links_from_state
  cat "${LINKS_FILE}"
}

cmd_restart() {
  need_root
  restart_xray
}

cmd_uninstall() {
  need_root
  confirm "确认卸载 Xray 并移除本脚本状态文件吗" "y" || die "已取消。"

  if [[ -x /usr/local/bin/xray ]]; then
    bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ remove || true
  fi
  rm -f "${STATE_FILE}" "${LINKS_FILE}"

  if [[ -d "${CERT_DIR}" ]]; then
    if confirm "是否同时删除证书目录 ${CERT_DIR}" "y"; then
      rm -rf "${CERT_DIR}"
      warn "已移除状态文件、链接文件和证书目录。"
    else
      warn "已移除状态文件和链接文件。证书目录 ${CERT_DIR} 已保留。"
    fi
  else
    warn "已移除状态文件和链接文件。未检测到证书目录。"
  fi
}

print_usage() {
  cat <<'EOF'
Cloudflare Xray Node 管理脚本

用法：
  install.sh [command]

命令：
  menu        打开交互菜单，默认命令
  install     安装/更新 Xray，并重新初始化已管理节点
  list        查看已安装节点
  add         新增 VLESS WS TLS、VMess WS TLS 或 Reality 节点
  modify      修改已有节点配置
  delete-all  清空所有已管理节点（不卸载 Xray）并重建空配置
  links       重新生成并显示节点链接
  restart     重启 Xray 服务
  uninstall   卸载 Xray，并移除本脚本状态和链接文件
  help        显示帮助
EOF
}

show_menu() {
  local choice

  while true; do
    echo
    echo "Cloudflare Xray Node 管理菜单"
    echo "  1) 安装/重新初始化节点"
    echo "  2) 查看已安装节点"
    echo "  3) 新增节点"
    echo "  4) 修改节点配置"
    echo "  5) 清空所有节点"
    echo "  6) 显示节点链接"
    echo "  7) 重启 Xray"
    echo "  8) 卸载"
    echo "  0) 退出"
    choice="$(prompt "请选择")"
    case "${choice}" in
      1) cmd_install ;;
      2) cmd_list ;;
      3) cmd_add ;;
      4) cmd_modify ;;
      5) cmd_delete_all ;;
      6) cmd_links ;;
      7) cmd_restart ;;
      8) cmd_uninstall ;;
      0) return ;;
      *) warn "未知选项：${choice}" ;;
    esac
  done
}

dispatch_command() {
  local command="${1:-menu}"

  case "${command}" in
    menu) show_menu ;;
    install) cmd_install ;;
    list) cmd_list ;;
    add) cmd_add ;;
    modify) cmd_modify ;;
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

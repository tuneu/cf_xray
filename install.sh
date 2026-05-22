#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_DIR="${CONFIG_DIR}/certs"
LINKS_FILE="/root/xray-node-links.txt"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

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
vless_ws_client_port=8443
vless_ws_path="/vlessws"
vless_ws_host=""

vmess_ws_port=2096
vmess_ws_client_port=2096
vmess_ws_path="/vmessws"
vmess_ws_host=""

reality_port=443
reality_addr=""
reality_target="learn.microsoft.com"
reality_target_port=443
reality_private_key=""
reality_public_key=""
reality_short_id=""
reality_fingerprint="chrome"
reality_spider_x="/"

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
  log "安装或更新 Xray 最新稳定版..."
  bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ install
  bash -c "$(curl -fsSL "${XRAY_INSTALL_URL}")" @ install-geodata

  if command -v xray >/dev/null 2>&1; then
    xray_bin="$(command -v xray)"
  elif [[ -x /usr/local/bin/xray ]]; then
    xray_bin="/usr/local/bin/xray"
  else
    die "Xray 安装后仍未找到 xray 可执行文件。"
  fi

  mkdir -p "${CONFIG_DIR}" "${CERT_DIR}"
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

ask_client_port() {
  local label="$1"
  local default="$2"
  local value

  while true; do
    value="$(prompt "${label}客户端连接端口" "${default}")"
    if validate_port_number "${value}"; then
      printf '%s' "${value}"
      return
    fi
    warn "客户端连接端口必须是 1-65535 的数字。"
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
  local required_pattern="$3"
  local line
  local content=""

  echo
  warn "请粘贴 ${label} PEM 内容，粘贴完成后单独输入一行 END。"
  while IFS= read -r line; do
    [[ "${line}" == "END" ]] && break
    content+="${line}"$'\n'
  done

  if ! grep -Eq "${required_pattern}" <<<"${content}"; then
    die "${label} 内容看起来不是有效 PEM。"
  fi

  umask 077
  printf '%s' "${content}" >"${output_file}"
}

safe_file_name() {
  local value="$1"
  printf '%s' "${value}" | tr -c 'A-Za-z0-9._-' '_'
}

configure_certificate() {
  local mode
  local safe_domain
  local cert_path
  local key_path

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
        ws_cert_file="${cert_path}"
        ws_key_file="${key_path}"
        return
        ;;
      2)
        safe_domain="$(safe_file_name "${ws_domain}")"
        cert_path="${CERT_DIR}/${safe_domain}.crt"
        key_path="${CERT_DIR}/${safe_domain}.key"
        read_pem_block "证书 certificate" "${cert_path}" "BEGIN .*CERTIFICATE"
        read_pem_block "私钥 private key" "${key_path}" "BEGIN .*PRIVATE KEY"
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

generate_reality_keys() {
  local output
  local key_seed

  key_seed="$(printf '%s' "${uuid}" | md5sum | head -c 32 | base64 -w 0 | tr '+/' '-_' | tr -d '=')"
  output="$("${xray_bin}" x25519 -i "${key_seed}" 2>/dev/null)"
  parse_x25519_output "${output}"
}

generate_short_id() {
  printf '%s' "${uuid}" | sha1sum | head -c 16
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
  if (( vless_ws_enabled || vmess_ws_enabled )); then
    echo
    log "配置 WebSocket + TLS 节点..."
    ws_domain="$(ask_domain "请输入已接入 Cloudflare 的域名")"
    ws_client_addr="$(prompt "客户端连接地址，可填优选域名/IP，回车使用上面的域名" "${ws_domain}")"
    configure_certificate

    if (( vless_ws_enabled )); then
      vless_ws_port="$(ask_port "VLESS WS TLS" "8443")"
      vless_ws_client_port="$(ask_client_port "VLESS WS TLS" "${vless_ws_port}")"
      vless_ws_path="$(normalize_ws_path "$(prompt "VLESS WS Path" "${vless_ws_path}")")"
      vless_ws_host="$(ask_domain "VLESS WS Host/SNI" "${ws_domain}")"
    fi

    if (( vmess_ws_enabled )); then
      vmess_ws_port="$(ask_port "VMess WS TLS" "2096")"
      vmess_ws_client_port="$(ask_client_port "VMess WS TLS" "${vmess_ws_port}")"
      vmess_ws_path="$(normalize_ws_path "$(prompt "VMess WS Path" "${vmess_ws_path}")")"
      vmess_ws_host="$(ask_domain "VMess WS Host/SNI" "${ws_domain}")"
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
  fi
}

make_vless_ws_inbound() {
  jq -n \
    --argjson port "${vless_ws_port}" \
    --arg uuid "${uuid}" \
    --arg path "${vless_ws_path}" \
    --arg host "${vless_ws_host}" \
    --arg cert "${ws_cert_file}" \
    --arg key "${ws_key_file}" \
    '{
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      tag: "vless-ws-tls",
      settings: {
        clients: [{ id: $uuid, email: "vless-ws-tls" }],
        decryption: "none"
      },
      streamSettings: {
        network: "websocket",
        security: "tls",
        tlsSettings: {
          minVersion: "1.2",
          certificates: [{ certificateFile: $cert, keyFile: $key }]
        },
        wsSettings: { path: $path, host: $host }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"]
      }
    }' >"${tmp_dir}/10_vless_ws_tls.json"
}

make_vmess_ws_inbound() {
  jq -n \
    --argjson port "${vmess_ws_port}" \
    --arg uuid "${uuid}" \
    --arg path "${vmess_ws_path}" \
    --arg host "${vmess_ws_host}" \
    --arg cert "${ws_cert_file}" \
    --arg key "${ws_key_file}" \
    '{
      listen: "0.0.0.0",
      port: $port,
      protocol: "vmess",
      tag: "vmess-ws-tls",
      settings: {
        clients: [{ id: $uuid, alterId: 0, email: "vmess-ws-tls" }]
      },
      streamSettings: {
        network: "websocket",
        security: "tls",
        tlsSettings: {
          minVersion: "1.2",
          certificates: [{ certificateFile: $cert, keyFile: $key }]
        },
        wsSettings: { path: $path, host: $host }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"]
      }
    }' >"${tmp_dir}/20_vmess_ws_tls.json"
}

make_reality_inbound() {
  jq -n \
    --argjson port "${reality_port}" \
    --arg uuid "${uuid}" \
    --arg target "${reality_target}:${reality_target_port}" \
    --arg server_name "${reality_target}" \
    --arg private_key "${reality_private_key}" \
    --arg short_id "${reality_short_id}" \
    '{
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      tag: "vless-reality-vision",
      settings: {
        clients: [{ id: $uuid, flow: "xtls-rprx-vision", email: "vless-reality-vision" }],
        decryption: "none"
      },
      streamSettings: {
        network: "raw",
        security: "reality",
        realitySettings: {
          show: false,
          target: $target,
          xver: 0,
          serverNames: [$server_name],
          privateKey: $private_key,
          shortIds: [$short_id]
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic"]
      }
    }' >"${tmp_dir}/30_vless_reality_vision.json"
}

build_config() {
  local config_tmp="${tmp_dir}/config.json"

  (( vless_ws_enabled )) && make_vless_ws_inbound
  (( vmess_ws_enabled )) && make_vmess_ws_inbound
  (( reality_enabled )) && make_reality_inbound

  jq -s '{
    log: {
      access: "/var/log/xray/access.log",
      error: "/var/log/xray/error.log",
      loglevel: "warning"
    },
    inbounds: .,
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
  }' "${tmp_dir}"/*.json >"${config_tmp}"

  test_xray_config "${config_tmp}"

  if [[ -f "${CONFIG_FILE}" ]]; then
    cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0644 "${config_tmp}" "${CONFIG_FILE}"
}

test_xray_config() {
  local config_file="$1"
  local output=""
  local fallback_output=""

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

write_links() {
  local addr
  local path_encoded
  local tag_encoded
  local vmess_json
  local reality_url_addr
  local spider_encoded

  : >"${LINKS_FILE}"
  chmod 600 "${LINKS_FILE}"

  if (( vless_ws_enabled )); then
    addr="$(format_address_for_url "${ws_client_addr}")"
    path_encoded="$(urlencode "${vless_ws_path}")"
    tag_encoded="$(urlencode "VLESS-WS-TLS-${vless_ws_host}")"
    {
      echo "---------- VLESS WS TLS ----------"
      echo "vless://${uuid}@${addr}:${vless_ws_client_port}?encryption=none&type=ws&security=tls&sni=${vless_ws_host}&host=${vless_ws_host}&path=${path_encoded}#${tag_encoded}"
      echo
    } >>"${LINKS_FILE}"
  fi

  if (( vmess_ws_enabled )); then
    vmess_json="$(jq -nc \
      --arg add "${ws_client_addr}" \
      --arg port "${vmess_ws_client_port}" \
      --arg id "${uuid}" \
      --arg host "${vmess_ws_host}" \
      --arg path "${vmess_ws_path}" \
      --arg ps "VMess-WS-TLS-${vmess_ws_host}" \
      '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
    {
      echo "---------- VMess WS TLS ----------"
      printf 'vmess://'
      printf '%s' "${vmess_json}" | base64_one_line
      echo
      echo
    } >>"${LINKS_FILE}"
  fi

  if (( reality_enabled )); then
    reality_url_addr="$(format_address_for_url "${reality_addr}")"
    spider_encoded="$(urlencode "${reality_spider_x}")"
    tag_encoded="$(urlencode "VLESS-Reality-${reality_addr}")"
    {
      echo "---------- VLESS Reality Vision ----------"
      echo "vless://${uuid}@${reality_url_addr}:${reality_port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${reality_target}&fp=${reality_fingerprint}&pbk=${reality_public_key}&sid=${reality_short_id}&spx=${spider_encoded}#${tag_encoded}"
      echo
    } >>"${LINKS_FILE}"
  fi
}

restart_xray() {
  log "重启 Xray 服务..."
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
}

print_summary() {
  echo
  log "安装完成。"
  echo "Xray 配置文件：${CONFIG_FILE}"
  echo "节点链接文件：${LINKS_FILE}"

  if (( vless_ws_enabled || vmess_ws_enabled )); then
    echo
    warn "Cloudflare CDN 提醒："
    echo "  - SSL/TLS 模式建议使用 Full 或 Full (strict)。"
    echo "  - 如客户端端口和源站监听端口不同，请用 Origin Rule 将 Host + Path 回源到对应源站端口。"
    (( vless_ws_enabled )) && echo "  - VLESS 源站端口 ${vless_ws_port}，客户端端口 ${vless_ws_client_port}。"
    (( vmess_ws_enabled )) && echo "  - VMess 源站端口 ${vmess_ws_port}，客户端端口 ${vmess_ws_client_port}。"
    echo "  - 如系统启用了防火墙，需要放行源站监听端口。"
  fi

  if (( reality_enabled )); then
    echo
    warn "Reality 提醒：Reality 是直连 TCP/RAW 节点，不走 Cloudflare CDN。"
    echo "  - 公钥 publicKey：${reality_public_key}"
    echo "  - ShortId：${reality_short_id}"
  fi

  echo
  echo "节点链接："
  cat "${LINKS_FILE}"
}

main() {
  need_root
  check_system

  tmp_dir="$(mktemp -d)"
  install_dependencies
  install_xray

  select_protocols
  uuid="$(ask_uuid "$(generate_uuid)")"
  collect_ws_settings
  collect_reality_settings

  build_config
  restart_xray
  write_links
  print_summary
}

main "$@"

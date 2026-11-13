#!/usr/bin/env bash
# ==============================================================================
# 系统检测、依赖安装、端口与防火墙函数库（lib/system.sh）
# ==============================================================================

if [ "${_LIB_SYSTEM_LOADED:-0}" = "1" ]; then
  return 0
fi
_LIB_SYSTEM_LOADED=1

# 全局系统信息缓存变量
SYS_OS_NAME="未知系统"
SYS_OS_ID="unknown"
SYS_OS_VER=""
SYS_ARCH="unknown"
SYS_PKG_MGR=""
SYS_CPU_CORES="未知"
SYS_MEM_TOTAL="未知"
SYS_MEM_AVAIL="未知"
SYS_DISK_AVAIL="未知"
SYS_PUBLIC_IP=""

# 检测操作系统、CPU、内存、磁盘
detect_system_info() {
  SYS_ARCH="$(uname -m 2>/dev/null || echo 'unknown')"

  if [ -r /etc/os-release ]; then
    # 安全读取 os-release 中的 PRETTY_NAME / ID / VERSION_ID
    SYS_OS_NAME="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    SYS_OS_ID="$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    SYS_OS_VER="$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
  elif command -v uname >/dev/null 2>&1; then
    SYS_OS_NAME="$(uname -s) $(uname -r)"
  fi
  [ -z "$SYS_OS_NAME" ] && SYS_OS_NAME="Linux"

  if command -v apt-get >/dev/null 2>&1; then
    SYS_PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    SYS_PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    SYS_PKG_MGR="yum"
  elif command -v apk >/dev/null 2>&1; then
    SYS_PKG_MGR="apk"
  else
    SYS_PKG_MGR="unknown"
  fi

  if command -v nproc >/dev/null 2>&1; then
    SYS_CPU_CORES="$(nproc 2>/dev/null || echo '1')"
  elif [ -r /proc/cpuinfo ]; then
    SYS_CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '1')"
  fi

  if [ -r /proc/meminfo ]; then
    local mem_kb avail_kb
    mem_kb="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)"
    avail_kb="$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)"
    [ -z "$avail_kb" ] && avail_kb="$(awk '/^MemFree:/{print $2; exit}' /proc/meminfo)"
    if [ -n "$mem_kb" ]; then
      SYS_MEM_TOTAL="$(awk -v k="$mem_kb" 'BEGIN{printf "%.1f GB", k/1024/1024}')"
    fi
    if [ -n "$avail_kb" ]; then
      SYS_MEM_AVAIL="$(awk -v k="$avail_kb" 'BEGIN{printf "%.1f GB", k/1024/1024}')"
    fi
  fi

  if command -v df >/dev/null 2>&1; then
    SYS_DISK_AVAIL="$(df -Pk / 2>/dev/null | awk 'END{if (NF>=4 && $4 ~ /^[0-9]+$/) printf "%.1f GB", $4/1024/1024}' || true)"
    [ -z "$SYS_DISK_AVAIL" ] && SYS_DISK_AVAIL="未知"
  fi
}

# 探测本机公网 IPv4 地址（严禁使用内网路由探测）
get_public_ip() {
  if [ -n "$SYS_PUBLIC_IP" ]; then
    printf '%s' "$SYS_PUBLIC_IP"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    SYS_PUBLIC_IP="203.0.113.10"
    printf '%s' "$SYS_PUBLIC_IP"
    return 0
  fi

  local url ip=""
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    ip="$(curl -4 -fsSL --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      SYS_PUBLIC_IP="$ip"
      printf '%s' "$SYS_PUBLIC_IP"
      return 0
    fi
  done

  printf ''
  return 1
}

# 安装缺失的基础系统依赖
ensure_base_deps() {
  local missing=()
  local cmd
  for cmd in curl openssl tar; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  # ss 命令用于精确探测端口占用
  if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
    missing+=("ss")
  fi

  if [ "${#missing[@]}" -eq 0 ]; then
    log_ok "基础系统依赖已齐备（curl / openssl / tar / 端口检测工具）。"
    return 0
  fi

  log_info "检测到缺少基础工具: ${missing[*]}，正在自动安装..."
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将自动安装基础依赖: ${missing[*]}"
    return 0
  fi

  case "$SYS_PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      run_cmd apt-get update -qq || log_warn "部分软件源索引更新失败，尝试继续安装基础工具..."
      run_cmd apt-get install -y -qq curl ca-certificates openssl tar iproute2 dnsutils
      ;;
    dnf)
      run_cmd dnf install -y -q curl ca-certificates openssl tar iproute bind-utils
      ;;
    yum)
      run_cmd yum install -y -q curl ca-certificates openssl tar iproute bind-utils
      ;;
    apk)
      run_cmd apk add --no-cache curl ca-certificates openssl tar iproute2 bind-tools bash
      ;;
    *)
      log_warn "未识别的包管理器，请手动安装: curl openssl tar iproute2"
      return 1
      ;;
  esac
  log_ok "基础依赖安装完成。"
}

# 获取当前所有已占用 TCP 端口（宿主机监听 + Docker 容器映射端口，一次算好）
get_used_ports() {
  {
    if command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://'
    elif command -v netstat >/dev/null 2>&1; then
      netstat -ltn 2>/dev/null | awk 'NR>2{print $4}' | sed 's/.*://'
    fi
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
        | sed -n 's/.*:\([0-9][0-9]*\)->.*/\1/p'
    fi
  } | grep -E '^[0-9]+$' | sort -nu || true
}

# 一次性获取 iptables NAT PREROUTING 中可能劫持 TCP 端口的区间
get_nat_reserved_ranges() {
  if command -v iptables >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    iptables -t nat -S PREROUTING 2>/dev/null | awk '
      /-p udp/ { next }
      match($0, /--dport ([0-9]+):([0-9]+)/, m) { print m[1]"-"m[2]; next }
      match($0, /--dport ([0-9]+) /, m)          { print m[1]"-"m[1] }' || true
  fi
}

# 检查单个端口是否被占用或落在 iptables NAT 劫持区间内
# 返回 0 表示被占用（不可用），返回 1 表示空闲可用
is_port_in_use() {
  local target_port="$1"
  local used_list="${2:-}"
  local nat_ranges="${3:-__UNSET__}"
  [ -z "$used_list" ] && used_list="$(get_used_ports)"

  if [ -n "$used_list" ] && printf '%s\n' "$used_list" | grep -qx "$target_port"; then
    return 0
  fi

  if [ "$nat_ranges" = "__UNSET__" ]; then
    nat_ranges="$(get_nat_reserved_ranges)"
  fi

  local range start_p end_p
  for range in $nat_ranges; do
    start_p="${range%-*}"
    end_p="${range#*-}"
    if [ "$target_port" -ge "$start_p" ] && [ "$target_port" -le "$end_p" ]; then
      return 0
    fi
  done
  return 1
}

# 查看某个端口被哪个进程或容器占用（未检测到时返回空串，由调用方按需兜底）
describe_port_owner() {
  local port="$1"
  local owner=""
  if command -v ss >/dev/null 2>&1; then
    owner="$(ss -ltnp 2>/dev/null | awk -v p=":${port}$" 'NR>1 && $4 ~ p {print; exit}' | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1 || true)"
  fi
  if [ -z "$owner" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    owner="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E ":${port}->" | awk '{print "容器:"$1}' | head -1 || true)"
  fi
  printf '%s' "$owner"
}

# 从指定起始端口自动挑选一个空闲端口（所有端口列表与 NAT 区间均在循环外一次性缓存）
pick_free_port() {
  local candidate="${1:-8080}"
  local used_list nat_ranges
  used_list="$(get_used_ports)"
  nat_ranges="$(get_nat_reserved_ranges)"
  while [ "$candidate" -le 65000 ]; do
    if ! is_port_in_use "$candidate" "$used_list" "$nat_ranges"; then
      printf '%s' "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  return 1
}

# 格式化输出已占用端口摘要（供面板展示）
get_used_ports_summary() {
  local ports
  ports="$(get_used_ports | head -15 | tr '\n' ' ' | sed 's/ $//')"
  if [ -z "$ports" ]; then
    printf '暂无检测到监听端口'
  else
    printf '%s' "$ports"
  fi
}

# 放行防火墙端口（TCP）
open_firewall_port() {
  local port="$1"
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将放行防火墙端口: ${port}/tcp"
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    run_cmd ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    log_ok "已通过 UFW 防火墙放行端口 ${port}/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    run_cmd firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    run_cmd firewall-cmd --reload >/dev/null 2>&1 || true
    log_ok "已通过 firewalld 防火墙放行端口 ${port}/tcp"
  else
    log_info "未检测到启用的本地防火墙（ufw/firewalld），请确保云厂商安全组已放行 ${port}/tcp 端口。"
  fi
}

# 打印系统体检面板
print_system_banner() {
  detect_system_info
  local pub_ip
  pub_ip="$(get_public_ip || echo '未检测到（可能无外网或超时）')"
  local docker_status="未安装"
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      docker_status="已安装并运行中"
    else
      docker_status="已安装（服务未启动）"
    fi
  fi
  local ports_summary
  ports_summary="$(get_used_ports_summary)"

  print_hr
  printf '  %b系统信息%b  : %s (%s)\n' "$C_BOLD" "$C_RESET" "$SYS_OS_NAME" "$SYS_ARCH" >&2
  printf '  %b硬件资源%b  : %s 核 CPU | 内存 %s (可用 %s) | 磁盘剩余 %s\n' \
    "$C_BOLD" "$C_RESET" "$SYS_CPU_CORES" "$SYS_MEM_TOTAL" "$SYS_MEM_AVAIL" "$SYS_DISK_AVAIL" >&2
  printf '  %b公网 IP%b   : %s\n' "$C_BOLD" "$C_RESET" "$pub_ip" >&2
  printf '  %bDocker%b    : %s\n' "$C_BOLD" "$C_RESET" "$docker_status" >&2
  printf '  %b已占端口%b  : %s\n' "$C_BOLD" "$C_RESET" "$ports_summary" >&2
  print_hr
}

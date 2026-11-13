#!/usr/bin/env bash
# ==============================================================================
# 公共基础函数库（lib/common.sh）
# 提供：日志记录、颜色输出、安全交互、命令执行包装、白名单配置读写、错误处理
# ==============================================================================

# 防止重复加载
if [ "${_LIB_COMMON_LOADED:-0}" = "1" ]; then
  return 0
fi
_LIB_COMMON_LOADED=1

# 全局路径与运行控制默认值
VPS_BASE_DIR="${VPS_BASE_DIR:-/opt/vps-proxy}"
CADDY_DATA_DIR="${VPS_BASE_DIR}/caddy"
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"

# 日志文件位置（无 root 权限或演练模式时自动回退到 /tmp）
if [ "$(id -u)" -eq 0 ] && [ "$DRY_RUN" != "1" ]; then
  INSTALLER_LOG="${INSTALLER_LOG:-/var/log/vps-proxy-installer.log}"
else
  INSTALLER_LOG="${INSTALLER_LOG:-/tmp/vps-proxy-installer.log}"
fi

# 终端颜色初始化（非终端或设置 NO_COLOR 时自动禁用）
init_colors() {
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
  else
    C_RESET=''
    C_BOLD=''
    C_DIM=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
  fi
}
init_colors

# 若日志超过 5MB 则在加载时截断保留最近 1000 行，避免每条日志频繁派生子进程
_rotate_log_if_needed() {
  if [ -f "$INSTALLER_LOG" ]; then
    local sz
    sz="$(wc -c < "$INSTALLER_LOG" 2>/dev/null || echo 0)"
    if [ "${sz:-0}" -gt 5242880 ]; then
      local tail_tmp="${INSTALLER_LOG}.trim.$$"
      tail -n 1000 "$INSTALLER_LOG" > "$tail_tmp" 2>/dev/null && mv "$tail_tmp" "$INSTALLER_LOG" 2>/dev/null || rm -f "$tail_tmp"
    fi
  fi
}
_rotate_log_if_needed

# 写入日志并同步输出到终端（stderr，避免污染函数 stdout 返回值）
_write_log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '未知时间')"
  # 追加到日志文件（忽略无权限错误）
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$INSTALLER_LOG" 2>/dev/null || true
}

log_info() {
  _write_log "信息" "$*"
  printf '%b[信息]%b %s\n' "$C_CYAN" "$C_RESET" "$*" >&2
}

log_ok() {
  _write_log "成功" "$*"
  printf '%b[成功]%b %s\n' "$C_GREEN" "$C_RESET" "$*" >&2
}

log_warn() {
  _write_log "警告" "$*"
  printf '%b[警告]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

log_err() {
  _write_log "错误" "$*"
  printf '%b[错误]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

log_step() {
  local current="$1"
  local total="$2"
  local title="$3"
  _write_log "步骤" "($current/$total) $title"
  printf '\n%b%b==> [%s/%s] %s%b\n' "$C_BOLD" "$C_BLUE" "$current" "$total" "$title" "$C_RESET" >&2
}

print_hr() {
  printf '%b------------------------------------------------------------%b\n' "$C_DIM" "$C_RESET" >&2
}

die() {
  log_err "$*"
  exit 1
}

# 命令执行包装器：演练模式（--dry-run）下仅打印即将执行的命令，不做实际写入
run_cmd() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '%b[演练模式]%b 将执行: %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
    _write_log "演练" "$*"
    return 0
  fi
  _write_log "执行" "$*"
  "$@"
}

# 检查并引导 root 权限（兼容精简镜像无 sudo 的情况）
ensure_root() {
  if [ "$DRY_RUN" = "1" ]; then
    log_warn "当前处于演练模式（--dry-run），跳过管理员权限检查。"
    return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  log_err "安装依赖、配置容器与绑定 80/443 端口需要管理员（root）权限。"
  if command -v sudo >/dev/null 2>&1; then
    printf '  请复制以下命令重新运行：\n' >&2
    printf '  %bsudo bash %s %s%b\n' "$C_GREEN" "$0" "$*" "$C_RESET" >&2
  else
    printf '  当前系统未安装 sudo，请先执行以下命令切换到 root 用户再运行：\n' >&2
    printf '  %bsu -%b\n' "$C_GREEN" "$C_RESET" >&2
  fi
  exit 1
}

# 交互文本输入：提示输出到 stderr，结果输出到 stdout
# 用法：val="$(ask "请输入域名" "example.com")"
ask() {
  local prompt="$1"
  local default="${2:-}"
  local ans=""

  if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
    if [ -n "$default" ]; then
      printf "  %s -> [非交互模式，使用默认值: %s]\n" "$prompt" "$default" >&2
    fi
    printf '%s' "$default"
    return 0
  fi

  if [ -n "$default" ]; then
    printf '  %s %b[默认: %s]%b: ' "$prompt" "$C_DIM" "$default" "$C_RESET" >&2
  else
    printf '  %s: ' "$prompt" >&2
  fi

  if ! IFS= read -r ans; then
    # 遇到输入流结束（EOF），文本类回退默认值并提示
    printf "\n" >&2
    log_warn "未检测到键盘输入，自动采用默认值: ${default:-空}"
    printf '%s' "$default"
    return 0
  fi

  # 去除首尾空白
  ans="${ans#"${ans%%[![:space:]]*}"}"
  ans="${ans%"${ans##*[![:space:]]}"}"
  if [ -z "$ans" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$ans"
  fi
}

# 交互确认（y/n）：返回 0 表示是，返回 1 表示否
# 安全规则：遇到 EOF 强制按「否」处理，防止终端断开时误执行破坏性操作
ask_yn() {
  local prompt="$1"
  local default="${2:-n}"
  local ans=""
  local hint="y/N"
  [ "$default" = "y" ] && hint="Y/n"

  if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
    printf "  %s [%s] -> [非交互模式，使用默认值: %s]\n" "$prompt" "$hint" "$default" >&2
    [ "$default" = "y" ] && return 0 || return 1
  fi

  while true; do
    printf '  %s %b[%s]%b: ' "$prompt" "$C_DIM" "$hint" "$C_RESET" >&2
    if ! IFS= read -r ans; then
      printf '\n' >&2
      log_warn "输入流已中断，确认操作安全起见按「否」处理。"
      return 1
    fi
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"
    [ -z "$ans" ] && ans="$default"
    case "$ans" in
      y|Y|yes|YES|是) return 0 ;;
      n|N|no|NO|否)   return 1 ;;
      *) printf '  %b请输入 y（是）或 n（否）%b\n' "$C_YELLOW" "$C_RESET" >&2 ;;
    esac
  done
}

# 按任意键继续（仅在交互终端生效）
pause_enter() {
  if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
    return 0
  fi
  printf '\n  %b按回车键继续...%b' "$C_DIM" "$C_RESET" >&2
  IFS= read -r _ || true
}

# 安全写入键值配置文件（权限固定 600）
# 用法：save_conf_kv "/opt/vps-proxy/sub2api/.install.conf" "KEY1" "VAL1" "KEY2" "VAL2" ...
save_conf_kv() {
  local conf_file="$1"
  shift
  if [ "$(( $# % 2 ))" -ne 0 ]; then
    log_err "save_conf_kv 参数数量必须成对提供。"
    return 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将保存配置到 ${conf_file}"
    return 0
  fi
  local dir
  dir="$(dirname "$conf_file")"
  mkdir -p "$dir"
  local tmp_file="${conf_file}.tmp.$$"
  : > "$tmp_file"
  while [ "$#" -ge 2 ]; do
    local k="$1"
    local v="$2"
    shift 2
    # 剔除换行符，防止破坏键值对格式
    v="${v//$'\n'/}"
    v="${v//$'\r'/}"
    # 值里的 # 会被读配置时当成整行注释丢掉，反斜杠会在 compose 插值时被吃掉。
    case "$v" in
      *'#'*|*'\'*)
        log_err "配置项 ${k} 的值含有 # 或反斜杠，不能安全写入 ${conf_file}。"
        rm -f "$tmp_file"
        return 1
        ;;
    esac
    printf '%s=%s\n' "$k" "$v" >> "$tmp_file"
  done
  chmod 600 "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  mv "$tmp_file" "$conf_file" || { rm -f "$tmp_file"; return 1; }
}

# 安全读取配置文件（严禁 source，使用键白名单 + printf -v 防命令注入）
# 用法：load_conf_safe "/path/to/.install.conf" "PROJECT_ID" "APP_PORT" "DOMAIN" ...
load_conf_safe() {
  local conf_file="$1"
  shift
  [ -f "$conf_file" ] || return 1

  local allowed_keys=("$@")
  local line k v valid_count=0 total_nonempty=0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    # 跳过空行与注释
    case "$line" in
      ""|\#*) continue ;;
    esac
    total_nonempty=$((total_nonempty + 1))

    # 必须包含等号且键名仅含大写字母、数字、下划线
    case "$line" in
      *=*)
        k="${line%%=*}"
        v="${line#*=}"
        ;;
      *)
        continue
        ;;
    esac

    if [[ ! "$k" =~ ^[A-Z0-9_]+$ ]]; then
      continue
    fi

    # 检查是否在白名单中
    local matched=0
    local ak
    for ak in "${allowed_keys[@]}"; do
      if [ "$k" = "$ak" ]; then
        matched=1
        break
      fi
    done

    if [ "$matched" = "1" ]; then
      printf -v "$k" '%s' "$v"
      valid_count=$((valid_count + 1))
    fi
  done < "$conf_file"

  if [ "$total_nonempty" -gt 0 ] && [ "$valid_count" -eq 0 ]; then
    log_warn "配置文件 ${conf_file} 内容异常，未解析出有效配置项。"
    return 1
  fi
  return 0
}

# 生成高强度随机密钥（优先 openssl，退化 /dev/urandom）
gen_secret() {
  local bytes="${1:-32}"
  if [[ ! "$bytes" =~ ^[1-9][0-9]*$ ]]; then
    bytes=32
  fi
  if command -v openssl >/dev/null 2>&1; then
    local secret=""
    secret="$(openssl rand -hex "$bytes" 2>/dev/null | tr -cd '0-9a-f' || true)"
    if [ "${#secret}" -eq $((bytes * 2)) ]; then
      printf '%s' "$secret"
      return 0
    fi
  fi
  if [ -r /dev/urandom ]; then
    # od 每行默认 16 字节，行尾换行被删掉后，相邻两行会粘在一起少一个字节。
    # -w1 让每个字节单独一行，再去掉空白，长度才等于请求的字节数。
    head -c "$bytes" /dev/urandom | od -An -tx1 -w1 | tr -d ' \n'
  fi
}

# 校验端口号是否合法（1-65535，禁止前导零）
is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[1-9][0-9]*$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# 校验域名格式是否合法
is_valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# 菜单里的域名先去掉用户随手带上的协议、路径和端口，再做校验。
canonicalize_domain() {
  local d="$1"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  d="${d%%:*}"
  d="$(normalize_domain "$d")"
  d="${d%.}"
  printf '%s' "$d"
}

# 域名转小写规范化
normalize_domain() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# 校验邮箱格式（空串视为跳过，非空严格限定标准邮箱字符集，防配置块注入）
is_valid_email() {
  local e="$1"
  [ -z "$e" ] && return 0
  [[ "$e" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# 校验容器镜像名格式（非空、不含空白或控制字符）
is_valid_image() {
  local img="$1"
  [ -n "$img" ] && [[ ! "$img" =~ [[:space:]] ]]
}

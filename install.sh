#!/usr/bin/env bash
# ==============================================================================
# VPS 反代项目一键安装脚本集合 — 统一入口（install.sh）
# 支持：交互式中文菜单 + 全参数非交互模式 + 演练模式（--dry-run）
# ==============================================================================

set -euo pipefail

# 定位脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_OWNER="yys9253462-gif"
REPO_NAME="apibox"
REPO_BRANCH="main"
APIBOX_HOME="${APIBOX_HOME:-/opt/apibox}"

# 自举引导：当用户通过「一条命令」单文件下载运行时，自动拉取完整仓库到 /opt/apibox
_bootstrap_full_repo() {
  echo "[信息] 正在初始化 ApiBox 运行环境（首次约需 5-10 秒）..." >&2

  # 确保 curl 与 tar 可用（兼容最精简系统，无需提前安装 git）
  if ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq curl ca-certificates tar
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q curl ca-certificates tar
      elif command -v yum >/dev/null 2>&1; then
        yum install -y -q curl ca-certificates tar
      elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates tar bash
      fi
    else
      echo "[错误] 当前缺少 curl 或 tar，且非 root 用户。请先切换 root（su -）或安装 curl tar。" >&2
      exit 1
    fi
  fi

  local tmp_tgz tmp_extract
  tmp_tgz="$(mktemp "/tmp/apibox-${REPO_BRANCH}.XXXXXX.tar.gz")"
  tmp_extract="$(mktemp -d "/tmp/apibox-extract.XXXXXX")"
  mkdir -p "$APIBOX_HOME"

  local tar_url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}"
  local fallback_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 30 "$tar_url" -o "$tmp_tgz" && \
     ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-time 30 "$fallback_url" -o "$tmp_tgz"; then
    echo "[错误] 下载 ApiBox 安装包失败，请检查服务器能否访问 GitHub。" >&2
    rm -rf "$tmp_tgz" "$tmp_extract"
    exit 1
  fi

  if [ ! -s "$tmp_tgz" ] || ! tar --no-same-owner -xzf "$tmp_tgz" -C "$tmp_extract"; then
    echo "[错误] 解压 ApiBox 安装包失败。" >&2
    rm -rf "$tmp_tgz" "$tmp_extract"
    exit 1
  fi

  local top_dir
  top_dir="$(find "$tmp_extract" -maxdepth 1 -mindepth 1 -type d | head -1)"
  if [ -z "$top_dir" ] || [ ! -f "${top_dir}/install.sh" ]; then
    echo "[错误] 安装包结构异常，未找到主程序。" >&2
    rm -rf "$tmp_tgz" "$tmp_extract"
    exit 1
  fi

  cp -a "${top_dir}/." "${APIBOX_HOME}/"
  chmod +x "${APIBOX_HOME}/install.sh" "${APIBOX_HOME}"/lib/*.sh "${APIBOX_HOME}"/projects/*.sh 2>/dev/null || true
  rm -rf "$tmp_tgz" "$tmp_extract"

  # 若用户通过管道 (curl | bash) 执行，尝试把 stdin 接回控制终端
  if [ ! -t 0 ] && (exec 3</dev/tty) 2>/dev/null; then
    exec bash "${APIBOX_HOME}/install.sh" "$@" </dev/tty
  fi
  exec bash "${APIBOX_HOME}/install.sh" "$@"
}

if [ ! -f "${SCRIPT_DIR}/lib/common.sh" ] || [ ! -f "${SCRIPT_DIR}/projects.conf" ]; then
  _bootstrap_full_repo "$@"
fi

# 加载公共函数库
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/system.sh
source "${SCRIPT_DIR}/lib/system.sh"
# shellcheck source=lib/docker.sh
source "${SCRIPT_DIR}/lib/docker.sh"
# shellcheck source=lib/ssl.sh
source "${SCRIPT_DIR}/lib/ssl.sh"
# shellcheck source=lib/project_base.sh
source "${SCRIPT_DIR}/lib/project_base.sh"

# 全局实例互斥锁（按权限隔离路径，避免 Linux fs.protected_regular 导致 sudo 权限拒绝）
if [ "$(id -u)" -eq 0 ] && [ -d /run ]; then
  APIBOX_LOCK_FILE="/run/apibox-installer.lock"
  APIBOX_LOCK_DIR="/run/apibox-installer.lock.d"
else
  APIBOX_LOCK_FILE="/tmp/apibox-installer-uid$(id -u).lock"
  APIBOX_LOCK_DIR="/tmp/apibox-installer-uid$(id -u).lock.d"
fi
_LOCK_HELD_MODE=""

_on_global_interrupt() {
  release_instance_lock
  exit 130
}

acquire_instance_lock() {
  [ "$DRY_RUN" = "1" ] && return 0
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$APIBOX_LOCK_FILE"
    if ! flock -n 9; then
      die "检测到另一个 ApiBox 安装/管理进程正在运行，请等待其结束后再试。"
    fi
    _LOCK_HELD_MODE="flock"
  else
    if ! mkdir "$APIBOX_LOCK_DIR" 2>/dev/null; then
      die "检测到另一个 ApiBox 安装/管理进程正在运行（锁目录 ${APIBOX_LOCK_DIR}），若确认无进程运行可手动删除该锁目录。"
    fi
    _LOCK_HELD_MODE="mkdir"
  fi
  trap release_instance_lock EXIT
  trap _on_global_interrupt INT TERM
}

release_instance_lock() {
  if [ "$_LOCK_HELD_MODE" = "flock" ]; then
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
  elif [ "$_LOCK_HELD_MODE" = "mkdir" ]; then
    rmdir "$APIBOX_LOCK_DIR" 2>/dev/null || true
  fi
}

# 命令行参数变量
CLI_PROJECT=""
CLI_ACTION=""
CLI_PORT=""
CLI_DOMAIN=""
CLI_NO_DOMAIN=0
CLI_EMAIL=""
CLI_IMAGE=""
CLI_LIST=0

# 项目注册表数组
REG_IDS=()
REG_NAMES=()
REG_DESCS=()
REG_PORTS=()
REG_SCRIPTS=()
REG_REPOS=()
REG_IMAGES=()

print_usage() {
  cat <<'EOF'
ApiBox — VPS 反代项目一键安装脚本集合

用法：
  交互式菜单（推荐新手）：
    sudo bash install.sh

  命令行非交互模式（适合自动化或批量部署）：
    sudo bash install.sh --project <项目ID> [选项]

常用选项：
  --project <id>      指定项目 ID（如 sub2api、newapi、magpie、agent2api）
  --action <act>      指定操作：install（安装，默认）| status | logs | restart | upgrade | uninstall
  --port <port|auto>  指定宿主机端口，或使用 auto 自动挑选空闲端口
  --domain <domain>   绑定域名并自动申请 Let's Encrypt HTTPS 证书
  --no-domain         跳过域名绑定，仅使用 IP + 端口访问
  --email <email>     Let's Encrypt 证书过期提醒邮箱（可选）
  --image <image>     自定义容器镜像地址
  --skip-dns-check    跳过域名 DNS 解析检查（适用于 CDN 回源场景）
  --yes, -y           非交互确认（所有提示自动使用默认值）
  --dry-run           演练模式：仅打印将执行的操作，不修改系统
  --list              列出当前支持的所有项目
  --help, -h          显示本帮助信息
EOF
}

# 解析命令行参数（严格校验，非法参数直接报错拦截）
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        [ -n "${2:-}" ] || die "参数 --project 缺少项目 ID"
        CLI_PROJECT="$2"
        shift 2
        ;;
      --action)
        [ -n "${2:-}" ] || die "参数 --action 缺少操作名称"
        case "$2" in
          install|status|logs|restart|upgrade|uninstall) CLI_ACTION="$2" ;;
          *) die "不支持的操作类型: $2（可选: install / status / logs / restart / upgrade / uninstall）" ;;
        esac
        shift 2
        ;;
      --port)
        [ -n "${2:-}" ] || die "参数 --port 缺少端口号"
        if [ "$2" != "auto" ] && ! is_valid_port "$2"; then
          die "无效的端口号: $2（请输入 1-65535 或 auto）"
        fi
        CLI_PORT="$2"
        shift 2
        ;;
      --domain)
        [ -n "${2:-}" ] || die "参数 --domain 缺少域名"
        is_valid_domain "$2" || die "域名格式不合法: $2"
        CLI_DOMAIN="$2"
        shift 2
        ;;
      --no-domain)
        CLI_NO_DOMAIN=1
        shift
        ;;
      --email)
        [ -n "${2:-}" ] || die "参数 --email 缺少邮箱"
        is_valid_email "$2" || die "邮箱格式不合法: $2"
        CLI_EMAIL="$2"
        shift 2
        ;;
      --image)
        [ -n "${2:-}" ] || die "参数 --image 缺少镜像名"
        is_valid_image "$2" || die "镜像名格式不合法（不能包含空白字符）: $2"
        CLI_IMAGE="$2"
        shift 2
        ;;
      --skip-dns-check)
        SKIP_DNS_CHECK=1
        shift
        ;;
      --yes|-y)
        ASSUME_YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        INSTALLER_LOG="/tmp/vps-proxy-installer.log"
        shift
        ;;
      --list)
        CLI_LIST=1
        shift
        ;;
      --help|-h)
        print_usage
        exit 0
        ;;
      *)
        die "未知参数: $1（使用 --help 查看支持的选项）"
        ;;
    esac
  done

  if [ "$CLI_NO_DOMAIN" = "1" ] && [ -n "$CLI_DOMAIN" ]; then
    die "参数冲突：--domain 与 --no-domain 不能同时使用。"
  fi
}

# 读取 projects.conf 注册表
load_projects_registry() {
  REG_IDS=()
  REG_NAMES=()
  REG_DESCS=()
  REG_PORTS=()
  REG_SCRIPTS=()
  REG_REPOS=()
  REG_IMAGES=()

  local conf_path="${SCRIPT_DIR}/projects.conf"
  [ -f "$conf_path" ] || die "找不到项目注册表: ${conf_path}"

  local line id name desc port script_rel repo image
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    # 跳过空行与注释
    case "$line" in
      ""|\#*) continue ;;
    esac
    IFS='|' read -r id name desc port script_rel repo image <<< "$line"
    [ -n "$id" ] && [ -n "$script_rel" ] || continue
    REG_IDS+=("$id")
    REG_NAMES+=("$name")
    REG_DESCS+=("$desc")
    REG_PORTS+=("$port")
    REG_SCRIPTS+=("$script_rel")
    REG_REPOS+=("$repo")
    REG_IMAGES+=("$image")
  done < "$conf_path"

  [ "${#REG_IDS[@]}" -gt 0 ] || die "projects.conf 中未配置任何有效项目。"
}

# 探测项目当前安装与运行状态标签
get_project_badge() {
  local id="$1"
  local container="vps-proxy-${id}"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local st
    st="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
    case "$st" in
      running) printf '%b[运行中]%b' "$C_GREEN" "$C_RESET" ; return 0 ;;
      exited|dead|created) printf '%b[已停止]%b' "$C_YELLOW" "$C_RESET" ; return 0 ;;
    esac
  fi
  if [ -f "${VPS_BASE_DIR}/${id}/docker-compose.yml" ]; then
    printf '%b[已配置]%b' "$C_YELLOW" "$C_RESET"
  else
    printf '%b[未安装]%b' "$C_DIM" "$C_RESET"
  fi
}

# 加载单个项目脚本并校验其存在性（加载前清理可选钩子，防止跨项目命名空间污染）
load_project_module() {
  local idx="$1"
  local script_file="${SCRIPT_DIR}/${REG_SCRIPTS[$idx]}"
  [ -f "$script_file" ] || die "项目 [${REG_IDS[$idx]}] 的安装脚本不存在: ${script_file}"
  unset -f project_write_env project_write_compose project_post_install_tips \
    project_install project_status project_logs project_restart project_upgrade project_uninstall 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$script_file"
}

# 查找项目 ID 在注册表中的索引
find_project_index() {
  local target_id="$1"
  local i
  for ((i = 0; i < ${#REG_IDS[@]}; i++)); do
    if [ "${REG_IDS[$i]}" = "$target_id" ]; then
      printf '%d' "$i"
      return 0
    fi
  done
  return 1
}

# 列出所有支持的项目
list_projects() {
  printf "当前支持的反代项目清单：\n"
  local i
  for ((i = 0; i < ${#REG_IDS[@]}; i++)); do
    printf "  %-10s | %-12s | 默认端口: %-5s | %s (%s)\n" \
      "${REG_IDS[$i]}" "${REG_NAMES[$i]}" "${REG_PORTS[$i]}" "${REG_DESCS[$i]}" "${REG_REPOS[$i]}"
  done
}

# 展示全部已安装容器与端口总览
show_all_services_overview() {
  print_hr
  printf '  %b当前已占用的 TCP 端口：%b\n' "$C_BOLD" "$C_RESET" >&2
  local ports_info
  ports_info="$(get_used_ports)"
  if [ -z "$ports_info" ]; then
    printf '    （暂无）\n' >&2
  else
    local p owner
    for p in $ports_info; do
      owner="$(describe_port_owner "$p")"
      printf '    端口 %-6s -> %s\n' "$p" "${owner:-未知进程}" >&2
    done
  fi
  printf '\n  %b已部署的反代容器：%b\n' "$C_BOLD" "$C_RESET" >&2
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker ps -a --filter "name=vps-proxy-" \
      --format "    {{.Names}}\t{{.Status}}\t{{.Ports}}" >&2 || true
  else
    printf '    （Docker 未安装或未运行）\n' >&2
  fi
  print_hr
  pause_enter
}

# 项目二级操作菜单
project_submenu() {
  local idx="$1"
  load_project_module "$idx"

  while true; do
    printf '\n' >&2
    print_hr
    printf '  %b当前项目：%b%s%b  %b\n' "$C_BOLD" "$C_CYAN" "${REG_NAMES[$idx]}" "$C_RESET" "$(get_project_badge "${REG_IDS[$idx]}")" >&2
    printf '  简介：%s\n' "${REG_DESCS[$idx]}" >&2
    printf '  仓库：%s\n' "${REG_REPOS[$idx]}" >&2
    print_hr
    printf '    1) 安装 / 重新配置（支持自动装 Docker 与申请 HTTPS 证书）\n' >&2
    printf '    2) 查看运行状态与访问地址\n' >&2
    printf '    3) 查看实时日志（排查启动异常）\n' >&2
    printf '    4) 重启服务\n' >&2
    printf '    5) 更新到最新镜像\n' >&2
    printf '    6) 卸载服务\n' >&2
    printf '    9) 返回上级菜单\n' >&2
    printf '    0) 退出脚本\n' >&2
    print_hr

    local sub_choice
    sub_choice="$(ask "请选择操作编号" "1")"
    case "$sub_choice" in
      1) project_install || true ; pause_enter ;;
      2) project_status || true ; pause_enter ;;
      3) project_logs || true ; pause_enter ;;
      4) project_restart || true ; pause_enter ;;
      5) project_upgrade || true ; pause_enter ;;
      6) project_uninstall || true ; pause_enter ;;
      9) return 0 ;;
      0) log_info "感谢使用，再见！"; exit 0 ;;
      *) log_warn "无效选项 [${sub_choice}]，请输入菜单中的数字编号。" ;;
    esac
  done
}

# 主交互菜单
main_menu() {
  # 首屏人话欢迎语
  printf '\n' >&2
  printf '%b%b============================================================%b\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
  printf '%b%b        VPS 反代项目一键部署与管理工具 (v1.0)               %b\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
  printf '%b%b============================================================%b\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
  printf '  面向新手设计：自动检测系统环境、安装 Docker、分配空闲端口、\n' >&2
  printf '  配置反向代理并免费申请/自动续期 Let'\''s Encrypt HTTPS 证书。\n' >&2
  printf '  全程约需 1-3 分钟，拿不准的提示直接按回车使用默认值即可。\n' >&2

  local need_redraw=1
  while true; do
    if [ "$need_redraw" -eq 1 ]; then
      print_system_banner
      printf '  %b请选择要安装或管理的反代项目：%b\n\n' "$C_BOLD" "$C_RESET" >&2

      local i num
      for ((i = 0; i < ${#REG_IDS[@]}; i++)); do
        num=$((i + 1))
        printf '    %d) %-12s %b  - %s\n' \
          "$num" "${REG_NAMES[$i]}" "$(get_project_badge "${REG_IDS[$i]}")" "${REG_DESCS[$i]}" >&2
      done

      printf '\n  %b系统辅助功能：%b\n' "$C_BOLD" "$C_RESET" >&2
      printf '    88) 单独检查 / 自动安装 Docker 与 Compose 环境\n' >&2
      printf '    89) 查看已占用端口与所有反代容器总览\n' >&2
      printf '     0) 退出脚本\n' >&2
      print_hr
      need_redraw=0
    fi

    local choice
    choice="$(ask "请输入数字编号" "1")"

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [ "$choice" -eq 0 ]; then
        log_info "已退出脚本。"
        exit 0
      elif [ "$choice" -eq 88 ]; then
        ensure_root
        ensure_base_deps
        ensure_docker_ready || true
        pause_enter
        need_redraw=1
        continue
      elif [ "$choice" -eq 89 ]; then
        show_all_services_overview
        need_redraw=1
        continue
      elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#REG_IDS[@]}" ]; then
        project_submenu $((choice - 1))
        need_redraw=1
        continue
      fi
    fi

    log_warn "无效选择 [${choice}]，请输入 1-${#REG_IDS[@]}、88、89 或 0。"
  done
}

# 主流程入口
main() {
  parse_args "$@"
  load_projects_registry

  if [ "$CLI_LIST" = "1" ]; then
    list_projects
    exit 0
  fi

  # 若在命令行指定了 --project，则走直接执行路径（支持全自动非交互）
  if [ -n "$CLI_PROJECT" ]; then
    local idx
    if ! idx="$(find_project_index "$CLI_PROJECT")"; then
      die "未在 projects.conf 中找到项目: ${CLI_PROJECT}（使用 --list 查看所有支持的项目）"
    fi
    load_project_module "$idx"
    local act="${CLI_ACTION:-install}"
    case "$act" in
      install|restart|upgrade|uninstall) acquire_instance_lock ;;
    esac
    case "$act" in
      install)   project_install ;;
      status)    project_status ;;
      logs)      project_logs ;;
      restart)   project_restart ;;
      upgrade)   project_upgrade ;;
      uninstall) project_uninstall ;;
    esac
    exit $?
  fi

  # 若当前不是交互终端且未指定 --project，明确告知用户并退出，避免死循环
  if [ ! -t 0 ] && [ "$DRY_RUN" != "1" ]; then
    log_warn "当前不是交互式终端，无法显示交互菜单。"
    printf '  请使用以下命令先下载再运行，或通过 --project 参数指定项目：\n' >&2
    printf '  %bbash install.sh --list%b\n' "$C_GREEN" "$C_RESET" >&2
    printf '  %bbash install.sh --project sub2api --port auto --no-domain --yes%b\n' "$C_GREEN" "$C_RESET" >&2
    exit 1
  fi

  acquire_instance_lock
  main_menu
}

main "$@"

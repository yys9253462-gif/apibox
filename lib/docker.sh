#!/usr/bin/env bash
# ==============================================================================
# Docker 与 Docker Compose 检测、自动安装与容器排障库（lib/docker.sh）
# ==============================================================================

if [ "${_LIB_DOCKER_LOADED:-0}" = "1" ]; then
  return 0
fi
_LIB_DOCKER_LOADED=1

# 统一执行 docker compose（兼容 V2 插件与独立二进制）
compose_cmd() {
  local compose_file="$1"
  shift
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$compose_file" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$compose_file" "$@"
  else
    die "未找到 docker compose 命令，请先安装 Docker Compose。"
  fi
}

# 启动并启用 Docker 服务
start_docker_service() {
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将启动并设置 Docker 开机自启。"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker || true
  elif command -v service >/dev/null 2>&1; then
    service docker start || true
  fi
  if ! docker info >/dev/null 2>&1; then
    log_err "Docker 服务启动失败，请复制以下命令查看详细报错："
    printf "  ${C_GREEN}systemctl status docker --no-pager -l${C_RESET}\n" >&2
    return 1
  fi
  return 0
}

# 自动检测并在缺失时部署 Docker 与 Docker Compose
ensure_docker_ready() {
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 跳过 Docker 安装与启动，假定环境就绪。"
    return 0
  fi

  local need_install=0
  if ! command -v docker >/dev/null 2>&1; then
    need_install=1
  fi

  if [ "$need_install" -eq 1 ]; then
    log_info "未检测到 Docker，准备自动安装 Docker 与 Docker Compose..."
    local installer_tmp="/tmp/get-docker.sh"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "https://get.docker.com" -o "$installer_tmp"; then
      log_warn "从官方源下载 Docker 安装脚本失败，尝试使用阿里云镜像脚本..."
      if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "https://get.docker.com" -o "$installer_tmp"; then
        log_err "下载 Docker 安装脚本失败，请检查服务器网络连接后重试，或手动执行："
        printf "  ${C_GREEN}curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh${C_RESET}\n" >&2
        return 1
      fi
    fi

    if [ ! -s "$installer_tmp" ] || ! grep -q "docker" "$installer_tmp"; then
      rm -f "$installer_tmp"
      die "下载的 Docker 安装脚本内容异常，已中止安装。"
    fi

    log_info "正在执行 Docker 安装，大约需要 1-2 分钟，请耐心等待..."
    sh "$installer_tmp"
    rm -f "$installer_tmp"
    log_ok "Docker 安装完成。"
  fi

  # 确保 Docker 服务处于运行状态
  if ! docker info >/dev/null 2>&1; then
    log_info "Docker 服务未启动，正在启动..."
    start_docker_service || return 1
  fi

  # 检查 Docker Compose V2 插件
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    log_info "检测到缺少 Docker Compose 插件，正在自动补充安装..."
    case "$SYS_PKG_MGR" in
      apt)
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
        ;;
      dnf)
        dnf install -y -q docker-compose-plugin >/dev/null 2>&1 || true
        ;;
      yum)
        yum install -y -q docker-compose-plugin >/dev/null 2>&1 || true
        ;;
      apk)
        apk add --no-cache docker-cli-compose >/dev/null 2>&1 || true
        ;;
    esac
  fi

  # 若系统软件源不含 docker-compose-plugin（如 Debian/Ubuntu 自带 docker.io），直接下载官方二进制插件
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    log_info "系统软件源未提供 Compose 插件，正在下载 Docker 官方 Compose V2 二进制插件..."
    local arch_raw compose_arch
    arch_raw="$(uname -m 2>/dev/null || echo 'x86_64')"
    case "$arch_raw" in
      x86_64|amd64)   compose_arch="x86_64" ;;
      aarch64|arm64)  compose_arch="aarch64" ;;
      *)              compose_arch="$arch_raw" ;;
    esac
    local plugin_dir="/usr/local/lib/docker/cli-plugins"
    local plugin_bin="${plugin_dir}/docker-compose"
    local compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${compose_arch}"
    mkdir -p "$plugin_dir"
    if curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 "$compose_url" -o "$plugin_bin" && [ -s "$plugin_bin" ]; then
      chmod +x "$plugin_bin"
      log_ok "Docker Compose V2 插件安装成功。"
    else
      rm -f "$plugin_bin"
    fi
  fi

  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    log_err "Docker Compose 仍不可用，请手动安装后再试："
    printf "  %bapt-get update && apt-get install -y docker-compose-plugin%b\n" "$C_GREEN" "$C_RESET" >&2
    return 1
  fi

  log_ok "Docker 与 Docker Compose 环境就绪。"
  return 0
}

# 创建共享 Docker 网络（用于内置 Caddy 容器反代各项目容器）
ensure_proxy_network() {
  local net_name="${1:-vps_proxy_net}"
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将确保共享反代网络 ${net_name} 存在。"
    return 0
  fi
  if ! docker network inspect "$net_name" >/dev/null 2>&1; then
    docker network create "$net_name" >/dev/null
    log_ok "已创建容器共享反代网络: ${net_name}"
  fi
}

# 等待容器真正就绪（避免 docker-proxy 绑定端口造成的假通过）
# 用法：wait_container_healthy "容器名" "容器内部端口" [最大等待秒数]
wait_container_ready() {
  local container="$1"
  local port="$2"
  local timeout="${3:-45}"
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将等待容器 ${container} 在端口 ${port} 上就绪。"
    return 0
  fi

  log_info "正在等待服务启动并检测端口就绪（最多 ${timeout} 秒）..."
  local i=0
  while [ "$i" -lt "$timeout" ]; do
    local state
    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo 'missing')"
    if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
      log_err "容器 ${container} 已意外退出（状态: ${state}）。"
      return 1
    fi
    if [ "$state" = "running" ]; then
      # 优先检测本地回环端口是否真正响应
      if curl -sf --max-time 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1 || \
         curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null; then
        # 检查从宿主机能否真正连上且不立刻重置连接
        local code
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null || echo '000')"
        if [ "$code" != "000" ]; then
          log_ok "服务已就绪（HTTP 状态码: ${code}）。"
          return 0
        fi
      fi
    fi
    sleep 2
    i=$((i + 2))
  done

  log_warn "服务启动超时（${timeout} 秒内未收到 HTTP 响应），请查看日志确认原因。"
  return 1
}

# 容器异常分型诊断与新手处理交互
handle_container_failure() {
  local container="$1"
  local compose_file="$2"
  local raw_err="${3:-}"

  printf "\n" >&2
  log_err "容器 [${container}] 启动或运行异常！"
  if [ -n "$raw_err" ]; then
    printf "  ${C_DIM}原始错误摘要:${C_RESET}\n" >&2
    printf '%s\n' "$raw_err" | tail -8 | sed 's/^/    /' >&2

    case "$raw_err" in
      *"is already in use"*)
        log_warn "原因定位：存在同名容器冲突。您可以先卸载旧容器或更换容器名。"
        ;;
      *"address already in use"*|*"port is already allocated"*)
        log_warn "原因定位：端口已被其他程序占用，请重新配置更换空闲端口。"
        ;;
      *"manifest unknown"*|*"pull access denied"*|*"TLS handshake timeout"*|*"connection refused"*)
        log_warn "原因定位：容器镜像拉取失败（网络超时或镜像标签不可用）。"
        ;;
      *"Cannot allocate memory"*|*"OOM"*)
        log_warn "原因定位：服务器内存不足，建议开启 Swap 虚拟内存或升级配置。"
        ;;
    esac
  fi

  printf "\n  您可以复制以下手动命令排查：\n" >&2
  printf "  查看最近日志: ${C_GREEN}docker logs --tail 100 %s${C_RESET}\n" "$container" >&2
  printf "  尝试手动重启: ${C_GREEN}docker compose -f %s restart${C_RESET}\n" "$compose_file" >&2
  printf "  彻底卸载清理: ${C_GREEN}docker compose -f %s down${C_RESET}\n\n" "$compose_file" >&2

  if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
    return 1
  fi

  while true; do
    printf "  请选择处理方式：\n" >&2
    printf "    1) 查看最近 50 行容器日志\n" >&2
    printf "    2) 重启容器再试一次\n" >&2
    printf "    3) 停止并移除异常容器\n" >&2
    printf "    0) 跳过并返回\n" >&2
    local choice
    choice="$(ask "请输入选项编号" "1")"
    case "$choice" in
      1)
        print_hr
        docker logs --tail 50 "$container" 2>&1 || true
        print_hr
        ;;
      2)
        log_info "正在重启容器..."
        compose_cmd "$compose_file" restart || true
        sleep 3
        docker ps -a --filter "name=^/${container}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" >&2
        ;;
      3)
        if ask_yn "确认停止并移除该异常容器吗？（保留数据目录）" "n"; then
          compose_cmd "$compose_file" down || true
          log_ok "异常容器已清理。"
          return 1
        fi
        ;;
      0)
        return 1
        ;;
      *)
        log_warn "无效选项，请输入 1、2、3 或 0。"
        ;;
    esac
  done
}

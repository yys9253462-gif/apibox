#!/usr/bin/env bash
# ==============================================================================
# 项目安装脚本：Magpie（yetone/magpie）
# ==============================================================================

PROJ_ID="magpie"
PROJ_NAME="Magpie"
PROJ_DESC="统一 AI Agent 模型网关（支持 Claude Code / Codex / Gemini CLI 多账号切换与 Web 管理）"
PROJ_REPO="https://github.com/yetone/magpie"
PROJ_DEFAULT_IMAGE="ghcr.io/yetone/magpie:stable"
PROJ_INNER_PORT="3425"
PROJ_DEFAULT_HOST_PORT="3425"
PROJ_CONTAINER_NAME="vps-proxy-magpie"

project_write_env() {
  local app_dir="$1"
  local env_file="${app_dir}/.env"

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将检查并生成环境变量文件: ${env_file}"
    return 0
  fi

  if [ -f "$env_file" ]; then
    log_info "检测到已有配置文件 ${env_file}，将保留原有设置（幂等安全）。"
    return 0
  fi

  cat > "$env_file" <<EOF
# Magpie 环境变量（由 apibox 自动生成）
TZ=Asia/Shanghai
MAGPIE_ADDR=0.0.0.0:${PROJ_INNER_PORT}
EOF
  chmod 600 "$env_file"
  log_ok "已生成配置文件 ${env_file}（权限 600）。"
}

project_write_compose() {
  local app_dir="$1"
  local host_port="$2"
  local image="$3"
  local compose_file="${app_dir}/docker-compose.yml"

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将生成 ${compose_file}（镜像: ${image}, 端口: ${host_port}:${PROJ_INNER_PORT}）"
    return 0
  fi

  # Magpie 容器以 nonroot (65532:65532) 运行，必须提前赋予宿主机挂载目录写权限
  mkdir -p "${app_dir}/config"
  chown -R 65532:65532 "${app_dir}/config"

  cat > "$compose_file" <<EOF
services:
  magpie:
    image: ${image}
    container_name: ${PROJ_CONTAINER_NAME}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "${host_port}:${PROJ_INNER_PORT}"
    volumes:
      - ./config:/config
    networks:
      - default
      - ${PROXY_NET_NAME}

networks:
  ${PROXY_NET_NAME}:
    external: true
EOF
}

project_post_install_tips() {
  local app_dir="$1"
  printf '  %b数据配置目录%b : %s/config\n' "$C_BOLD" "$C_RESET" "$app_dir" >&2
  printf '  %b命令行管理%b   : %bdocker exec -it %s magpie tui%b\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$PROJ_CONTAINER_NAME" "$C_RESET" >&2
}

project_install()   { base_project_install "$@"; }
project_status()    { base_project_status "$@"; }
project_logs()      { base_project_logs "$@"; }
project_restart()   { base_project_restart "$@"; }
project_upgrade()   { base_project_upgrade "$@"; }
project_uninstall() { base_project_uninstall "$@"; }

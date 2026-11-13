#!/usr/bin/env bash
# ==============================================================================
# 项目安装脚本：Agent2API（aimod-cc/agent2api）
# ==============================================================================

PROJ_ID="agent2api"
PROJ_NAME="Agent2API"
PROJ_DESC="一体化 AI Agent 网关与管理面板（OpenAI 兼容 /v1 接口 + 多渠道聚合）"
PROJ_REPO="https://github.com/aimod-cc/agent2api"
PROJ_DEFAULT_IMAGE="aimodcc/agent2api:latest"
PROJ_INNER_PORT="3065"
PROJ_DEFAULT_HOST_PORT="3065"
PROJ_CONTAINER_NAME="vps-proxy-agent2api"

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
# Agent2API 环境变量（由 apibox 自动生成）
TZ=Asia/Shanghai
AGENT2API_CAPTCHA_ENABLED=1
AGENT2API_SELF_UPDATE=1
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

  mkdir -p "${app_dir}/data"
  cat > "$compose_file" <<EOF
services:
  agent2api:
    image: ${image}
    container_name: ${PROJ_CONTAINER_NAME}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "${host_port}:${PROJ_INNER_PORT}"
    volumes:
      - ./data:/data
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
  printf '  %b首次使用提示%b : 打开上方地址即可注册管理员账号，并在「网关 Key」页创建密钥\n' "$C_BOLD" "$C_RESET" >&2
  printf '  %b数据配置目录%b : %s/data\n' "$C_BOLD" "$C_RESET" "$app_dir" >&2
}

project_install()   { base_project_install "$@"; }
project_status()    { base_project_status "$@"; }
project_logs()      { base_project_logs "$@"; }
project_restart()   { base_project_restart "$@"; }
project_upgrade()   { base_project_upgrade "$@"; }
project_uninstall() { base_project_uninstall "$@"; }

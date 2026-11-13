#!/usr/bin/env bash
# ==============================================================================
# 项目安装脚本：New API（QuantumNous/new-api）
# ==============================================================================

PROJ_ID="newapi"
PROJ_NAME="New API"
PROJ_DESC="新一代大模型接口管理与分发系统（多渠道聚合、令牌与额度计费）"
PROJ_REPO="https://github.com/QuantumNous/new-api"
PROJ_DEFAULT_IMAGE="calciumion/new-api:latest"
PROJ_INNER_PORT="3000"
PROJ_DEFAULT_HOST_PORT="3000"
PROJ_CONTAINER_NAME="vps-proxy-newapi"

project_write_env() {
  local app_dir="$1"
  local env_file="${app_dir}/.env"

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将检查并生成环境变量文件: ${env_file}"
    return 0
  fi

  if [ -f "$env_file" ]; then
    log_info "检测到已有配置文件 ${env_file}，将保留原加密密钥与会话密钥（幂等安全）。"
    return 0
  fi

  local session_secret crypto_secret
  session_secret="$(gen_secret 24)"
  crypto_secret="$(gen_secret 24)"

  cat > "$env_file" <<EOF
# New API 环境变量（由 apibox 自动生成）
TZ=Asia/Shanghai
SESSION_SECRET=${session_secret}
CRYPTO_SECRET=${crypto_secret}
EOF
  chmod 600 "$env_file"
  log_ok "已生成随机安全密钥并保存到 ${env_file}（权限 600）。"
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
  new-api:
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
  printf '  %b初始账号提示%b : 首次打开网页请按引导设置 root 管理员账号与密码\n' "$C_BOLD" "$C_RESET" >&2
  printf '  %b配置文件目录%b : %s\n' "$C_BOLD" "$C_RESET" "$app_dir" >&2
}

project_install()   { base_project_install "$@"; }
project_status()    { base_project_status "$@"; }
project_logs()      { base_project_logs "$@"; }
project_restart()   { base_project_restart "$@"; }
project_upgrade()   { base_project_upgrade "$@"; }
project_uninstall() { base_project_uninstall "$@"; }

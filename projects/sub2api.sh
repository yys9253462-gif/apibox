#!/usr/bin/env bash
# ==============================================================================
# 项目安装脚本：Sub2API（weishaw/sub2api）
# ==============================================================================

PROJ_ID="sub2api"
PROJ_NAME="Sub2API"
PROJ_DESC="多账号 AI 接口聚合反代网关（支持 Claude / OpenAI / Gemini）"
PROJ_REPO="https://github.com/weishaw/sub2api"
PROJ_DEFAULT_IMAGE="weishaw/sub2api:latest"
PROJ_INNER_PORT="8080"
PROJ_DEFAULT_HOST_PORT="8080"
PROJ_CONTAINER_NAME="vps-proxy-sub2api"

project_write_env() {
  local app_dir="$1"
  local host_port="$2"
  local env_file="${app_dir}/.env"

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将检查并生成环境变量文件: ${env_file}"
    return 0
  fi

  if [ -f "$env_file" ]; then
    log_info "检测到已有配置文件 ${env_file}，将保留原密钥并同步更新端口设置（幂等安全）。"
    if grep -q '^HOST_PORT=' "$env_file" 2>/dev/null; then
      local tmp_env="${env_file}.tmp.$$"
      awk -v p="$host_port" '/^HOST_PORT=/{print "HOST_PORT=" p; next} {print}' "$env_file" > "$tmp_env" \
        && chmod 600 "$tmp_env" && mv "$tmp_env" "$env_file" || rm -f "$tmp_env"
    else
      printf 'HOST_PORT=%s\n' "$host_port" >> "$env_file"
    fi
    return 0
  fi

  local jwt_secret admin_pass
  jwt_secret="$(gen_secret 32)"
  admin_pass="$(gen_secret 8)"

  cat > "$env_file" <<EOF
# Sub2API 环境变量（由 apibox 自动生成）
TZ=Asia/Shanghai
PORT=${PROJ_INNER_PORT}
HOST_PORT=${host_port}
JWT_SECRET=${jwt_secret}
ADMIN_PASSWORD=${admin_pass}
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
  sub2api:
    image: ${image}
    container_name: ${PROJ_CONTAINER_NAME}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "${host_port}:${PROJ_INNER_PORT}"
    volumes:
      - ./data:/app/data
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
  printf '  %b配置文件目录%b : %s\n' "$C_BOLD" "$C_RESET" "$app_dir" >&2
  if [ -f "${app_dir}/.env" ]; then
    printf '  %b初始密钥查看%b : %bcat %s/.env%b\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$app_dir" "$C_RESET" >&2
  fi
}

project_install()   { base_project_install "$@"; }
project_status()    { base_project_status "$@"; }
project_logs()      { base_project_logs "$@"; }
project_restart()   { base_project_restart "$@"; }
project_upgrade()   { base_project_upgrade "$@"; }
project_uninstall() { base_project_uninstall "$@"; }

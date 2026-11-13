#!/usr/bin/env bash
# ==============================================================================
# 新增项目标准模板（projects/_template.sh）
# 扩展步骤：
#   1. 复制本文件为 projects/<新项目ID>.sh
#   2. 修改下方 PROJ_* 元数据与 project_write_env / project_write_compose
#   3. 在根目录 projects.conf 中追加一行注册信息即可在菜单中自动生效
# ==============================================================================

PROJ_ID="example"
PROJ_NAME="示例反代项目"
PROJ_DESC="请在这里填写一句话中文简介"
PROJ_REPO="https://github.com/owner/repo"
PROJ_DEFAULT_IMAGE="owner/repo:latest"
PROJ_INNER_PORT="8000"
PROJ_DEFAULT_HOST_PORT="8000"
PROJ_CONTAINER_NAME="vps-proxy-example"

project_write_env() {
  local app_dir="$1"
  local env_file="${app_dir}/.env"
  [ "$DRY_RUN" = "1" ] && return 0
  if [ ! -f "$env_file" ]; then
    printf 'TZ=Asia/Shanghai\n' > "$env_file"
    chmod 600 "$env_file"
  fi
}

project_write_compose() {
  local app_dir="$1"
  local host_port="$2"
  local image="$3"
  local compose_file="${app_dir}/docker-compose.yml"
  [ "$DRY_RUN" = "1" ] && return 0

  mkdir -p "${app_dir}/data"
  cat > "$compose_file" <<EOF
services:
  app:
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

project_install()   { base_project_install "$@"; }
project_status()    { base_project_status "$@"; }
project_logs()      { base_project_logs "$@"; }
project_restart()   { base_project_restart "$@"; }
project_upgrade()   { base_project_upgrade "$@"; }
project_uninstall() { base_project_uninstall "$@"; }

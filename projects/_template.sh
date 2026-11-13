#!/usr/bin/env bash
# ==============================================================================
# 新增项目标准模板（projects/_template.sh）
# 扩展步骤：
#   1. 复制本文件为 projects/<新项目ID>.sh
#   2. 修改下方 PROJ_* 元数据与 docker-compose.yml 模板
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

_tpl_dir() { printf '%s/%s' "$VPS_BASE_DIR" "$PROJ_ID"; }
_tpl_conf() { printf '%s/.install.conf' "$(_tpl_dir)"; }
_tpl_compose() { printf '%s/docker-compose.yml' "$(_tpl_dir)"; }

_tpl_load_saved() {
  local conf
  conf="$(_tpl_conf)"
  SAVED_PORT=""
  SAVED_DOMAIN=""
  SAVED_EMAIL=""
  SAVED_IMAGE=""
  [ -f "$conf" ] && load_conf_safe "$conf" "SAVED_PORT" "SAVED_DOMAIN" "SAVED_EMAIL" "SAVED_IMAGE" || true
}

project_install() {
  ensure_root "$@"
  _tpl_load_saved
  local app_dir compose_file
  app_dir="$(_tpl_dir)"
  compose_file="$(_tpl_compose)"

  log_step 1 5 "检查系统依赖与 Docker 容器环境"
  ensure_base_deps
  ensure_docker_ready || return 1
  ensure_proxy_network "$PROXY_NET_NAME"

  log_step 2 5 "配置服务访问端口"
  local target_port="${CLI_PORT:-${SAVED_PORT:-$PROJ_DEFAULT_HOST_PORT}}"
  [ "$target_port" = "auto" ] && target_port="$(pick_free_port "$PROJ_DEFAULT_HOST_PORT")"
  if [ -z "${CLI_PORT:-}" ]; then
    target_port="$(ask "请输入 ${PROJ_NAME} 监听端口" "$target_port")"
  fi

  log_step 3 5 "配置域名与 HTTPS 证书"
  local domain="${CLI_DOMAIN:-}" email="${CLI_EMAIL:-$SAVED_EMAIL}" use_domain=0
  if [ "${CLI_NO_DOMAIN:-0}" != "1" ] && [ -z "$domain" ]; then
    if ask_yn "是否绑定域名并自动申请免费 HTTPS 证书？" "n"; then
      domain="$(ask "请输入已解析到本机的域名" "$SAVED_DOMAIN")"
      [ -n "$domain" ] && is_valid_domain "$domain" && check_domain_dns "$domain" && use_domain=1
      [ "$use_domain" -eq 1 ] && email="$(ask "请输入证书到期提醒邮箱（可选）" "$SAVED_EMAIL")"
    fi
  elif [ -n "$domain" ]; then
    use_domain=1
  fi

  log_step 4 5 "生成配置并启动容器"
  local image="${CLI_IMAGE:-${SAVED_IMAGE:-$PROJ_DEFAULT_IMAGE}}"
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "${app_dir}/data"
    if [ ! -f "${app_dir}/.env" ]; then
      printf 'TZ=Asia/Shanghai\n' > "${app_dir}/.env"
      chmod 600 "${app_dir}/.env"
    fi
    cat > "$compose_file" <<EOF
services:
  app:
    image: ${image}
    container_name: ${PROJ_CONTAINER_NAME}
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "${target_port}:${PROJ_INNER_PORT}"
    volumes:
      - ./data:/data
    networks:
      - default
      - ${PROXY_NET_NAME}

networks:
  ${PROXY_NET_NAME}:
    external: true
EOF
    compose_cmd "$compose_file" pull || true
    compose_cmd "$compose_file" up -d
    wait_container_ready "$PROJ_CONTAINER_NAME" "$target_port" 45 || {
      handle_container_failure "$PROJ_CONTAINER_NAME" "$compose_file" "启动后端口探活超时"
      return 1
    }
  fi

  log_step 5 5 "配置防火墙与反向代理"
  open_firewall_port "$target_port"
  local final_domain=""
  if [ "$use_domain" -eq 1 ] && [ -n "$domain" ]; then
    configure_domain_ssl "$PROJ_ID" "$domain" "${PROJ_CONTAINER_NAME}:${PROJ_INNER_PORT}" "$target_port" "$email" && final_domain="$domain"
  fi
  save_conf_kv "$(_tpl_conf)" "SAVED_PORT" "$target_port" "SAVED_DOMAIN" "$final_domain" "SAVED_EMAIL" "$email" "SAVED_IMAGE" "$image"
  log_ok "${PROJ_NAME} 安装完成！"
}

project_status() {
  _tpl_load_saved
  local compose_file
  compose_file="$(_tpl_compose)"
  [ -f "$compose_file" ] || { log_warn "尚未安装 ${PROJ_NAME}。"; return 0; }
  docker ps -a --filter "name=^/${PROJ_CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" >&2 || true
}

project_logs() {
  docker logs --tail 80 "$PROJ_CONTAINER_NAME" 2>&1 || true
}

project_restart() {
  compose_cmd "$(_tpl_compose)" restart
}

project_upgrade() {
  compose_cmd "$(_tpl_compose)" pull && compose_cmd "$(_tpl_compose)" up -d
}

project_uninstall() {
  ensure_root "$@"
  local app_dir compose_file
  app_dir="$(_tpl_dir)"
  compose_file="$(_tpl_compose)"
  ask_yn "确认卸载 ${PROJ_NAME} 吗？" "n" || return 0
  [ "$DRY_RUN" != "1" ] && [ -f "$compose_file" ] && compose_cmd "$compose_file" down || true
  remove_domain_ssl "$PROJ_ID"
  if [ -d "$app_dir" ] && ask_yn "是否删除数据目录 ${app_dir}？" "n"; then
    run_cmd rm -rf "$app_dir"
  fi
  log_ok "${PROJ_NAME} 已卸载。"
}

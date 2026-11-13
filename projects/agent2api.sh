#!/usr/bin/env bash
# ==============================================================================
# 项目安装脚本：Agent2API（aimod-cc/agent2api）
# 接口约定：由入口脚本 install.sh 调用，需实现以下标准函数：
#   project_install | project_status | project_logs | project_restart | project_upgrade | project_uninstall
# ==============================================================================

PROJ_ID="agent2api"
PROJ_NAME="Agent2API"
PROJ_DESC="一体化 AI Agent 网关与管理面板（OpenAI 兼容 /v1 接口 + 多渠道聚合）"
PROJ_REPO="https://github.com/aimod-cc/agent2api"
PROJ_DEFAULT_IMAGE="aimodcc/agent2api:latest"
PROJ_INNER_PORT="3065"
PROJ_DEFAULT_HOST_PORT="3065"
PROJ_CONTAINER_NAME="vps-proxy-agent2api"

_agent2api_dir() {
  printf '%s/%s' "$VPS_BASE_DIR" "$PROJ_ID"
}

_agent2api_conf() {
  printf '%s/.install.conf' "$(_agent2api_dir)"
}

_agent2api_compose() {
  printf '%s/docker-compose.yml' "$(_agent2api_dir)"
}

_agent2api_load_saved() {
  local conf
  conf="$(_agent2api_conf)"
  SAVED_PORT=""
  SAVED_DOMAIN=""
  SAVED_EMAIL=""
  SAVED_IMAGE=""
  if [ -f "$conf" ]; then
    load_conf_safe "$conf" "SAVED_PORT" "SAVED_DOMAIN" "SAVED_EMAIL" "SAVED_IMAGE" || true
  fi
}

_agent2api_write_env() {
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

_agent2api_write_compose() {
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

project_install() {
  ensure_root "$@"
  _agent2api_load_saved

  local app_dir
  app_dir="$(_agent2api_dir)"

  print_hr
  printf "  %b准备安装：%s%b\n" "$C_BOLD" "$PROJ_NAME" "$C_RESET" >&2
  printf "  说明：%s\n" "$PROJ_DESC" >&2
  printf "  开源地址：%s\n" "$PROJ_REPO" >&2
  printf "  安装目录：%s\n" "$app_dir" >&2
  print_hr

  if [ -f "$(_agent2api_conf)" ]; then
    log_info "检测到本机已安装过 ${PROJ_NAME}，本次操作将保留数据并按新参数安全更新配置。"
  fi

  # 第 1 步：基础依赖与 Docker 就绪
  log_step 1 5 "检查系统依赖与 Docker 容器环境"
  ensure_base_deps
  ensure_docker_ready || return 1
  ensure_proxy_network "$PROXY_NET_NAME"

  # 第 2 步：配置服务端口
  log_step 2 5 "配置服务访问端口"
  local target_port="${CLI_PORT:-${SAVED_PORT:-$PROJ_DEFAULT_HOST_PORT}}"
  if [ "$target_port" = "auto" ]; then
    target_port="$(pick_free_port "$PROJ_DEFAULT_HOST_PORT")"
    log_info "已自动选择空闲端口: ${target_port}"
  fi

  if [ "$DRY_RUN" != "1" ]; then
    local owner
    owner="$(describe_port_owner "$target_port")"
    if is_port_in_use "$target_port" && [ "$owner" != "容器:${PROJ_CONTAINER_NAME}" ]; then
      local suggested
      suggested="$(pick_free_port $((target_port + 1)))"
      log_warn "端口 ${target_port} 已被 [${owner}] 占用，自动为您推荐空闲端口: ${suggested}"
      target_port="$suggested"
    fi
  fi

  if [ -z "${CLI_PORT:-}" ]; then
    while true; do
      target_port="$(ask "请输入 Agent2API 宿主机监听端口" "$target_port")"
      if ! is_valid_port "$target_port"; then
        log_warn "端口必须是 1 到 65535 之间的纯数字。"
        continue
      fi
      local owner
      owner="$(describe_port_owner "$target_port")"
      if [ "$DRY_RUN" != "1" ] && is_port_in_use "$target_port" && [ "$owner" != "容器:${PROJ_CONTAINER_NAME}" ]; then
        log_warn "端口 ${target_port} 已被 [${owner}] 占用，请换一个端口。"
        continue
      fi
      break
    done
  fi
  log_ok "已选定服务端口: ${target_port}"

  # 第 3 步：配置域名与证书
  log_step 3 5 "配置域名与 HTTPS（Let's Encrypt 免费证书）"
  local domain="" email="" use_domain=0

  if [ "${CLI_NO_DOMAIN:-0}" = "1" ]; then
    use_domain=0
  elif [ -n "${CLI_DOMAIN:-}" ]; then
    domain="$CLI_DOMAIN"
    email="${CLI_EMAIL:-$SAVED_EMAIL}"
    use_domain=1
  else
    local default_yn="n"
    [ -n "$SAVED_DOMAIN" ] && default_yn="y"
    if ask_yn "是否绑定域名并自动申请免费 HTTPS 证书？（选 n 可先用 IP:端口 访问）" "$default_yn"; then
      while true; do
        domain="$(ask "请输入已解析到本机的域名（如 agent.example.com）" "$SAVED_DOMAIN")"
        if [ -z "$domain" ]; then
          log_info "未输入域名，将改为仅使用 IP + 端口访问。"
          use_domain=0
          break
        fi
        if ! is_valid_domain "$domain"; then
          log_warn "域名格式看起来不正确（示例：agent.example.com），请重新输入。"
          continue
        fi
        if check_domain_dns "$domain"; then
          use_domain=1
          email="$(ask "请输入接收证书到期提醒的邮箱（可直接回车跳过）" "$SAVED_EMAIL")"
          break
        fi
      done
    else
      use_domain=0
    fi
  fi

  # 第 4 步：生成配置并拉起容器
  log_step 4 5 "生成配置并拉取启动 Agent2API 容器"
  local image="${CLI_IMAGE:-${SAVED_IMAGE:-$PROJ_DEFAULT_IMAGE}}"
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$app_dir"
  fi
  _agent2api_write_env "$app_dir"
  _agent2api_write_compose "$app_dir" "$target_port" "$image"

  local compose_file
  compose_file="$(_agent2api_compose)"
  if [ "$DRY_RUN" != "1" ]; then
    local out
    if ! out="$(compose_cmd "$compose_file" pull 2>&1)" ; then
      log_warn "镜像拉取过程有提示信息，尝试继续启动..."
      printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2
    fi
    if ! out="$(compose_cmd "$compose_file" up -d 2>&1)"; then
      handle_container_failure "$PROJ_CONTAINER_NAME" "$compose_file" "$out"
      return 1
    fi
    if ! wait_container_ready "$PROJ_CONTAINER_NAME" "$target_port" 45; then
      handle_container_failure "$PROJ_CONTAINER_NAME" "$compose_file" "容器启动后端口探活超时"
      return 1
    fi
  else
    log_info "[演练模式] 将执行 docker compose pull && docker compose up -d"
  fi

  # 第 5 步：放行端口、绑定反代与保存状态
  log_step 5 5 "配置网络访问与保存安装记录"
  open_firewall_port "$target_port"

  local final_domain=""
  if [ "$use_domain" -eq 1 ] && [ -n "$domain" ]; then
    if configure_domain_ssl "$PROJ_ID" "$domain" "${PROJ_CONTAINER_NAME}:${PROJ_INNER_PORT}" "$target_port" "$email"; then
      final_domain="$domain"
    else
      log_warn "域名自动配置未完成，您仍可通过 IP + 端口访问服务。"
    fi
  else
    if [ -n "$SAVED_DOMAIN" ]; then
      remove_domain_ssl "$PROJ_ID"
    fi
  fi

  save_conf_kv "$(_agent2api_conf)" \
    "SAVED_PORT" "$target_port" \
    "SAVED_DOMAIN" "$final_domain" \
    "SAVED_EMAIL" "$email" \
    "SAVED_IMAGE" "$image"

  local pub_ip
  pub_ip="$(get_public_ip || echo '服务器公网IP')"
  printf "\n" >&2
  print_hr
  log_ok "${PROJ_NAME} 安装并启动成功！"
  printf "  %bIP 直接访问%b  : http://%s:%s\n" "$C_BOLD" "$C_RESET" "$pub_ip" "$target_port" >&2
  if [ -n "$final_domain" ]; then
    printf "  %bHTTPS 域名%b   : https://%s\n" "$C_BOLD" "$C_RESET" "$final_domain" >&2
  fi
  printf "  %b首次使用提示%b : 打开上方地址即可注册管理员账号，并在「网关 Key」页创建密钥\n" "$C_BOLD" "$C_RESET" >&2
  printf "  %b数据配置目录%b : %s/data\n" "$C_BOLD" "$C_RESET" "$app_dir" >&2
  printf "  %b查看运行日志%b : %bdocker logs -f --tail 100 %s%b\n" "$C_BOLD" "$C_RESET" "$C_GREEN" "$PROJ_CONTAINER_NAME" "$C_RESET" >&2
  printf "  %b重启服务命令%b : %bdocker compose -f %s restart%b\n" "$C_BOLD" "$C_RESET" "$C_GREEN" "$compose_file" "$C_RESET" >&2
  print_hr
}

project_status() {
  _agent2api_load_saved
  local app_dir compose_file pub_ip
  app_dir="$(_agent2api_dir)"
  compose_file="$(_agent2api_compose)"
  pub_ip="$(get_public_ip || echo '未知')"

  print_hr
  printf "  %b项目名称%b : %s (%s)\n" "$C_BOLD" "$C_RESET" "$PROJ_NAME" "$PROJ_ID" >&2
  if [ ! -f "$compose_file" ]; then
    log_warn "尚未安装 ${PROJ_NAME}。"
    print_hr
    return 0
  fi
  printf "  %b安装目录%b : %s\n" "$C_BOLD" "$C_RESET" "$app_dir" >&2
  printf "  %b监听端口%b : %s\n" "$C_BOLD" "$C_RESET" "${SAVED_PORT:-未知}" >&2
  printf "  %b访问地址%b : http://%s:%s\n" "$C_BOLD" "$C_RESET" "$pub_ip" "${SAVED_PORT:-$PROJ_DEFAULT_HOST_PORT}" >&2
  [ -n "$SAVED_DOMAIN" ] && printf "  %b绑定域名%b : https://%s\n" "$C_BOLD" "$C_RESET" "$SAVED_DOMAIN" >&2
  if command -v docker >/dev/null 2>&1; then
    printf "\n  %b容器状态:%b\n" "$C_BOLD" "$C_RESET" >&2
    docker ps -a --filter "name=^/${PROJ_CONTAINER_NAME}$" \
      --format "  名称: {{.Names}} | 状态: {{.Status}} | 镜像: {{.Image}}" >&2 || true
  fi
  print_hr
}

project_logs() {
  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$PROJ_CONTAINER_NAME"; then
    log_warn "未找到容器 ${PROJ_CONTAINER_NAME}，可能尚未安装。"
    return 1
  fi
  log_info "显示最近 80 行日志（如需持续跟踪可手动运行: docker logs -f ${PROJ_CONTAINER_NAME}）："
  print_hr
  docker logs --tail 80 "$PROJ_CONTAINER_NAME" 2>&1 || true
  print_hr
}

project_restart() {
  local compose_file
  compose_file="$(_agent2api_compose)"
  [ -f "$compose_file" ] || { log_warn "尚未安装 ${PROJ_NAME}。"; return 1; }
  log_info "正在重启 ${PROJ_NAME}..."
  run_cmd compose_cmd "$compose_file" restart
  log_ok "${PROJ_NAME} 已重启。"
}

project_upgrade() {
  local compose_file
  compose_file="$(_agent2api_compose)"
  [ -f "$compose_file" ] || { log_warn "尚未安装 ${PROJ_NAME}。"; return 1; }
  log_info "正在拉取最新镜像并滚动重建 ${PROJ_NAME}（原有数据不会丢失）..."
  if [ "$DRY_RUN" != "1" ]; then
    compose_cmd "$compose_file" pull
    compose_cmd "$compose_file" up -d
  fi
  log_ok "${PROJ_NAME} 更新完成。"
}

project_uninstall() {
  ensure_root "$@"
  local app_dir compose_file
  app_dir="$(_agent2api_dir)"
  compose_file="$(_agent2api_compose)"

  if [ ! -d "$app_dir" ] && ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$PROJ_CONTAINER_NAME"; then
    log_warn "${PROJ_NAME} 尚未安装，无需卸载。"
    return 0
  fi

  if ! ask_yn "确认停止并卸载 ${PROJ_NAME} 容器及反代配置吗？" "n"; then
    log_info "已取消卸载。"
    return 0
  fi

  if [ "$DRY_RUN" != "1" ]; then
    [ -f "$compose_file" ] && compose_cmd "$compose_file" down 2>/dev/null || docker rm -f "$PROJ_CONTAINER_NAME" 2>/dev/null || true
  else
    log_info "[演练模式] 将停止并移除容器 ${PROJ_CONTAINER_NAME}"
  fi

  remove_domain_ssl "$PROJ_ID"

  if [ -d "$app_dir" ]; then
    if ask_yn "是否同时删除数据目录 ${app_dir}？（包含数据库与配置，删除后不可恢复）" "n"; then
      run_cmd rm -rf "$app_dir"
      log_ok "已彻底删除 ${app_dir}。"
    else
      log_info "已保留数据目录 ${app_dir}，后续重装可无缝恢复。"
    fi
  fi
  log_ok "${PROJ_NAME} 卸载完成。"
}

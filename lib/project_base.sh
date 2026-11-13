#!/usr/bin/env bash
# ==============================================================================
# 项目通用生命周期基础库（lib/project_base.sh）
# 收拢所有项目共用的端口/域名/邮箱交互、容器启动探活、状态/日志/重启/升级/卸载
# ==============================================================================

if [ "${_LIB_PROJECT_BASE_LOADED:-0}" = "1" ]; then
  return 0
fi
_LIB_PROJECT_BASE_LOADED=1

base_app_dir() {
  printf '%s/%s' "$VPS_BASE_DIR" "$PROJ_ID"
}

base_conf_file() {
  printf '%s/.install.conf' "$(base_app_dir)"
}

base_compose_file() {
  printf '%s/docker-compose.yml' "$(base_app_dir)"
}

base_load_saved() {
  local conf
  conf="$(base_conf_file)"
  SAVED_PORT=""
  SAVED_DOMAIN=""
  SAVED_EMAIL=""
  SAVED_IMAGE=""
  if [ -f "$conf" ]; then
    load_conf_safe "$conf" "SAVED_PORT" "SAVED_DOMAIN" "SAVED_EMAIL" "SAVED_IMAGE" || true
  fi
}

# 通用安装主流程
# 依赖项目脚本已定义：
#   PROJ_ID, PROJ_NAME, PROJ_DESC, PROJ_REPO, PROJ_DEFAULT_IMAGE,
#   PROJ_INNER_PORT, PROJ_DEFAULT_HOST_PORT, PROJ_CONTAINER_NAME
#   project_write_env(app_dir, host_port)
#   project_write_compose(app_dir, host_port, image)
#   project_post_install_tips(app_dir, compose_file) [可选]
base_project_install() {
  ensure_root "$@"
  base_load_saved

  local app_dir compose_file
  app_dir="$(base_app_dir)"
  compose_file="$(base_compose_file)"

  print_hr
  printf '  %b准备安装：%s%b\n' "$C_BOLD" "$PROJ_NAME" "$C_RESET" >&2
  printf '  说明：%s\n' "$PROJ_DESC" >&2
  printf '  开源地址：%s\n' "$PROJ_REPO" >&2
  printf '  安装目录：%s\n' "$app_dir" >&2
  print_hr

  if [ -f "$(base_conf_file)" ]; then
    log_info "检测到本机已安装过 ${PROJ_NAME}，本次操作将保留数据并按新参数安全更新配置。"
  fi

  # 第 1 步：基础依赖与 Docker 就绪
  log_step 1 5 "检查系统依赖与 Docker 容器环境"
  ensure_base_deps
  ensure_docker_ready || return 1
  ensure_proxy_network "$PROXY_NET_NAME"

  # 第 2 步：配置服务端口（冲突自动推荐空闲端口）
  log_step 2 5 "配置服务访问端口"
  local target_port="${CLI_PORT:-${SAVED_PORT:-$PROJ_DEFAULT_HOST_PORT}}"
  if [ "$target_port" = "auto" ]; then
    target_port="$(pick_free_port "$PROJ_DEFAULT_HOST_PORT")" || die "未能找到 65000 以下的可用空闲端口，请手动释放端口后重试。"
    log_info "已自动选择空闲端口: ${target_port}"
  fi

  if [ "$DRY_RUN" != "1" ]; then
    local owner
    owner="$(describe_port_owner "$target_port")"
    if is_port_in_use "$target_port" && [ "$owner" != "容器:${PROJ_CONTAINER_NAME}" ]; then
      local suggested
      suggested="$(pick_free_port $((target_port + 1)))" || die "端口 ${target_port} 已被占用且未找到可用备选端口。"
      log_warn "端口 ${target_port} 已被 [${owner:-未知进程}] 占用，自动为您推荐空闲端口: ${suggested}"
      target_port="$suggested"
    fi
  fi

  if [ -z "${CLI_PORT:-}" ]; then
    while true; do
      target_port="$(ask "请输入 ${PROJ_NAME} 宿主机监听端口" "$target_port")"
      if ! is_valid_port "$target_port"; then
        log_warn "端口必须是 1 到 65535 之间的纯数字（不能以 0 开头）。"
        [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ] && die "非交互模式下默认端口无效: ${target_port}"
        continue
      fi
      local owner
      owner="$(describe_port_owner "$target_port")"
      if [ "$DRY_RUN" != "1" ] && is_port_in_use "$target_port" && [ "$owner" != "容器:${PROJ_CONTAINER_NAME}" ]; then
        log_warn "端口 ${target_port} 已被 [${owner:-未知进程}] 占用，请换一个端口。"
        [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ] && die "非交互模式下端口 ${target_port} 已被占用，请用 --port auto 或指定其他端口。"
        continue
      fi
      break
    done
  fi
  log_ok "已选定服务端口: ${target_port}"

  # 第 3 步：配置域名与 HTTPS 证书
  log_step 3 5 "配置域名与 HTTPS（Let's Encrypt 免费证书）"
  local domain="" email="" use_domain=0

  if [ "${CLI_NO_DOMAIN:-0}" = "1" ]; then
    use_domain=0
  elif [ -n "${CLI_DOMAIN:-}" ]; then
    domain="$(normalize_domain "$CLI_DOMAIN")"
    email="${CLI_EMAIL:-$SAVED_EMAIL}"
    use_domain=1
  else
    local default_yn="n"
    [ -n "$SAVED_DOMAIN" ] && default_yn="y"
    if ask_yn "是否绑定域名并自动申请免费 HTTPS 证书？（选 n 可先用 IP:端口 访问）" "$default_yn"; then
      while true; do
        domain="$(ask "请输入已解析到本机的域名（如 ${PROJ_ID}.example.com）" "$SAVED_DOMAIN")"
        if [ -z "$domain" ]; then
          log_info "未输入域名，将改为仅使用 IP + 端口访问。"
          use_domain=0
          break
        fi
        if ! is_valid_domain "$domain"; then
          log_warn "域名格式看起来不正确（示例：${PROJ_ID}.example.com），请重新输入。"
          continue
        fi
        domain="$(normalize_domain "$domain")"
        if check_domain_dns "$domain"; then
          use_domain=1
          while true; do
            email="$(ask "请输入接收证书到期提醒的邮箱（可直接回车跳过）" "$SAVED_EMAIL")"
            if is_valid_email "$email"; then
              break
            fi
            log_warn "邮箱格式不正确（示例：admin@example.com），或直接回车跳过。"
          done
          break
        fi
      done
    else
      use_domain=0
    fi
  fi

  # 第 4 步：生成配置并拉起容器
  log_step 4 5 "生成配置并拉取启动 ${PROJ_NAME} 容器"
  local image="${CLI_IMAGE:-${SAVED_IMAGE:-$PROJ_DEFAULT_IMAGE}}"
  local compose_bak=""
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$app_dir"
    if [ -f "$compose_file" ]; then
      compose_bak="${compose_file}.bak.$$"
      cp "$compose_file" "$compose_bak"
    fi
  fi
  project_write_env "$app_dir" "$target_port"
  project_write_compose "$app_dir" "$target_port" "$image"

  if [ "$DRY_RUN" != "1" ]; then
    local out
    if ! out="$(compose_cmd "$compose_file" pull 2>&1)" ; then
      log_warn "镜像拉取过程有提示信息，尝试继续启动..."
      printf '%s\n' "$out" | tail -5 | sed 's/^/    /' >&2
    fi
    if ! out="$(compose_cmd "$compose_file" up -d 2>&1)"; then
      handle_container_failure "$PROJ_CONTAINER_NAME" "$compose_file" "$out"
      [ -n "$compose_bak" ] && [ -f "$compose_bak" ] && mv "$compose_bak" "$compose_file"
      return 1
    fi
    if ! wait_container_ready "$PROJ_CONTAINER_NAME" "$target_port" 45; then
      handle_container_failure "$PROJ_CONTAINER_NAME" "$compose_file" "容器启动后端口探活超时"
      [ -n "$compose_bak" ] && [ -f "$compose_bak" ] && mv "$compose_bak" "$compose_file"
      return 1
    fi
    [ -n "$compose_bak" ] && rm -f "$compose_bak"
  else
    log_info "[演练模式] 将执行 docker compose pull && docker compose up -d"
  fi

  # 第 5 步：放行端口、绑定反代与保存状态
  log_step 5 5 "配置网络访问与保存安装记录"
  local final_domain=""
  if [ "$use_domain" -eq 1 ] && [ -n "$domain" ]; then
    if configure_domain_ssl "$PROJ_ID" "$domain" "${PROJ_CONTAINER_NAME}:${PROJ_INNER_PORT}" "$target_port" "$email"; then
      final_domain="$domain"
    else
      log_warn "域名自动配置未完成，将放行端口以便通过 IP + 端口访问服务。"
      open_firewall_port "$target_port"
      [ -n "$SAVED_DOMAIN" ] && remove_domain_ssl "$PROJ_ID"
    fi
  else
    open_firewall_port "$target_port"
    if [ -n "$SAVED_DOMAIN" ]; then
      remove_domain_ssl "$PROJ_ID"
    fi
  fi

  save_conf_kv "$(base_conf_file)" \
    "SAVED_PORT" "$target_port" \
    "SAVED_DOMAIN" "$final_domain" \
    "SAVED_EMAIL" "$email" \
    "SAVED_IMAGE" "$image"

  local pub_ip
  pub_ip="$(get_public_ip || echo '服务器公网IP')"
  printf '\n' >&2
  print_hr
  log_ok "${PROJ_NAME} 安装并启动成功！"
  printf '  %bIP 直接访问%b  : http://%s:%s\n' "$C_BOLD" "$C_RESET" "$pub_ip" "$target_port" >&2
  if [ -n "$final_domain" ]; then
    printf '  %bHTTPS 域名%b   : https://%s\n' "$C_BOLD" "$C_RESET" "$final_domain" >&2
  fi
  if declare -F project_post_install_tips >/dev/null 2>&1; then
    project_post_install_tips "$app_dir" "$compose_file"
  fi
  printf '  %b查看运行日志%b : %bdocker logs -f --tail 100 %s%b\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$PROJ_CONTAINER_NAME" "$C_RESET" >&2
  printf '  %b重启服务命令%b : %bdocker compose -f %s restart%b\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$compose_file" "$C_RESET" >&2
  print_hr
}

base_project_status() {
  base_load_saved
  local app_dir compose_file pub_ip
  app_dir="$(base_app_dir)"
  compose_file="$(base_compose_file)"
  pub_ip="$(get_public_ip || echo '未知')"

  print_hr
  printf '  %b项目名称%b : %s (%s)\n' "$C_BOLD" "$C_RESET" "$PROJ_NAME" "$PROJ_ID" >&2
  if [ ! -f "$compose_file" ]; then
    log_warn "尚未安装 ${PROJ_NAME}。"
    print_hr
    return 0
  fi
  printf '  %b安装目录%b : %s\n' "$C_BOLD" "$C_RESET" "$app_dir" >&2
  printf '  %b监听端口%b : %s\n' "$C_BOLD" "$C_RESET" "${SAVED_PORT:-未知}" >&2
  printf '  %b访问地址%b : http://%s:%s\n' "$C_BOLD" "$C_RESET" "$pub_ip" "${SAVED_PORT:-$PROJ_DEFAULT_HOST_PORT}" >&2
  [ -n "$SAVED_DOMAIN" ] && printf '  %b绑定域名%b : https://%s\n' "$C_BOLD" "$C_RESET" "$SAVED_DOMAIN" >&2
  if command -v docker >/dev/null 2>&1; then
    printf '\n  %b容器状态:%b\n' "$C_BOLD" "$C_RESET" >&2
    if docker info >/dev/null 2>&1; then
      docker ps -a --filter "name=^/${PROJ_CONTAINER_NAME}$" \
        --format "  名称: {{.Names}} | 状态: {{.Status}} | 镜像: {{.Image}}" >&2 || true
    else
      printf '  Docker 服务当前未运行。\n' >&2
    fi
  fi
  print_hr
}

base_project_logs() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    log_warn "Docker 未安装或服务未运行，无法读取容器日志。"
    return 1
  fi
  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$PROJ_CONTAINER_NAME"; then
    log_warn "未找到容器 ${PROJ_CONTAINER_NAME}，可能尚未安装。"
    return 1
  fi
  log_info "显示最近 80 行日志（如需持续跟踪可手动运行: docker logs -f ${PROJ_CONTAINER_NAME}）："
  print_hr
  docker logs --tail 80 "$PROJ_CONTAINER_NAME" 2>&1 || true
  print_hr
}

base_project_restart() {
  local compose_file
  compose_file="$(base_compose_file)"
  [ -f "$compose_file" ] || { log_warn "尚未安装 ${PROJ_NAME}。"; return 1; }
  log_info "正在重启 ${PROJ_NAME}..."
  ensure_proxy_network "$PROXY_NET_NAME" || return 1
  run_cmd compose_cmd "$compose_file" restart
  log_ok "${PROJ_NAME} 已重启。"
}

base_project_upgrade() {
  ensure_root "$@"
  base_load_saved
  local compose_file
  compose_file="$(base_compose_file)"
  [ -f "$compose_file" ] || { log_warn "尚未安装 ${PROJ_NAME}。"; return 1; }
  log_info "正在拉取最新镜像并滚动重建 ${PROJ_NAME}（原有数据不会丢失，失败将自动回滚）..."
  if [ "$DRY_RUN" != "1" ]; then
    ensure_proxy_network "$PROXY_NET_NAME" || return 1
    local old_image_id="" compose_bak="" target_image=""
    if docker info >/dev/null 2>&1; then
      old_image_id="$(docker inspect -f '{{.Image}}' "$PROJ_CONTAINER_NAME" 2>/dev/null || true)"
    fi
    if [ -n "${CLI_IMAGE:-}" ]; then
      target_image="$CLI_IMAGE"
      compose_bak="${compose_file}.upgrade.bak.$$"
      cp "$compose_file" "$compose_bak"
      local tmp_c="${compose_file}.tmp.$$"
      awk -v img="$target_image" '
        !done && /^[[:space:]]*image:[[:space:]]*/ {
          sub(/image:.*/, "image: " img); done=1
        }
        { print }
      ' "$compose_file" > "$tmp_c" && mv "$tmp_c" "$compose_file" || { rm -f "$tmp_c" "$compose_bak"; return 1; }
    fi
    if ! compose_cmd "$compose_file" pull; then
      log_err "拉取新镜像失败，已保留原运行容器未做改动。"
      [ -n "$compose_bak" ] && [ -f "$compose_bak" ] && mv "$compose_bak" "$compose_file"
      return 1
    fi
    if ! compose_cmd "$compose_file" up -d || ! wait_container_ready "$PROJ_CONTAINER_NAME" "${SAVED_PORT:-$PROJ_DEFAULT_HOST_PORT}" 45; then
      log_err "新版本启动或探活失败！正在尝试自动回滚到升级前版本..."
      [ -n "$compose_bak" ] && [ -f "$compose_bak" ] && mv "$compose_bak" "$compose_file"
      if [ -n "$old_image_id" ]; then
        local current_img_ref
        current_img_ref="$(awk '/^[[:space:]]*image:[[:space:]]*/{print $2; exit}' "$compose_file" 2>/dev/null | tr -d '"' | tr -d "'" || true)"
        [ -z "$current_img_ref" ] && current_img_ref="${SAVED_IMAGE:-$PROJ_DEFAULT_IMAGE}"
        docker tag "$old_image_id" "$current_img_ref" 2>/dev/null || true
        if compose_cmd "$compose_file" up -d 2>/dev/null && \
           wait_container_ready "$PROJ_CONTAINER_NAME" "${SAVED_PORT:-$PROJ_DEFAULT_HOST_PORT}" 30; then
          log_ok "已成功回滚并恢复升级前镜像（ID: ${old_image_id:0:19}）。"
        else
          log_err "已尝试回滚到旧镜像（ID: ${old_image_id:0:19}），但服务未通过探活，请手动检查日志：docker logs --tail 50 ${PROJ_CONTAINER_NAME}"
        fi
      fi
      return 1
    fi
    [ -n "$compose_bak" ] && rm -f "$compose_bak"
    if [ -n "$target_image" ] && [ -f "$(base_conf_file)" ]; then
      save_conf_kv "$(base_conf_file)" \
        "SAVED_PORT" "${SAVED_PORT:-$PROJ_DEFAULT_HOST_PORT}" \
        "SAVED_DOMAIN" "${SAVED_DOMAIN:-}" \
        "SAVED_EMAIL" "${SAVED_EMAIL:-}" \
        "SAVED_IMAGE" "$target_image"
    fi
  else
    log_info "[演练模式] 将拉取镜像 ${CLI_IMAGE:-${SAVED_IMAGE:-$PROJ_DEFAULT_IMAGE}} 并执行带健康门禁的升级"
  fi
  log_ok "${PROJ_NAME} 更新完成。"
}

base_project_uninstall() {
  ensure_root "$@"
  local app_dir compose_file
  app_dir="$(base_app_dir)"
  compose_file="$(base_compose_file)"

  if [ ! -d "$app_dir" ] && ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$PROJ_CONTAINER_NAME"; then
    log_warn "${PROJ_NAME} 尚未安装，无需卸载。"
    return 0
  fi

  local confirm_def="n"
  [ "$ASSUME_YES" = "1" ] && [ "${CLI_ACTION:-}" = "uninstall" ] && confirm_def="y"
  if ! ask_yn "确认停止并卸载 ${PROJ_NAME} 容器及反代配置吗？" "$confirm_def"; then
    log_info "已取消卸载。"
    return 0
  fi

  if [ "$DRY_RUN" != "1" ]; then
    if [ -f "$compose_file" ]; then
      compose_cmd "$compose_file" down 2>/dev/null || docker rm -f "$PROJ_CONTAINER_NAME" 2>/dev/null || true
    else
      docker rm -f "$PROJ_CONTAINER_NAME" 2>/dev/null || true
    fi
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

#!/usr/bin/env bash
# ==============================================================================
# 反向代理与 Let's Encrypt SSL 证书管理库（lib/ssl.sh）
# 支持：内置 Caddy 自动签发/续期、宿主机 Caddy 幂等接入、Nginx 冲突引导与配置生成
# ==============================================================================

if [ "${_LIB_SSL_LOADED:-0}" = "1" ]; then
  return 0
fi
_LIB_SSL_LOADED=1

CADDY_CONTAINER_NAME="vps-proxy-caddy"
PROXY_NET_NAME="vps_proxy_net"

# 中断保护状态变量（防止 Ctrl-C 在修改宿主机 Caddyfile 中途留下半截配置）
_CADDY_BAK_ACTIVE=0
_CADDY_BAK_FILE=""
_CADDY_TARGET_CFG=""

_on_ssl_interrupt() {
  if [ "$_CADDY_BAK_ACTIVE" = "1" ] && [ -f "$_CADDY_BAK_FILE" ] && [ -n "$_CADDY_TARGET_CFG" ]; then
    cp "$_CADDY_BAK_FILE" "$_CADDY_TARGET_CFG" 2>/dev/null || true
    caddy validate --config "$_CADDY_TARGET_CFG" >/dev/null 2>&1 && caddy reload --config "$_CADDY_TARGET_CFG" >/dev/null 2>&1 || true
    log_warn "检测到操作中断，已自动回滚反代配置。"
  fi
  if declare -F release_instance_lock >/dev/null 2>&1; then
    release_instance_lock
  fi
  exit 130
}

# 解析域名当前指向的 IPv4 地址
resolve_domain_ipv4() {
  local domain="$1"
  local resolved=""
  if command -v dig >/dev/null 2>&1; then
    resolved="$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
  fi
  if [ -z "$resolved" ] && command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}' || true)"
  fi
  if [ -z "$resolved" ] && command -v nslookup >/dev/null 2>&1; then
    resolved="$(nslookup "$domain" 2>/dev/null | awk '/^Address: /{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
  fi
  printf '%s' "$resolved"
}

# 校验域名 DNS 解析是否指向本机公网 IP
check_domain_dns() {
  local domain="$1"
  if [ "$SKIP_DNS_CHECK" = "1" ] || [ "$DRY_RUN" = "1" ]; then
    log_info "已跳过域名 DNS 解析检查（${domain}）。"
    return 0
  fi

  local pub_ip resolved_ip
  pub_ip="$(get_public_ip || true)"
  resolved_ip="$(resolve_domain_ipv4 "$domain" || true)"

  if [ -z "$resolved_ip" ]; then
    log_warn "暂未查询到域名 [${domain}] 的 A 记录解析。"
    printf "  请先在您的域名服务商处添加一条 A 记录：\n" >&2
    printf "    类型: A  |  主机名: %s  |  记录值: %s\n" "$domain" "${pub_ip:-您的服务器公网IP}" >&2
    if ask_yn "如果您刚添加解析或使用 CDN 代理，是否仍要继续配置？" "n"; then
      return 0
    fi
    return 1
  fi

  if [ -n "$pub_ip" ] && [ "$resolved_ip" != "$pub_ip" ]; then
    log_warn "域名 [${domain}] 当前解析到 ${resolved_ip}，与本机公网 IP (${pub_ip}) 不一致。"
    printf "  常见原因：\n" >&2
    printf "    1) 您开启了 Cloudflare 橙色云朵（CDN 代理），属于正常现象；\n" >&2
    printf "    2) 域名还未改绑到本台服务器。\n" >&2
    if ask_yn "确定要继续为 [${domain}] 配置反向代理与证书吗？" "y"; then
      return 0
    fi
    return 1
  fi

  log_ok "域名解析验证通过：${domain} -> ${resolved_ip}"
  return 0
}

# 探测 80/443 端口归属形态
# 输出之一：self（空闲，使用内置 Caddy）| host_caddy（宿主机 Caddy）| self_caddy（本脚本已托管的 Caddy）| conflict:<进程名>
detect_proxy_mode() {
  local caddy_exists=0
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CADDY_CONTAINER_NAME"; then
    caddy_exists=1
  fi

  local p80_in_use=0 p443_in_use=0
  local used_list
  used_list="$(get_used_ports)"
  is_port_in_use 80 "$used_list" && p80_in_use=1
  is_port_in_use 443 "$used_list" && p443_in_use=1

  local owner80 owner443 owner
  owner80="$(describe_port_owner 80)"
  owner443="$(describe_port_owner 443)"
  owner="${owner80:-$owner443}"

  if [ "$caddy_exists" -eq 1 ]; then
    # 如果 80/443 已被非 vps-proxy-caddy 的其它进程抢占，不能盲目返回 self_caddy
    if { [ "$p80_in_use" -eq 1 ] && [ -n "$owner80" ] && [ "$owner80" != "容器:${CADDY_CONTAINER_NAME}" ]; } || \
       { [ "$p443_in_use" -eq 1 ] && [ -n "$owner443" ] && [ "$owner443" != "容器:${CADDY_CONTAINER_NAME}" ]; }; then
      printf 'conflict:%s' "${owner:-未知服务}"
      return 0
    fi
    printf 'self_caddy'
    return 0
  fi

  if [ "$p80_in_use" -eq 0 ] && [ "$p443_in_use" -eq 0 ]; then
    printf 'self'
    return 0
  fi

  if printf '%s %s' "$owner80" "$owner443" | grep -qi "caddy" && [ -f /etc/caddy/Caddyfile ]; then
    printf 'host_caddy'
    return 0
  fi

  printf 'conflict:%s' "${owner:-未知服务}"
}

# 检查域名是否已被其他项目占用（排除当前项目自身的标记块）
check_caddy_domain_conflict() {
  local cfg_file="$1"
  local project_id="$2"
  local domain
  domain="$(normalize_domain "$3")"
  [ -f "$cfg_file" ] || return 0

  local start_mark="# >>> vps-proxy:${project_id} >>>"
  local end_mark="# <<< vps-proxy:${project_id} <<<"
  local hit
  hit="$(awk -v s="$start_mark" -v e="$end_mark" -v d="$domain" '
    $0 == s { skip=1; next }
    $0 == e { skip=0; next }
    skip { next }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    index($0, "{") > 0 {
      hdr = tolower($0)
      sub(/\{.*/, "", hdr)
      gsub(/,/, " ", hdr)
      n = split(hdr, arr, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        sub(/:[0-9]+$/, "", arr[i])
        if (arr[i] == d) { print $0; exit }
      }
    }
  ' "$cfg_file")"

  if [ -n "$hit" ]; then
    log_err "域名 [${domain}] 已被其他站点或项目配置占用（${cfg_file}），请更换其他域名或子域名。"
    return 1
  fi
  return 0
}

# 按标记块移除 Caddyfile 中的指定项目配置（幂等）
strip_caddy_block() {
  local cfg_file="$1"
  local project_id="$2"
  [ -f "$cfg_file" ] || return 0
  local start_mark="# >>> vps-proxy:${project_id} >>>"
  local end_mark="# <<< vps-proxy:${project_id} <<<"
  local tmp_file="${cfg_file}.strip.$$"
  awk -v s="$start_mark" -v e="$end_mark" '
    $0 == s { skip=1; next }
    $0 == e { skip=0; next }
    !skip { print }
  ' "$cfg_file" > "$tmp_file" && mv "$tmp_file" "$cfg_file" || { rm -f "$tmp_file"; return 1; }
}

# 生成单个项目的 Caddy 站点配置块
build_caddy_site_block() {
  local project_id="$1"
  local domain="$2"
  local upstream="$3"
  local email="${4:-}"
  local now_ts
  now_ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '未知时间')"

  printf '\n# >>> vps-proxy:%s >>>\n' "$project_id"
  printf '# 由 apibox 自动维护（更新于 %s），请勿手动修改此标记块\n' "$now_ts"
  printf '%s {\n' "$domain"
  if [ -n "$email" ]; then
    printf '    tls %s\n' "$email"
  fi
  printf '    encode gzip\n'
  printf '    reverse_proxy %s {\n' "$upstream"
  printf '        flush_interval -1\n'
  printf '    }\n'
  printf '}\n'
  printf '# <<< vps-proxy:%s <<<\n' "$project_id"
}

# 初始化内置 Caddy 集中目录与 compose 文件（必须先落盘 Caddyfile 再起容器）
ensure_self_caddy_files() {
  local caddy_dir="$CADDY_DATA_DIR"
  local caddyfile="${caddy_dir}/Caddyfile"
  local compose_file="${caddy_dir}/docker-compose.yml"

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将初始化内置 Caddy 目录: ${caddy_dir}"
    return 0
  fi

  mkdir -p "${caddy_dir}/data" "${caddy_dir}/config"
  if [ ! -f "$caddyfile" ]; then
    cat > "$caddyfile" <<'EOF'
# ==============================================================================
# apibox 集中反向代理配置（由脚本自动维护）
# Let's Encrypt 证书自动申请并保存于 ./data 目录，到期前自动续期
# 注意：保留默认本地 Admin API (localhost:2019) 以支持零中断 caddy reload 热重载
# ==============================================================================
EOF
  fi

  cat > "$compose_file" <<EOF
services:
  caddy:
    image: caddy:2-alpine
    container_name: ${CADDY_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
    networks:
      - ${PROXY_NET_NAME}

networks:
  ${PROXY_NET_NAME}:
    external: true
EOF
}

# 校验并重载内置 Caddy 容器
reload_self_caddy() {
  local caddyfile="${CADDY_DATA_DIR}/Caddyfile"
  local compose_file="${CADDY_DATA_DIR}/docker-compose.yml"

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将校验 Caddyfile 并启动/重载 ${CADDY_CONTAINER_NAME}"
    return 0
  fi

  # 先用一次性容器校验语法，避免坏配置把线上容器搞挂
  if ! docker run --rm -v "${caddyfile}:/etc/caddy/Caddyfile:ro" caddy:2-alpine \
       caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    log_err "Caddyfile 语法校验失败，详情如下："
    docker run --rm -v "${caddyfile}:/etc/caddy/Caddyfile:ro" caddy:2-alpine \
      caddy validate --config /etc/caddy/Caddyfile 2>&1 || true
    return 1
  fi

  ensure_proxy_network "$PROXY_NET_NAME"
  open_firewall_port 80
  open_firewall_port 443

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CADDY_CONTAINER_NAME"; then
    docker exec "$CADDY_CONTAINER_NAME" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || \
      compose_cmd "$compose_file" up -d --force-recreate
  else
    compose_cmd "$compose_file" up -d
  fi
  log_ok "内置反向代理（Caddy）已启动并完成配置重载。"
}

# 打印 Nginx 手动反代片段与 Certbot 证书命令（当 80/443 被已有 Nginx 占用时使用）
print_manual_nginx_guide() {
  local domain="$1"
  local app_port="$2"
  printf "\n" >&2
  print_hr
  log_info "您可以将以下 Nginx 配置保存到 /etc/nginx/conf.d/${domain}.conf："
  cat >&2 <<EOF
server {
    listen 80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # 流式输出（SSE）防卡顿必需参数
        proxy_buffering off;
        proxy_read_timeout 300s;
    }
}
EOF
  printf '\n  然后执行以下命令自动申请 Let'\''s Encrypt 证书并重载 Nginx：\n' >&2
  printf '  %bnginx -t && systemctl reload nginx%b\n' "$C_GREEN" "$C_RESET" >&2
  printf '  %bcertbot --nginx -d %s%b\n' "$C_GREEN" "$domain" "$C_RESET" >&2
  print_hr
}

# 为项目配置域名与 Let's Encrypt 证书
# 用法：configure_domain_ssl "project_id" "domain" "upstream_container_port" "app_host_port" "email"
configure_domain_ssl() {
  local project_id="$1"
  local domain
  domain="$(normalize_domain "$2")"
  local upstream="$3"
  local app_host_port="$4"
  local email="${5:-}"

  local mode
  mode="$(detect_proxy_mode)"

  case "$mode" in
    self|self_caddy)
      ensure_self_caddy_files
      local caddyfile="${CADDY_DATA_DIR}/Caddyfile"
      if [ "$DRY_RUN" != "1" ]; then
        check_caddy_domain_conflict "$caddyfile" "$project_id" "$domain" || return 1
        cp "$caddyfile" "${caddyfile}.bak" 2>/dev/null || true
        strip_caddy_block "$caddyfile" "$project_id"
        build_caddy_site_block "$project_id" "$domain" "$upstream" "$email" >> "$caddyfile"
        if ! reload_self_caddy; then
          if [ -f "${caddyfile}.bak" ]; then
            cp "${caddyfile}.bak" "$caddyfile"
            rm -f "${caddyfile}.bak"
          fi
          return 1
        fi
        rm -f "${caddyfile}.bak"
      else
        log_info "[演练模式] 将写入 ${domain} -> ${upstream} 到 ${caddyfile}"
      fi
      verify_https_certificate "$domain"
      return 0
      ;;

    host_caddy)
      local host_cfg="/etc/caddy/Caddyfile"
      local bak_file="${host_cfg}.bak-$(date +%Y%m%d-%H%M%S)-${project_id}"
      log_info "检测到宿主机已运行 Caddy（配置文件: ${host_cfg}），将安全追加站点配置（自动备份并支持失败回滚）。"
      if [ "$DRY_RUN" = "1" ]; then
        log_info "[演练模式] 将备份 ${host_cfg} 并追加 ${domain} -> 127.0.0.1:${app_host_port}"
        return 0
      fi

      check_caddy_domain_conflict "$host_cfg" "$project_id" "$domain" || return 1

      trap _on_ssl_interrupt INT TERM
      cp "$host_cfg" "$bak_file"
      _CADDY_BAK_ACTIVE=1
      _CADDY_BAK_FILE="$bak_file"
      _CADDY_TARGET_CFG="$host_cfg"

      strip_caddy_block "$host_cfg" "$project_id"
      build_caddy_site_block "$project_id" "$domain" "127.0.0.1:${app_host_port}" "$email" >> "$host_cfg"

      if ! caddy validate --config "$host_cfg" >/dev/null 2>&1; then
        log_err "宿主机 Caddyfile 语法校验失败，错误详情如下："
        caddy validate --config "$host_cfg" 2>&1 | tail -8 | sed 's/^/    /' >&2 || true
        log_warn "正在自动回滚到原配置..."
        cp "$bak_file" "$host_cfg"
        _CADDY_BAK_ACTIVE=0
        if declare -F _on_global_interrupt >/dev/null 2>&1; then
          trap _on_global_interrupt INT TERM
        else
          trap - INT TERM
        fi
        return 1
      fi

      if ! caddy reload --config "$host_cfg" >/dev/null 2>&1; then
        log_err "宿主机 Caddy 重载失败，正在自动回滚到原配置..."
        cp "$bak_file" "$host_cfg"
        caddy reload --config "$host_cfg" >/dev/null 2>&1 || true
        _CADDY_BAK_ACTIVE=0
        if declare -F _on_global_interrupt >/dev/null 2>&1; then
          trap _on_global_interrupt INT TERM
        else
          trap - INT TERM
        fi
        return 1
      fi

      _CADDY_BAK_ACTIVE=0
      if declare -F _on_global_interrupt >/dev/null 2>&1; then
        trap _on_global_interrupt INT TERM
      else
        trap - INT TERM
      fi
      log_ok "已成功接入宿主机 Caddy。"
      verify_https_certificate "$domain"
      return 0
      ;;

    conflict:*)
      local owner="${mode#conflict:}"
      log_warn "检测到 80/443 端口已被宿主机其他服务占用（${owner}），无法自动接管证书申请。"
      print_manual_nginx_guide "$domain" "$app_host_port"
      return 2
      ;;
  esac
}

# 验证 Let's Encrypt 证书是否签发成功，失败时给出明确排查步骤
verify_https_certificate() {
  local domain="$1"
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 跳过在线 HTTPS 证书签发探测。"
    return 0
  fi

  log_info "正在自动向 Let's Encrypt 申请并验证 [${domain}] 的 HTTPS 证书（约需 5-15 秒）..."
  local i=0 code="000"
  while [ "$i" -lt 18 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "https://${domain}/" 2>/dev/null || echo '000')"
    if [ "$code" != "000" ]; then
      log_ok "HTTPS 证书签发成功！访问 https://${domain} 返回状态码: ${code}（证书将自动续期）"
      return 0
    fi
    sleep 3
    i=$((i + 3))
  done

  printf '\n' >&2
  log_warn "暂时未能通过 https://${domain} 完成 TLS 握手（可能证书仍在后台签发，或遇到网络/解析拦截）。"
  printf '  %b请按以下顺序快速排查：%b\n' "$C_BOLD" "$C_RESET" >&2
  printf '    1) 检查云厂商控制台安全组：确保 TCP 80 和 443 端口已对 0.0.0.0/0 放行；\n' >&2
  printf '    2) 检查域名解析：确认 %s 的 A 记录已指向本机公网 IP；\n' "$domain" >&2
  printf '    3) 若使用 Cloudflare 代理：请将 SSL/TLS 模式设为「完全（Full）」，勿选「灵活（Flexible）」；\n' >&2
  printf '    4) 同一域名每周向 Let'\''s Encrypt 申请证书有 5 次频率限制，超限需等待或换子域名。\n\n' >&2
  printf '  您可以复制以下命令查看证书申请实时日志：\n' >&2
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CADDY_CONTAINER_NAME"; then
    printf '  %bdocker logs --tail 50 %s%b\n' "$C_GREEN" "$CADDY_CONTAINER_NAME" "$C_RESET" >&2
  else
    printf '  %bjournalctl -u caddy -n 50 --no-pager%b\n' "$C_GREEN" "$C_RESET" >&2
  fi
  return 0
}

# 卸载时精准摘除指定项目的反代配置块
remove_domain_ssl() {
  local project_id="$1"
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将移除项目 ${project_id} 的反向代理配置块。"
    return 0
  fi

  local self_cfg="${CADDY_DATA_DIR}/Caddyfile"
  if [ -f "$self_cfg" ] && grep -q "# >>> vps-proxy:${project_id} >>>" "$self_cfg" 2>/dev/null; then
    strip_caddy_block "$self_cfg" "$project_id"
    if ! grep -q "# >>> vps-proxy:" "$self_cfg" 2>/dev/null; then
      # 已无任何托管站点，停止并回收闲置的内置 Caddy 容器以释放 80/443 端口
      if [ -f "${CADDY_DATA_DIR}/docker-compose.yml" ]; then
        compose_cmd "${CADDY_DATA_DIR}/docker-compose.yml" down >/dev/null 2>&1 || true
      elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CADDY_CONTAINER_NAME"; then
        docker rm -f "$CADDY_CONTAINER_NAME" >/dev/null 2>&1 || true
      fi
      log_ok "已清理 [${project_id}] 反代配置，并自动回收闲置的内置 Caddy 容器以释放 80/443 端口。"
    else
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CADDY_CONTAINER_NAME"; then
        docker exec "$CADDY_CONTAINER_NAME" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
      fi
      log_ok "已清理内置 Caddy 中 [${project_id}] 的域名反代配置。"
    fi
  fi

  local host_cfg="/etc/caddy/Caddyfile"
  if [ -f "$host_cfg" ] && grep -q "# >>> vps-proxy:${project_id} >>>" "$host_cfg" 2>/dev/null; then
    cp "$host_cfg" "${host_cfg}.bak-$(date +%Y%m%d-%H%M%S)-rm-${project_id}"
    strip_caddy_block "$host_cfg" "$project_id"
    caddy validate --config "$host_cfg" >/dev/null 2>&1 && caddy reload --config "$host_cfg" >/dev/null 2>&1 || true
    log_ok "已清理宿主机 Caddyfile 中 [${project_id}] 的域名反代配置。"
  fi
}

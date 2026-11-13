#!/usr/bin/env bash
# ==============================================================================
# 项目安装脚本：Sub2API（Wei-Shaw/sub2api）
# 按官方 deploy/docker-compose.yml 一起拉起应用、PostgreSQL 与 Redis。
# 密钥只在首次生成；重装与改端口都保留已有 .env，避免数据库密码对不上。
# ==============================================================================

PROJ_ID="sub2api"
PROJ_NAME="Sub2API"
PROJ_DESC="多账号 AI 接口聚合反代网关（支持 Claude / OpenAI / Gemini，含 PostgreSQL 与 Redis）"
PROJ_REPO="https://github.com/Wei-Shaw/sub2api"
PROJ_DEFAULT_IMAGE="weishaw/sub2api:latest"
PROJ_INNER_PORT="8080"
PROJ_DEFAULT_HOST_PORT="8080"
PROJ_CONTAINER_NAME="vps-proxy-sub2api"
PROJ_POSTGRES_CONTAINER="vps-proxy-sub2api-postgres"
PROJ_REDIS_CONTAINER="vps-proxy-sub2api-redis"
PROJ_POSTGRES_IMAGE="postgres:18-alpine"
PROJ_REDIS_IMAGE="redis:8-alpine"
# 首次要等 PostgreSQL 初始化并完成应用迁移，45 秒不够
PROJ_READY_TIMEOUT="180"

# 缺少的键才追加，已有行不动，从不覆盖已生成的密钥。
_sub2api_ensure_env_line() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    return 0
  fi
  printf '%s=%s\n' "$key" "$value" >> "$env_file"
}

# 把某个键改成新值；没有这一行就追加。其余行原样保留。
_sub2api_set_env_line() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local tmp_env="${env_file}.tmp.$$"
  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    awk -v k="$key" -v v="$value" '
      index($0, k "=") == 1 { print k "=" v; next }
      { print }
    ' "$env_file" > "$tmp_env" \
      && chmod 600 "$tmp_env" && mv "$tmp_env" "$env_file" || { rm -f "$tmp_env"; return 1; }
  else
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  fi
}

project_write_env() {
  local app_dir="$1"
  local host_port="$2"
  local env_file="${app_dir}/.env"

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将检查并生成环境变量文件: ${env_file}"
    return 0
  fi

  if [ -f "$env_file" ]; then
    log_info "检测到已有配置文件 ${env_file}，将保留原密钥并补齐官方必填项（幂等安全）。"
    _sub2api_set_env_line "$env_file" "SERVER_PORT" "$host_port" || return 1
    # 旧版脚本写的是 HOST_PORT，官方编排读 SERVER_PORT。两者保持一致，避免升级后端口对不上。
    if grep -q '^HOST_PORT=' "$env_file" 2>/dev/null; then
      _sub2api_set_env_line "$env_file" "HOST_PORT" "$host_port" || return 1
    fi
    _sub2api_ensure_env_line "$env_file" "AUTO_SETUP" "true"
    _sub2api_ensure_env_line "$env_file" "POSTGRES_USER" "sub2api"
    _sub2api_ensure_env_line "$env_file" "POSTGRES_DB" "sub2api"
    _sub2api_ensure_env_line "$env_file" "POSTGRES_PASSWORD" "$(gen_secret 24)"
    _sub2api_ensure_env_line "$env_file" "REDIS_PASSWORD" "$(gen_secret 24)"
    _sub2api_ensure_env_line "$env_file" "JWT_SECRET" "$(gen_secret 32)"
    _sub2api_ensure_env_line "$env_file" "TOTP_ENCRYPTION_KEY" "$(gen_secret 32)"
    _sub2api_ensure_env_line "$env_file" "ADMIN_EMAIL" "admin@localhost"
    _sub2api_ensure_env_line "$env_file" "ADMIN_PASSWORD" "$(gen_secret 8)"
    chmod 600 "$env_file"
    return 0
  fi

  local pg_pass redis_pass jwt_secret totp_key admin_pass admin_email
  pg_pass="$(gen_secret 24)"
  redis_pass="$(gen_secret 24)"
  jwt_secret="$(gen_secret 32)"
  totp_key="$(gen_secret 32)"
  admin_pass="$(gen_secret 8)"
  admin_email="${CLI_EMAIL:-${SAVED_EMAIL:-}}"
  if [ -z "$admin_email" ] || ! is_valid_email "$admin_email"; then
    admin_email="admin@localhost"
  fi

  cat > "$env_file" <<EOF
# Sub2API 环境变量（由 apibox 按官方部署自动生成，请勿把本文件提交到仓库）
TZ=Asia/Shanghai
SERVER_PORT=${host_port}
AUTO_SETUP=true
POSTGRES_USER=sub2api
POSTGRES_PASSWORD=${pg_pass}
POSTGRES_DB=sub2api
REDIS_PASSWORD=${redis_pass}
JWT_SECRET=${jwt_secret}
TOTP_ENCRYPTION_KEY=${totp_key}
ADMIN_EMAIL=${admin_email}
ADMIN_PASSWORD=${admin_pass}
EOF
  chmod 600 "$env_file"
  log_ok "已生成数据库、缓存与登录密钥并保存到 ${env_file}（权限 600）。"
}

project_write_compose() {
  local app_dir="$1"
  local host_port="$2"
  local image="$3"
  local compose_file="${app_dir}/docker-compose.yml"

  if [ "$DRY_RUN" = "1" ]; then
    log_info "[演练模式] 将生成 ${compose_file}（应用 ${image}，端口 ${host_port}:${PROJ_INNER_PORT}，另含 PostgreSQL 与 Redis）"
    return 0
  fi

  mkdir -p "${app_dir}/data" "${app_dir}/postgres" "${app_dir}/redis"
  # 官方镜像里 postgres 与 redis 都不以 root 跑，挂载目录要先给它们写权限
  chown 70:70 "${app_dir}/postgres" 2>/dev/null || true
  chown 999:999 "${app_dir}/redis" 2>/dev/null || true

  # 定界符加引号，脚本不展开 ${}。端口和镜像名用占位符，写完再替换。
  # 密钥留在文件里，由 docker compose 启动时从同目录 .env 读入。
  cat > "$compose_file" <<'EOF'
services:
  sub2api:
    image: __APIBOX_IMAGE__
    container_name: __APIBOX_APP_CONTAINER__
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "__APIBOX_HOST_PORT__:8080"
    volumes:
      - ./data:/app/data
    environment:
      AUTO_SETUP: "true"
      SERVER_HOST: 0.0.0.0
      SERVER_PORT: "8080"
      SERVER_MODE: release
      TZ: Asia/Shanghai
      DATABASE_HOST: postgres
      DATABASE_PORT: "5432"
      DATABASE_USER: sub2api
      DATABASE_PASSWORD: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
      DATABASE_DBNAME: sub2api
      DATABASE_SSLMODE: disable
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_PASSWORD: "${REDIS_PASSWORD:-}"
      REDIS_DB: "0"
      ADMIN_EMAIL: "${ADMIN_EMAIL:-admin@localhost}"
      ADMIN_PASSWORD: "${ADMIN_PASSWORD:-}"
      JWT_SECRET: "${JWT_SECRET:-}"
      TOTP_ENCRYPTION_KEY: "${TOTP_ENCRYPTION_KEY:-}"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - default
      - __APIBOX_PROXY_NET__

  postgres:
    image: __APIBOX_POSTGRES_IMAGE__
    container_name: __APIBOX_POSTGRES_CONTAINER__
    restart: unless-stopped
    environment:
      PGDATA: /var/lib/postgresql/data
      POSTGRES_USER: sub2api
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
      POSTGRES_DB: sub2api
      TZ: Asia/Shanghai
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sub2api -d sub2api"]
      interval: 10s
      timeout: 5s
      retries: 18
      start_period: 40s
    networks:
      - default

  redis:
    image: __APIBOX_REDIS_IMAGE__
    container_name: __APIBOX_REDIS_CONTAINER__
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"]
    volumes:
      - ./redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD:?REDIS_PASSWORD is required}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s
    networks:
      - default

networks:
  __APIBOX_PROXY_NET__:
    external: true
EOF

  local tmp_compose="${compose_file}.tmp.$$"
  awk \
    -v image="$image" \
    -v app_container="$PROJ_CONTAINER_NAME" \
    -v host_port="$host_port" \
    -v proxy_net="$PROXY_NET_NAME" \
    -v pg_image="$PROJ_POSTGRES_IMAGE" \
    -v pg_container="$PROJ_POSTGRES_CONTAINER" \
    -v redis_image="$PROJ_REDIS_IMAGE" \
    -v redis_container="$PROJ_REDIS_CONTAINER" '
    {
      gsub(/__APIBOX_IMAGE__/, image)
      gsub(/__APIBOX_APP_CONTAINER__/, app_container)
      gsub(/__APIBOX_HOST_PORT__/, host_port)
      gsub(/__APIBOX_PROXY_NET__/, proxy_net)
      gsub(/__APIBOX_POSTGRES_IMAGE__/, pg_image)
      gsub(/__APIBOX_POSTGRES_CONTAINER__/, pg_container)
      gsub(/__APIBOX_REDIS_IMAGE__/, redis_image)
      gsub(/__APIBOX_REDIS_CONTAINER__/, redis_container)
      print
    }
  ' "$compose_file" > "$tmp_compose" \
    && mv "$tmp_compose" "$compose_file" || { rm -f "$tmp_compose"; return 1; }
}

project_post_install_tips() {
  local app_dir="$1"
  printf '  %b配置文件目录%b : %s\n' "$C_BOLD" "$C_RESET" "$app_dir" >&2
  printf '  %b登录账号%b     : 见 %b%s/.env%b 里的 ADMIN_EMAIL 与 ADMIN_PASSWORD\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$app_dir" "$C_RESET" >&2
  printf '  %b数据保存%b     : PostgreSQL 在 %s/postgres，Redis 在 %s/redis（均不对外开放端口）\n' "$C_BOLD" "$C_RESET" "$app_dir" "$app_dir" >&2
}

project_install()   { base_project_install "$@"; }
project_status()    { base_project_status "$@"; }
project_logs()      { base_project_logs "$@"; }
project_restart()   { base_project_restart "$@"; }
project_upgrade()   { base_project_upgrade "$@"; }
project_uninstall() { base_project_uninstall "$@"; }

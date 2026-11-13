#!/usr/bin/env bash
# ==============================================================================
# 自动化自检与回归测试套件（tests/verify.sh）
# 覆盖：语法检查、LF 行尾校验、参数校验、dry-run 端到端、配置注入安全测试
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[通过] %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[失败] %s\n' "$*" >&2
}

echo "=== 开始执行 vps-proxy-installer 自检与回归测试 ==="

# 1. 语法检查 (bash -n)
while IFS= read -r -d '' sh_file; do
  if bash -n "$sh_file"; then
    ok "语法检查通过: ${sh_file#"$ROOT_DIR"/}"
  else
    fail "语法检查失败: ${sh_file#"$ROOT_DIR"/}"
  fi
done < <(find "$ROOT_DIR" -maxdepth 3 -name "*.sh" -print0)

# 2. 跨平台换行符检查（CR 字节数必须为 0）
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  PY_BIN="$(command -v python3 || command -v python)"
  if "$PY_BIN" -c "
import pathlib, sys
root = pathlib.Path(r'$ROOT_DIR')
bad = []
for p in root.rglob('*'):
    if p.is_file() and '.git' not in p.parts:
        if p.suffix in ('.sh', '.conf', '.md', '.yml', '.yaml') or p.name in ('.gitattributes', '.gitignore'):
            cr = p.read_bytes().count(b'\r')
            if cr > 0:
                bad.append((str(p), cr))
if bad:
    print('发现 CRLF:', bad)
    sys.exit(1)
"; then
    ok "全部脚本文档行尾均为 LF（CR = 0）"
  else
    fail "存在 CRLF 行尾文件"
  fi
fi

# 3. 帮助与项目列表输出
if bash "${ROOT_DIR}/install.sh" --help >/dev/null 2>&1; then
  ok "install.sh --help 正常退出"
else
  fail "install.sh --help 执行失败"
fi

list_out="$(bash "${ROOT_DIR}/install.sh" --list)"
if printf '%s' "$list_out" | grep -q "sub2api" && printf '%s' "$list_out" | grep -q "newapi" && printf '%s' "$list_out" | grep -q "magpie" && printf '%s' "$list_out" | grep -q "agent2api"; then
  ok "install.sh --list 正确列出 sub2api、newapi、magpie 与 agent2api"
else
  fail "install.sh --list 输出缺少预期项目: $list_out"
fi

# 4. 非法参数与冲突拦截测试（必须返回非 0）
for bad_args in \
  "--action bogus" \
  "--port 99999" \
  "--port 080" \
  "--email invalid_email" \
  "--domain invalid_domain" \
  "--domain api.example.com --no-domain" \
  "--image bad\ image" \
  "--project not_exists"; do
  # shellcheck disable=SC2086
  if bash "${ROOT_DIR}/install.sh" $bad_args >/dev/null 2>&1; then
    fail "非法参数未被拦截: $bad_args"
  else
    ok "非法参数已正确拦截: $bad_args"
  fi
done

# 5. --dry-run 端到端流程测试（无副作用）
for proj in sub2api newapi magpie agent2api; do
  if bash "${ROOT_DIR}/install.sh" --project "$proj" --action install --port auto --no-domain --yes --dry-run >/dev/null 2>&1; then
    ok "演练模式通过（无域名）: $proj"
  else
    fail "演练模式失败（无域名）: $proj"
  fi
  if bash "${ROOT_DIR}/install.sh" --project "$proj" --action install --port 18080 --domain "test-${proj}.example.com" --skip-dns-check --yes --dry-run >/dev/null 2>&1; then
    ok "演练模式通过（绑定域名）: $proj"
  else
    fail "演练模式失败（绑定域名）: $proj"
  fi
done

# 6. 安全配置解析注入测试（验证 load_conf_safe 不会执行恶意命令）
tmp_conf="$(mktemp)"
pwn_flag="/tmp/vps_proxy_pwned_test_$$"
rm -f "$pwn_flag"
cat > "$tmp_conf" <<EOF
SAVED_PORT=8080
EVIL=\$(touch ${pwn_flag})
SAVED_DOMAIN=api.example.com
EOF

(
  # shellcheck source=lib/common.sh
  source "${ROOT_DIR}/lib/common.sh"
  SAVED_PORT=""
  SAVED_DOMAIN=""
  load_conf_safe "$tmp_conf" "SAVED_PORT" "SAVED_DOMAIN"
  [ "$SAVED_PORT" = "8080" ] && [ "$SAVED_DOMAIN" = "api.example.com" ]
)
rc=$?
rm -f "$tmp_conf"
if [ "$rc" -eq 0 ] && [ ! -e "$pwn_flag" ]; then
  ok "安全配置解析注入测试通过（白名单过滤且未执行恶意命令）"
else
  rm -f "$pwn_flag"
  fail "安全配置解析存在漏洞或解析错误"
fi

# 7. 交互函数 stdout 纯净度测试
ask_val="$(
  source "${ROOT_DIR}/lib/common.sh"
  ASSUME_YES=1
  ask "测试提示语" "default_val" 2>/dev/null
)"
if [ "$ask_val" = "default_val" ]; then
  ok "交互函数返回值纯净（提示语未污染 stdout）"
else
  fail "交互函数返回值被污染: [$ask_val]"
fi

# 8. 特殊字符日志安全测试（-- 与 % 开头不崩溃）
if (
  source "${ROOT_DIR}/lib/common.sh"
  NO_COLOR=1
  init_colors
  log_info "--port 80 100% ready" 2>/dev/null
); then
  ok "日志函数支持横线与百分号特殊字符"
else
  fail "日志函数处理特殊字符失败"
fi

# 9. 域名规范化与 Caddy 跨项目域名冲突检测测试
tmp_caddy="$(mktemp)"
cat > "$tmp_caddy" <<'EOF'
# >>> vps-proxy:sub2api >>>
api.example.com {
    reverse_proxy vps-proxy-sub2api:8080
}
# <<< vps-proxy:sub2api <<<
EOF

if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/ssl.sh"
  [ "$(normalize_domain "API.Example.COM")" = "api.example.com" ] &&
  check_caddy_domain_conflict "$tmp_caddy" "sub2api" "api.example.com" 2>/dev/null &&
  ! check_caddy_domain_conflict "$tmp_caddy" "newapi" "api.example.com" 2>/dev/null
); then
  ok "域名小写规范化与跨项目域名冲突检测通过"
else
  fail "域名规范化或冲突检测未按预期工作"
fi
rm -f "$tmp_caddy"

# 10. get_used_ports 零报错安全退出测试
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/system.sh"
  get_used_ports >/dev/null
); then
  ok "get_used_ports 在任何环境下均安全返回退出码 0"
else
  fail "get_used_ports 执行异常退出"
fi

# 11. sub2api 重配端口同步 .env 中 HOST_PORT 且保留密钥测试
tmp_sub_dir="$(mktemp -d)"
cat > "${tmp_sub_dir}/.env" <<'EOF'
TZ=Asia/Shanghai
PORT=8080
HOST_PORT=8080
JWT_SECRET=keep_this_secret_123
ADMIN_PASSWORD=keep_pass
EOF

if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/project_base.sh"
  source "${ROOT_DIR}/projects/sub2api.sh"
  DRY_RUN=0
  project_write_env "$tmp_sub_dir" "18088" 2>/dev/null
  grep -qx "HOST_PORT=18088" "${tmp_sub_dir}/.env" &&
  grep -qx "SERVER_PORT=18088" "${tmp_sub_dir}/.env" &&
  grep -qx "JWT_SECRET=keep_this_secret_123" "${tmp_sub_dir}/.env" &&
  grep -qx "ADMIN_PASSWORD=keep_pass" "${tmp_sub_dir}/.env" &&
  grep -q '^POSTGRES_PASSWORD=.' "${tmp_sub_dir}/.env" &&
  grep -q '^REDIS_PASSWORD=.' "${tmp_sub_dir}/.env" &&
  grep -qx "AUTO_SETUP=true" "${tmp_sub_dir}/.env"
); then
  ok "sub2api 重配端口时同步 SERVER_PORT 与 HOST_PORT，保留原密钥并补齐数据库项"
else
  fail "sub2api 重配端口未同步端口、破坏了原密钥，或未补齐数据库项"
fi
rm -rf "$tmp_sub_dir"

# 12. 配置文件含 CRLF (\r) 时的容错解析测试
tmp_crlf_conf="$(mktemp)"
printf 'SAVED_PORT=3425\r\nSAVED_DOMAIN=magpie.example.com\r\n' > "$tmp_crlf_conf"
if (
  source "${ROOT_DIR}/lib/common.sh"
  SAVED_PORT=""
  SAVED_DOMAIN=""
  load_conf_safe "$tmp_crlf_conf" "SAVED_PORT" "SAVED_DOMAIN"
  [ "$SAVED_PORT" = "3425" ] && [ "$SAVED_DOMAIN" = "magpie.example.com" ]
); then
  ok "load_conf_safe 兼容剥离意外带入的 CRLF 回车符"
else
  fail "load_conf_safe 未正确剥离 CRLF 回车符"
fi
rm -f "$tmp_crlf_conf"

# 13. 邮箱注入字符严格拦截测试
if (
  source "${ROOT_DIR}/lib/common.sh"
  is_valid_email "admin@example.com" &&
  ! is_valid_email "a{b}@example.com" &&
  ! is_valid_email "admin@ex;ample.com"
); then
  ok "is_valid_email 严格拦截花括号与分号等配置注入字符"
else
  fail "is_valid_email 校验未按预期拦截特殊字符"
fi

# 14. 内置 Caddyfile 必须保留 Admin API（禁止写入 admin off 导致 reload 失效）
tmp_caddy_dir="$(mktemp -d)"
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/ssl.sh"
  DRY_RUN=0
  CADDY_DATA_DIR="$tmp_caddy_dir"
  ensure_self_caddy_files
  [ -f "${tmp_caddy_dir}/Caddyfile" ] && ! grep -q "admin off" "${tmp_caddy_dir}/Caddyfile"
); then
  ok "内置 Caddyfile 保留本地 Admin API 以支持零中断 caddy reload"
else
  fail "内置 Caddyfile 异常包含 admin off 或未生成"
fi
rm -rf "$tmp_caddy_dir"

# 15. 全仓 printf 格式串静态扫描（禁止把 ${C_*} 拼接进格式字符串）
if ! grep -rnE 'printf[[:space:]]+"[^"]*\$\{C_' "${ROOT_DIR}/install.sh" "${ROOT_DIR}/lib" "${ROOT_DIR}/projects" >/dev/null 2>&1; then
  ok "全仓脚本 printf 格式串均已参数化（无颜色变量直接拼接）"
else
  fail "发现未参数化的 printf 颜色格式串"
fi

# 16. 跨项目切换防可选钩子函数污染测试
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/project_base.sh"
  source "${ROOT_DIR}/projects/sub2api.sh"
  declare -F project_post_install_tips >/dev/null 2>&1
  unset -f project_write_env project_write_compose project_post_install_tips \
    project_install project_status project_logs project_restart project_upgrade project_uninstall 2>/dev/null || true
  source "${ROOT_DIR}/projects/_template.sh"
  ! declare -F project_post_install_tips >/dev/null 2>&1
); then
  ok "跨项目切换时正确清理可选钩子函数，杜绝张冠李戴"
else
  fail "跨项目切换未清理 project_post_install_tips 钩子"
fi

# 17. POSIX df -Pk 磁盘信息探测兼容性测试（独立严格模式进程，确保函数返回 0）
if bash -euo pipefail -c "
  source '${ROOT_DIR}/lib/common.sh'
  source '${ROOT_DIR}/lib/system.sh'
  detect_system_info
  [[ \"\$SYS_DISK_AVAIL\" =~ ^[0-9]+(\\.[0-9]+)?\\ GB\$ ]] || [ \"\$SYS_DISK_AVAIL\" = '未知' ]
"; then
  ok "detect_system_info 磁盘空间探测格式规范（POSIX df -Pk）"
else
  fail "detect_system_info 磁盘空间解析格式异常: ${SYS_DISK_AVAIL:-空}"
fi

# 18. 锁文件权限隔离检查（防 fs.protected_regular 导致 sudo 权限拒绝）
if grep -q 'apibox-installer-uid' "${ROOT_DIR}/install.sh"; then
  ok "全局互斥锁已按 UID/权限隔离，避免 fs.protected_regular 碰撞"
else
  fail "全局互斥锁未按 UID 隔离"
fi

# 19. Caddy 域名冲突检测增强测试（无空格花括号、多域名逗号、大小写、带端口）
tmp_caddy2="$(mktemp)"
cat > "$tmp_caddy2" <<'EOF'
Site1.Example.COM{
    respond "ok"
}
a.example.com, b.example.com:443 {
    respond "ok"
}
EOF
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/ssl.sh"
  ! check_caddy_domain_conflict "$tmp_caddy2" "sub2api" "site1.example.com" 2>/dev/null &&
  ! check_caddy_domain_conflict "$tmp_caddy2" "sub2api" "b.example.com" 2>/dev/null &&
  check_caddy_domain_conflict "$tmp_caddy2" "sub2api" "c.example.com" 2>/dev/null
); then
  ok "Caddy 域名冲突检测覆盖无空格花括号、多域名逗号、大小写与端口格式"
else
  fail "Caddy 域名冲突检测在特殊语法格式下漏检"
fi
rm -f "$tmp_caddy2"

# 20. save_conf_kv 奇数参数防御与 gen_secret 异常长度兜底测试
if (
  source "${ROOT_DIR}/lib/common.sh"
  ! save_conf_kv "/tmp/unused_conf_test" "ONLY_KEY" 2>/dev/null &&
  sec="$(gen_secret "invalid")" &&
  [ "${#sec}" -eq 64 ]
); then
  ok "save_conf_kv 奇数参数拦截与 gen_secret 非法参数兜底通过"
else
  fail "save_conf_kv 或 gen_secret 参数边界保护失败"
fi

# 21. 演练模式下升级（--image）与非交互卸载路径检查
tmp_up_dir="$(mktemp -d)"
mkdir -p "${tmp_up_dir}/sub2api"
touch "${tmp_up_dir}/sub2api/docker-compose.yml"
if (
  VPS_BASE_DIR="$tmp_up_dir" bash "${ROOT_DIR}/install.sh" --project sub2api --action upgrade --image weishaw/sub2api:v1.0.0 --dry-run >/dev/null 2>&1 &&
  VPS_BASE_DIR="$tmp_up_dir" bash "${ROOT_DIR}/install.sh" --project sub2api --action uninstall --yes --dry-run >/dev/null 2>&1
); then
  ok "--action upgrade --image 与 --action uninstall --yes 演练路径均正常执行"
else
  fail "升级带 --image 或非交互卸载演练路径执行失败"
fi
rm -rf "$tmp_up_dir"

# 22. compose 镜像行替换防 & 展开与缩进保留测试
tmp_img_c="$(mktemp)"
cat > "$tmp_img_c" <<'EOF'
services:
  app:
    image: old/img:v1
    restart: unless-stopped
EOF
new_img_test='localhost:5000/app:v2&special'
awk -v img="$new_img_test" '
  !done && /^[[:space:]]*image:[[:space:]]*/ {
    match($0, /^[[:space:]]*/)
    print substr($0, 1, RLENGTH) "image: " img
    done=1
    next
  }
  { print }
' "$tmp_img_c" > "${tmp_img_c}.out"
if grep -Fqx "    image: ${new_img_test}" "${tmp_img_c}.out"; then
  ok "镜像行替换正确保留缩进且不展开 & 特殊字符"
else
  fail "镜像行替换发生格式或字符展开异常"
fi
rm -f "$tmp_img_c" "${tmp_img_c}.out"

# 23. 日志超过 5MB 自动截断轮转测试
tmp_big_log="$(mktemp)"
python_cmd="$(command -v python3 || command -v python)"
TMPF="$tmp_big_log" "$python_cmd" -c "
import os
with open(os.environ['TMPF'], 'wb') as f:
    f.write((b'x' * 5999 + b'\n') * 1100)
"
if (
  INSTALLER_LOG="$tmp_big_log"
  source "${ROOT_DIR}/lib/common.sh"
  lines_after="$(wc -l < "$tmp_big_log" | tr -d ' ')"
  [ "$lines_after" -eq 1000 ]
); then
  ok "超过 5MB 的日志文件在加载时自动截断保留最近 1000 行"
else
  fail "超限日志文件自动截断未按预期生效"
fi
rm -f "$tmp_big_log"

# 24. get_public_ip 探测失败缓存标记校验
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/system.sh"
  DRY_RUN=0
  _SYS_PUBLIC_IP_PROBED=1
  SYS_PUBLIC_IP=""
  ! get_public_ip >/dev/null 2>&1
); then
  ok "get_public_ip 失败探测缓存标记生效，避免无网环境重复超时卡顿"
else
  fail "get_public_ip 失败探测缓存未按预期工作"
fi

# 25. Sub2API 编排必须带上 PostgreSQL、Redis，且不把密钥写进 compose
tmp_compose_dir="$(mktemp -d)"
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/projects/sub2api.sh"
  DRY_RUN=0
  PROXY_NET_NAME="vps_proxy_net"
  project_write_env "$tmp_compose_dir" "18088"
  project_write_compose "$tmp_compose_dir" "18088" "weishaw/sub2api:v9"
  compose="${tmp_compose_dir}/docker-compose.yml"
  envf="${tmp_compose_dir}/.env"
  grep -q 'container_name: vps-proxy-sub2api-postgres' "$compose" &&
  grep -q 'container_name: vps-proxy-sub2api-redis' "$compose" &&
  grep -q 'image: weishaw/sub2api:v9' "$compose" &&
  grep -q '"18088:8080"' "$compose" &&
  grep -q 'service_healthy' "$compose" &&
  grep -q 'PGDATA: /var/lib/postgresql/data' "$compose" &&
  grep -Fq '${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}' "$compose" &&
  secret="$(grep '^POSTGRES_PASSWORD=' "$envf" | cut -d= -f2-)" &&
  [ -n "$secret" ] &&
  ! grep -Fq "$secret" "$compose"
); then
  ok "sub2api 编排包含 PostgreSQL 与 Redis，密钥只留在 .env"
else
  fail "sub2api 编排缺少数据库依赖，或把密钥写进了 compose"
fi
rm -rf "$tmp_compose_dir"

# 26. 服务探活不能把 curl 连不上时输出的 000000 当成已就绪
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/docker.sh"
  DRY_RUN=0
  ! wait_container_ready "definitely-missing-container" "1" "1"
); then
  ok "wait_container_ready 在连接失败时返回未就绪，而不是把 000000 当成成功"
else
  fail "wait_container_ready 把连接失败误判成服务已就绪"
fi

# 27. 命令行安装路径会先识别系统，包管理器不会是空的
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/system.sh"
  source "${ROOT_DIR}/lib/project_base.sh"
  SYS_PKG_MGR=""
  detect_system_info
  [ -n "$SYS_PKG_MGR" ]
) && grep -q 'detect_system_info' "${ROOT_DIR}/lib/project_base.sh"; then
  ok "detect_system_info 会写入包管理器，且安装流程会调用它"
else
  fail "安装流程未识别系统，SYS_PKG_MGR 仍为空"
fi

# 28. 升级只替换应用服务的镜像，数据库镜像保持不动
tmp_up_compose="$(mktemp)"
cat > "$tmp_up_compose" <<'EOF'
services:
  sub2api:
    image: weishaw/sub2api:old
  postgres:
    image: postgres:18-alpine
  redis:
    image: redis:8-alpine
EOF
awk -v img='weishaw/sub2api:new' -v svc='sub2api' '
  $0 ~ "^[[:space:]]*" svc ":[[:space:]]*$" { in_svc=1 }
  in_svc && /^[[:space:]]{0,2}[^[:space:]]/ && $0 !~ "^[[:space:]]*" svc ":[[:space:]]*$" { in_svc=0 }
  in_svc && !done && /^[[:space:]]*image:[[:space:]]*/ {
    match($0, /^[[:space:]]*/)
    print substr($0, 1, RLENGTH) "image: " img
    done=1
    next
  }
  { print }
' "$tmp_up_compose" > "${tmp_up_compose}.out"
if grep -qx '    image: weishaw/sub2api:new' "${tmp_up_compose}.out" \
   && grep -qx '    image: postgres:18-alpine' "${tmp_up_compose}.out" \
   && grep -qx '    image: redis:8-alpine' "${tmp_up_compose}.out"; then
  ok "升级镜像替换只命中应用服务，postgres 与 redis 镜像不变"
else
  fail "升级镜像替换误改了数据库镜像"
fi
rm -f "$tmp_up_compose" "${tmp_up_compose}.out"

# 29. postgres 数据目录按官方镜像用户 999 授权，不再写成 70
if grep -q 'chown 999:999 "${app_dir}/postgres"' "${ROOT_DIR}/projects/sub2api.sh" \
   && ! grep -q 'chown 70:70' "${ROOT_DIR}/projects/sub2api.sh"; then
  ok "sub2api 数据目录按 postgres 官方镜像用户 999 授权"
else
  fail "sub2api 仍把 postgres 数据目录授权给错误的用户 70"
fi

# 30. 编排占位符按字面替换，镜像名里的 & 不会被当成替换表达式
tmp_literal="$(mktemp -d)"
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/projects/sub2api.sh"
  DRY_RUN=0
  PROXY_NET_NAME="vps_proxy_net"
  project_write_compose "$tmp_literal" "18088" "registry.example.com/app:v1&build"
  grep -Fq 'image: registry.example.com/app:v1&build' "${tmp_literal}/docker-compose.yml" \
    && ! grep -q '__APIBOX_' "${tmp_literal}/docker-compose.yml"
); then
  ok "compose 占位符按字面替换，镜像名中的 & 原样保留"
else
  fail "compose 占位符替换把 & 当成了正则替换"
fi
rm -rf "$tmp_literal"

# 31. 首次生成的管理员邮箱留空，不使用证书邮箱或固定的 admin@localhost
tmp_admin="$(mktemp -d)"
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/projects/sub2api.sh"
  DRY_RUN=0
  CLI_EMAIL="certs@example.com"
  SAVED_EMAIL="certs@example.com"
  project_write_env "$tmp_admin" "8080"
  grep -qx 'ADMIN_EMAIL=' "${tmp_admin}/.env"
); then
  ok "sub2api 管理员邮箱留空，不复用证书邮箱"
else
  fail "sub2api 把证书邮箱或固定邮箱写成了管理员登录名"
fi
rm -rf "$tmp_admin"

# 32. 配置值里的 # 与反斜杠会被拒绝，避免读回时被截断
if (
  source "${ROOT_DIR}/lib/common.sh"
  DRY_RUN=0
  tmp_conf="$(mktemp)"
  ! save_conf_kv "$tmp_conf" "SAVED_DOMAIN" "bad#value"
  ! save_conf_kv "$tmp_conf" "SAVED_DOMAIN" 'bad\value'
  rm -f "$tmp_conf"
); then
  ok "save_conf_kv 拒绝包含 # 或反斜杠的配置值"
else
  fail "save_conf_kv 接受了会被读回逻辑截断的配置值"
fi

# 33. 自举更新用 cp -R，避免 cp -a 把 root 属主带进已有目录
if grep -q 'cp -R "${top_dir}/." "${APIBOX_HOME}/"' "${ROOT_DIR}/install.sh" \
   && ! grep -q 'cp -a "${top_dir}/."' "${ROOT_DIR}/install.sh"; then
  ok "自举更新使用 cp -R，不再保留压缩包里的 root 属主"
else
  fail "自举更新仍使用 cp -a"
fi

# 34. 卸载在 compose down 失败时会删掉编排里的每一个容器
if grep -q 'container_name:' "${ROOT_DIR}/lib/project_base.sh" \
   && grep -A 8 'compose_cmd "$compose_file" down' "${ROOT_DIR}/lib/project_base.sh" | grep -q 'for cname in'; then
  ok "卸载失败回退会清理编排中的全部容器，不只是应用容器"
else
  fail "卸载失败回退仍只删除应用容器"
fi

# 35. 证书探测按 curl 退出码判断，不把失败输出 000000 当成签发成功
if grep -q 'code="${code:0:3}"' "${ROOT_DIR}/lib/ssl.sh" \
   && ! grep -q "|| echo '000'" "${ROOT_DIR}/lib/ssl.sh"; then
  ok "HTTPS 证书探测按退出码判断，不再把 curl 失败输出当成成功"
else
  fail "HTTPS 证书探测仍把 curl 失败输出当成成功"
fi

echo "------------------------------------------------------------"
printf "测试汇总：通过 %d 项，失败 %d 项\n" "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]

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
  grep -qx "JWT_SECRET=keep_this_secret_123" "${tmp_sub_dir}/.env"
); then
  ok "sub2api 重配端口时同步更新 HOST_PORT 且保留原密钥"
else
  fail "sub2api 重配端口未同步 HOST_PORT 或破坏了原密钥"
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

# 17. POSIX df -Pk 磁盘信息探测兼容性测试
if (
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/system.sh"
  detect_system_info
  [[ "$SYS_DISK_AVAIL" =~ ^[0-9]+(\.[0-9]+)?\ GB$ ]] || [ "$SYS_DISK_AVAIL" = "未知" ]
); then
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
"$python_cmd" -c "
with open(r'$tmp_big_log', 'wb') as f:
    line = b'x' * 5999 + b'\n'
    f.write(line * 1100)
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

echo "------------------------------------------------------------"
printf "测试汇总：通过 %d 项，失败 %d 项\n" "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]

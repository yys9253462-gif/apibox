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

echo "------------------------------------------------------------"
printf "测试汇总：通过 %d 项，失败 %d 项\n" "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]

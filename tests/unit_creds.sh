#!/usr/bin/env bash
# tests/unit_creds.sh —— 凭据持久化单元测试（使用临时配置目录）。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/creds.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# 隔离到临时目录。
BUPTY_CONFIG_DIR="$(mktemp -d)/bupty"
BUPTY_CACHE_DIR="${BUPTY_CONFIG_DIR}/cache"
BUPTY_CREDENTIALS_FILE="${BUPTY_CONFIG_DIR}/credentials.json"
BUPTY_SETTINGS_FILE="${BUPTY_CONFIG_DIR}/settings.json"
BUPTY_FAVORITES_FILE="${BUPTY_CONFIG_DIR}/favorite-events.json"

t_begin "凭据保存/加载"
assert_ok creds_save "2025211681" "secret-pass" ""
assert_ok creds_load
assert_eq "${BUPTY_ACCOUNT}" "2025211681" "账号"
assert_eq "${BUPTY_PASSWORD}" "secret-pass" "密码"

t_begin "教学云密码回退"
assert_ok creds_save "2025211681" "acad-pass" "cloud-pass"
assert_eq "$(creds_assignment_password)" "cloud-pass" "有独立密码用独立密码"
assert_ok creds_save "2025211681" "acad-pass" ""
assert_eq "$(creds_assignment_password)" "acad-pass" "无独立密码回退教务密码"

t_begin "凭据文件权限 0600"
assert_ok creds_save "2025211681" "p" ""
perm="$(stat -c '%a' "${BUPTY_CREDENTIALS_FILE}" 2>/dev/null)"
assert_eq "${perm}" "600" "文件权限应为 600"

t_begin "登出清除凭据"
assert_ok creds_clear
assert_fail creds_load
assert_eq "${BUPTY_ACCOUNT}" "" "登出后账号为空"

t_begin "拒绝符号链接凭据"
assert_ok creds_save "2025211681" "p" ""
# 将真实文件移走，替换为符号链接。
mv "${BUPTY_CREDENTIALS_FILE}" "${BUPTY_CREDENTIALS_FILE}.real"
ln -s "${BUPTY_CREDENTIALS_FILE}.real" "${BUPTY_CREDENTIALS_FILE}"
assert_fail creds_load
rm -f "${BUPTY_CREDENTIALS_FILE}" "${BUPTY_CREDENTIALS_FILE}.real"

t_summary

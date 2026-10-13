#!/usr/bin/env bash
# tests/unit_creds_memo.sh —— 凭据加载缓存（memoization）单元测试（使用临时配置目录）。
# 覆盖：首次读盘后缓存命中（改文件不重读）、creds_save/creds_clear 使缓存失效、
# 缓存路径仍拒绝符号链接。
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
mkdir -p "${BUPTY_CONFIG_DIR}"

# 直接写盘一份凭据，模拟「首次真实读盘」（重置缓存标志后加载）。
printf '%s\n' '{"account":"2025211681","password":"secret-pass"}' > "${BUPTY_CREDENTIALS_FILE}"
chmod 600 "${BUPTY_CREDENTIALS_FILE}"
_CREDS_LOADED=0

t_begin "首次读盘"
assert_ok creds_load
assert_eq "${BUPTY_ACCOUNT}" "2025211681" "账号读入"
assert_eq "${BUPTY_PASSWORD}" "secret-pass" "密码读入"

# 覆盖文件为不同内容：缓存命中，不应重新读盘。
printf '%s\n' '{"account":"9999999999","password":"other-pass"}' > "${BUPTY_CREDENTIALS_FILE}"
chmod 600 "${BUPTY_CREDENTIALS_FILE}"
t_begin "缓存命中：改文件不重读"
assert_ok creds_load
assert_eq "${BUPTY_ACCOUNT}" "2025211681" "仍是缓存账号"
assert_eq "${BUPTY_PASSWORD}" "secret-pass" "仍是缓存密码"

# creds_save 使缓存失效（直接写全局新值）。
t_begin "creds_save 使缓存失效"
assert_ok creds_save "8888888888" "new-pass" ""
assert_ok creds_load
assert_eq "${BUPTY_ACCOUNT}" "8888888888" "保存后返回新账号"
assert_eq "${BUPTY_PASSWORD}" "new-pass" "保存后返回新密码"

# creds_clear 使缓存失效（清空全局，文件已删除）。
t_begin "creds_clear 使缓存失效"
assert_ok creds_clear
assert_fail creds_load
assert_eq "${BUPTY_ACCOUNT}" "" "清除后账号为空"
assert_eq "${BUPTY_PASSWORD}" "" "清除后密码为空"

# 缓存路径仍拒绝符号链接（_CREDS_LOADED=1 时也必须校验文件为普通文件）。
t_begin "缓存路径拒绝符号链接"
assert_ok creds_save "2025211681" "p" ""
mv "${BUPTY_CREDENTIALS_FILE}" "${BUPTY_CREDENTIALS_FILE}.real"
ln -s "${BUPTY_CREDENTIALS_FILE}.real" "${BUPTY_CREDENTIALS_FILE}"
assert_fail creds_load
assert_eq "${BUPTY_ACCOUNT}" "" "符号链接下清空账号"
rm -f "${BUPTY_CREDENTIALS_FILE}" "${BUPTY_CREDENTIALS_FILE}.real"

t_summary

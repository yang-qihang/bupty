#!/usr/bin/env bash
# tests/live.sh —— 真实网络「只读」集成测试（登录、教务查询等）。
# 凭据优先从环境变量 BUPTY_USERNAME/BUPTY_PASSWORD 读取，否则读 app 凭据文件。
# 只做读语义；绝不提交/写入任何业务数据。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tui.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

ACCOUNT="${BUPTY_USERNAME:-}"
PASSWORD="${BUPTY_PASSWORD:-}"

# 从凭据文件读取（若环境变量未提供）。
if [[ -z "${ACCOUNT}" || -z "${PASSWORD}" ]]; then
  if creds_load; then
    ACCOUNT="${BUPTY_ACCOUNT}"
    PASSWORD="${BUPTY_PASSWORD}"
  fi
fi

if [[ -z "${ACCOUNT}" || -z "${PASSWORD}" ]]; then
  echo "跳过：未找到凭据（请设置 BUPTY_USERNAME/BUPTY_PASSWORD 或先用 bupty 登录）。"
  exit 0
fi

t_begin "教务登录"
if sjd_login "${ACCOUNT}" "${PASSWORD}"; then
  ((TESTS_PASS += 1))
else
  ((TESTS_FAIL += 1))
  echo "FAIL [教务登录] ${BUPTY_ERR}"
fi

t_begin "当前学期查询（验证 token）"
sjd_authed_request POST "${SJD_BASE}/currentTerm"
if [[ "${HTTP_STATUS}" == "200" ]] && sjd_code_success; then
  ((TESTS_PASS += 1))
  term="$(printf '%s' "${HTTP_BODY}" | jq -r '.data[0].semesterId // empty' 2>/dev/null)"
  echo "  当前学期：${term}"
else
  ((TESTS_FAIL += 1))
  echo "FAIL [当前学期] HTTP ${HTTP_STATUS}"
fi

t_summary

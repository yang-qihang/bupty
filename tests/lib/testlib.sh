#!/usr/bin/env bash
# tests/lib/testlib.sh —— 极简断言测试框架。

TESTS_PASS=0
TESTS_FAIL=0
TESTS_NAME=""

t_begin() {
  TESTS_NAME="$1"
}

# 断言相等。用法：assert_eq <实际值> <期望值> [描述]
assert_eq() {
  local got="$1" want="$2" desc="${3:-}"
  if [[ "${got}" == "${want}" ]]; then
    ((TESTS_PASS += 1))
  else
    ((TESTS_FAIL += 1))
    printf 'FAIL [%s] %s\n' "${TESTS_NAME}" "${desc}"
    printf '  want: %q\n' "${want}"
    printf '  got : %q\n' "${got}"
  fi
}

# 断言成功。用法：assert_ok <命令...>
assert_ok() {
  if "$@" >/dev/null 2>&1; then
    ((TESTS_PASS += 1))
  else
    ((TESTS_FAIL += 1))
    printf 'FAIL [%s] 命令未成功: %s\n' "${TESTS_NAME}" "$*"
  fi
}

# 断言失败（命令应返回非零）。
assert_fail() {
  if "$@" >/dev/null 2>&1; then
    ((TESTS_FAIL += 1))
    printf 'FAIL [%s] 命令不应成功: %s\n' "${TESTS_NAME}" "$*"
  else
    ((TESTS_PASS += 1))
  fi
}

t_summary() {
  printf '\n测试结果：通过 %d，失败 %d\n' "${TESTS_PASS}" "${TESTS_FAIL}"
  if [[ "${TESTS_FAIL}" -gt 0 ]]; then
    return 1
  fi
  return 0
}

#!/usr/bin/env bash
# tests/snapshot.sh —— TUI 渲染快照测试：渲染各视图，断言关键文本存在、无乱码。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# 在非 TTY 下渲染一帧（禁用颜色，便于文本断言）。
# 用空的 XDG_CONFIG_HOME 保证无凭据、无网络请求，渲染「未登录」态，结果确定。
render_view() {
  local view="$1"
  local empty_cfg
  empty_cfg="$(mktemp -d)"
  BUPTY_NO_COLOR=1 COLUMNS=80 LINES=24 BUPTY_HOME="${BUPTY_HOME}" XDG_CONFIG_HOME="${empty_cfg}" bash -c '
    set -uo pipefail
    source "${BUPTY_HOME}/tui.sh"
    TUI_VIEW="'"${view}"'"
    tui_render_once
  ' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
  rm -rf "${empty_cfg}"
}

strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

# 直接渲染空教室「内容函数」（加载 fixture 数据后调用 _classrooms_render_content），
# 用于断言内容标题「空教室」存在（render_view 走登录态，不会进入内容渲染）。
render_classrooms_content() {
  BUPTY_NO_COLOR=1 COLUMNS=80 LINES=24 BUPTY_HOME="${BUPTY_HOME}" bash -c '
    set -uo pipefail
    source "${BUPTY_HOME}/tui.sh"
    CLASSROOMS_DATA="$(cat "${BUPTY_HOME}/tests/fixtures/classrooms.json")"
    _classrooms_precompute
    _classrooms_render_content
  ' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

t_begin "首页渲染"
home="$(render_view home)"
assert_ok grep -q '首页' <<< "${home}"
assert_ok grep -q '作业 DDL' <<< "${home}"
assert_ok grep -q '空教室' <<< "${home}"
assert_ok grep -q '设置' <<< "${home}"

t_begin "设置页渲染"
settings="$(render_view settings)"
assert_ok grep -q '账号设置' <<< "${settings}"
assert_ok grep -q '登录' <<< "${settings}"

t_begin "作业视图渲染（未登录态）"
stub="$(render_view assignments)"
assert_ok grep -q '作业 DDL' <<< "${stub}"
assert_ok grep -q '请先在设置中登录' <<< "${stub}"

t_begin "课表视图渲染（未登录态）"
sched="$(render_view schedule)"
assert_ok grep -q '课表' <<< "${sched}"
assert_ok grep -q '请先在设置中登录' <<< "${sched}"

t_begin "空教室视图内容渲染（含标题）"
cr="$(render_classrooms_content)"
assert_ok grep -qE '^ 空教室$' <<< "${cr}"
assert_ok grep -q '西土城' <<< "${cr}"
assert_ok grep -q '主楼' <<< "${cr}"

t_begin "渲染输出非空且无 NUL 字节"
if [[ -n "${home}" ]]; then
  ((TESTS_PASS += 1))
else
  ((TESTS_FAIL += 1))
  echo "FAIL [渲染输出非空且无 NUL 字节] 输出为空"
fi
if printf '%s' "${home}" | tr -d '\0' | grep -q . && \
   [[ "$(printf '%s' "${home}" | tr -cd '\0' | wc -c)" -eq 0 ]]; then
  ((TESTS_PASS += 1))
else
  ((TESTS_FAIL += 1))
  echo "FAIL [渲染输出非空且无 NUL 字节] 检测到 NUL 字节"
fi

t_summary

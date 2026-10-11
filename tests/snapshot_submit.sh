#!/usr/bin/env bash
# tests/snapshot_submit.sh —— 提交对话框在不同终端宽度下的渲染快照：
# 断言关键文案存在、且无任何行超出该宽度（不溢出、不折行错乱）。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/http.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/session.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/creds.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/ui.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/views/assignments.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

t_begin "提交对话框多宽度渲染"
for w in 120 90 60 50 36 28; do
  UI_COLS=$w
  out="$(BUPTY_NO_COLOR=1 _submit_show_instructions "【测试课程】测试作业" | strip_ansi)"
  # 关键文案必须在（各宽度都出现）。
  if ! grep -q '附件约束' <<< "${out}" || ! grep -q '提交方式说明' <<< "${out}"; then
    ((TESTS_FAIL += 1))
    echo "FAIL [提交对话框多宽度渲染] 宽度 ${w} 缺少关键文案"
    continue
  fi
  # 无任何行超出宽度（去掉行尾空白后，显示宽度 ≤ 终端宽度）。
  overflow=0
  while IFS= read -r line; do
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue
    _core_width "${line}"
    if (( _CORE_W > w )); then
      overflow=1
      echo "  宽度 ${w} 溢出（宽 ${_CORE_W}）：${line}"
    fi
  done <<< "${out}"
  if (( overflow )); then
    ((TESTS_FAIL += 1))
  else
    ((TESTS_PASS += 1))
  fi
done

t_begin "提交对话框极窄仍不崩溃"
UI_COLS=20
if BUPTY_NO_COLOR=1 _submit_show_instructions "测试" >/dev/null 2>&1; then
  ((TESTS_PASS += 1))
else
  ((TESTS_FAIL += 1))
  echo "FAIL [提交对话框极窄仍不崩溃] 宽度 20 下异常"
fi

t_summary

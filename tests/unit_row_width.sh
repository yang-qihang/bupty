#!/usr/bin/env bash
# tests/unit_row_width.sh —— 列表页「选中行 / 非选中行」的显示宽度必须**恰好等于 UI_COLS**。
#
# 为什么需要这条断言（缺陷背景）：
#   合并后的宽度内核按 East Asian Width 计列。选中行前缀「 › 」里的「›」(U+203A)
#   属于 EAW=Ambiguous，在 BUPTY_AMBIG_W=1（CJK 终端，本仓库默认）下算 **1 列**。
#   而各页的行模板是按老内核（`cp > 255 → 2 列`）写的预算：
#       选中行：` %s› %s%s` + body(UI_COLS-4) → 3 + (UI_COLS-4) = UI_COLS - 1
#       非选中：`   %s`      + body(UI_COLS-6) → 3 + (UI_COLS-6) = UI_COLS - 3
#   于是选中行比整帧窄 1 列、非选中行窄 3 列，底色会留下缺口。
#   **这不是溢出**（行永远 <= UI_COLS），所以既有的「行宽 <= UI_COLS」类断言抓不到它，
#   必须由「恰为 UI_COLS」这条正向断言钉住。
#
# 本文件在 lib 侧把预算统一改成 UI_COLS-3 之前**应当是红的**（见报告 task B）。
#
# 纪律：期望值由本文件自己构造——宽度用 lib/core.sh 的 _core_width（单一真源）量，
# 行数据与上下文（UI_COLS / UI_HL_FG / UI_RESET / *_SEL）全部显式摆好，只调用各页
# 自己的行渲染函数，不复制它们的模板逻辑。
set -uo pipefail

TMPROOT="$(mktemp -d)"
export XDG_CONFIG_HOME="${TMPROOT}/config"
mkdir -p "${XDG_CONFIG_HOME}/bupty"
printf '{"account":"2025000000","password":"x"}' > "${XDG_CONFIG_HOME}/bupty/credentials.json"
chmod 600 "${XDG_CONFIG_HOME}/bupty/credentials.json"
export BUPTY_NO_COLOR=1

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tui.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"
set +e

ui_theme_init dark
ui_box_init

UI_COLS=100
UI_ROWS=30

# 剥 ANSI 后按显示列量宽（_CORE_W）。剥色只是为了不让转义序列干扰 _core_width；
# 宽度口径本身来自 lib/core.sh，不在这里重新实现一份。
# 剥的是**任意** CSI 序列（不止颜色里的 `...m`）：ui_select_option 的整行还带 `\r\033[K`
# （回车 + 清行）与重画时的光标上移 `\033[NA`，这些都不在终端上占列，量宽前必须去掉
# ——`\r`（0x0D）不是 ANSI 序列，得单独删，否则会被 _core_width 当成 1 列。
rw_width() {
  local plain
  plain="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g')"
  _core_width "${plain}"
  printf '%s' "${_CORE_W}"
}

# rw_assert <描述> <渲染出的整行>
# 断言该行显示宽度恰为 UI_COLS。空行视为失败（没渲染出行 = 断言没有意义）。
rw_assert() {
  local desc="$1" line="$2"
  if [[ -z "${line}" ]]; then
    assert_eq "空" "非空" "${desc}：行渲染函数没有输出"
    return
  fi
  assert_eq "$(rw_width "${line}")" "${UI_COLS}" \
    "${desc}：显示宽度应恰为 UI_COLS=${UI_COLS}（短 1~3 列 = 底色缺口）"
}

rw_total=0
rw_count() { rw_total=$((rw_total + 1)); }

# ---------------------------------------------------------------------------
# 1. classrooms —— `_classrooms_render_row <i>`，数据是 \x1f 分隔的 TSV
# ---------------------------------------------------------------------------
t_begin "列表行宽：classrooms"
_sep=$'\x1f'
_CLASSROOMS_ROWS=(
  "教三楼${_sep}3-335${_sep}90${_sep}1,2${_sep}1-2"
  "教一楼${_sep}101${_sep}80${_sep}3,4${_sep}3-4"
)
CLASSROOMS_SEL=0
CLASSROOMS_SHOW_HIDDEN=0
rw_assert "classrooms 选中行" "$(_classrooms_render_row 0)"; rw_count
rw_assert "classrooms 非选中行" "$(_classrooms_render_row 1)"; rw_count

# ---------------------------------------------------------------------------
# 2. schedule —— `_schedule_day_row <i>`，数据是 \x1f 分隔的 TSV
# ---------------------------------------------------------------------------
t_begin "列表行宽：schedule"
_SCHEDULE_DAY_ROWS=(
  "08:00-09:35${_sep}数据结构${_sep}3-335${_sep}1-16周"
  "10:15-11:50${_sep}高等数学${_sep}2-201${_sep}1-16周"
)
SCHEDULE_SEL=0
rw_assert "schedule 选中行" "$(_schedule_day_row 0)"; rw_count
rw_assert "schedule 非选中行" "$(_schedule_day_row 1)"; rw_count

# ---------------------------------------------------------------------------
# 3. grades —— `_grades_render_row <i>`，数据是纯文本行
# ---------------------------------------------------------------------------
t_begin "列表行宽：grades"
_GRADES_ROWS=(
  "数据结构 [学分4] 92 · 必修 · 通过"
  "高等数学 [学分5] 88 · 必修 · 通过"
)
GRADES_SEL=0
rw_assert "grades 选中行" "$(_grades_render_row 0)"; rw_count
rw_assert "grades 非选中行" "$(_grades_render_row 1)"; rw_count

# ---------------------------------------------------------------------------
# 4. exams —— `_exams_render_row <i>`，数据是纯文本行
# ---------------------------------------------------------------------------
t_begin "列表行宽：exams"
_EXAMS_ROWS=(
  "2026-01-05 08:00-09:35 数据结构 @3-335"
  "2026-01-08 10:15-11:50 高等数学 @2-201"
)
EXAMS_SEL=0
rw_assert "exams 选中行" "$(_exams_render_row 0)"; rw_count
rw_assert "exams 非选中行" "$(_exams_render_row 1)"; rw_count

# ---------------------------------------------------------------------------
# 5. public —— `_public_render_event_row <i>`，数据在 _PUBLIC_VISIBLE_ROWS
# ---------------------------------------------------------------------------
t_begin "列表行宽：public"
_PUBLIC_VISIBLE_ROWS=(
  "讲座：人工智能前沿 · 2026-01-05 · 教三 101"
  "招聘会：秋季专场 · 2026-01-06 · 体育馆"
)
PUBLIC_SEL=0
rw_assert "public 选中行" "$(_public_render_event_row 0)"; rw_count
rw_assert "public 非选中行" "$(_public_render_event_row 1)"; rw_count

# ---------------------------------------------------------------------------
# 6. booking —— `_booking_render_category_row <i>`，数据是 jq 解析出的 BOOKING_CATEGORIES
# ---------------------------------------------------------------------------
t_begin "列表行宽：booking"
BOOKING_CATEGORIES="$(_booking_parse_categories \
  "$(cat "${BUPTY_HOME}/tests/fixtures/booking-roommenu.json")")"
BOOKING_SEL_CAT=0
rw_assert "booking 选中行" "$(_booking_render_category_row 0)"; rw_count
rw_assert "booking 非选中行" "$(_booking_render_category_row 1)"; rw_count

# ---------------------------------------------------------------------------
# 7. ui_select_option —— lib/ui.sh，选中行 ` %s` + core_fit("› label", UI_COLS-1)
#    前缀 1 列 + 预算(UI_COLS-1) = UI_COLS（预算里已含「› 」的 2 列）
# ---------------------------------------------------------------------------
# ui_select_option 是个交互循环（渲染一屏 → ui_read_key），没有单独的「渲染一行」函数。
# 打桩 ui_read_key 让它渲染完第一帧就收到 ENTER 后退出，取第一行（sel=0 的选中行）。
# 这是对**产品渲染代码**的调用，不是复制模板：模板仍在 lib/ui.sh 里。
t_begin "列表行宽：ui_select_option"
ui_read_key() { printf 'ENTER'; }
# 输出重定向到文件（而不是 `$( )`）：命令替换会 fork 子 shell，ui_select_option 在里面写的
# UI_SELECT_RESULT 传不回来，下面那条「确认的是第一项」就永远测不到真实值。
rw_out="${TMPROOT}/ui_select_option.out"
ui_select_option "v1|选项甲" "v2|选项乙" > "${rw_out}"
rw_sel_line="$(sed -n '1p' "${rw_out}")"
rw_assert "ui_select_option 选中行" "${rw_sel_line}"; rw_count
assert_eq "${UI_SELECT_RESULT}" "v1" "打桩 ENTER 应确认第一项（证明量到的确是选中帧）"

# ---------------------------------------------------------------------------
# 8. settings —— lib/views/settings.sh 的两处选中行
#    主题选择器 _render_settings_picker 与主列表 render_settings，模板都是
#    ` %s` + ui_paint hl("› " + core_fit(label, UI_COLS-3))：
#    1（前导空格）+ 1（›）+ 1（空格）+ (UI_COLS-3) = UI_COLS。
#    两处都取含「›」的那一行（各只有一行带选中标记）。
# ---------------------------------------------------------------------------
t_begin "列表行宽：settings 选择器"
SETTINGS_PICKER=1
SETTINGS_PICKER_SEL=3
rw_picker_out="$( _render_settings_picker )"
rw_sel_line="$(printf '%s\n' "${rw_picker_out}" | grep '›')"
rw_assert "settings 选择器选中行" "${rw_sel_line}"; rw_count

t_begin "列表行宽：settings 主列表"
SETTINGS_PICKER=0
SETTINGS_SEL=0
rw_sel_line="$( render_settings | grep '›' )"
rw_assert "settings 主列表选中行" "${rw_sel_line}"; rw_count

# ---------------------------------------------------------------------------
# 9. assignments —— lib/views/assignments.sh 的选中行
#    模板 ` %s` + _core_fit_compute(raw, UI_COLS-1)：1 + (UI_COLS-1) = UI_COLS。
#    （这一处的选中标记「›」不参与前缀，前缀只有 1 列前导空格，所以预算是 UI_COLS-1。）
# ---------------------------------------------------------------------------
t_begin "列表行宽：assignments"
_ASSIGNMENTS_ROWS=("2026-01-05${_sep}3天${_sep}数据结构${_sep}第一章作业${_sep}未提交")
_ASSIGNMENTS_COLORS=(danger)
ASSIGNMENTS_SEL=0
rw_assert "assignments 选中行" "$(_assignments_render_row 0)"; rw_count

# ---------------------------------------------------------------------------
# 非空集 / 反向对照
# ---------------------------------------------------------------------------
t_begin "列表行宽：覆盖数与反向对照"
# 六个列表页各两条（选中 + 非选中），加上四处「前缀列数不同」的选中行
# （ui_select_option、settings 选择器、settings 主列表、assignments）。
assert_eq "${rw_total}" "16" "六个列表页 × (选中+非选中) + 四处选中行 都应被检查（非空集）"
# 反向对照：同一页的选中行与非选中行必须**渲染得不一样**（否则说明 *SEL 没起作用、
# 上面那些 rw_assert 只是在量同一个东西，断言没有意义）。
CLASSROOMS_SEL=0
rw_sel="$(_classrooms_render_row 0)"
rw_other="$(_classrooms_render_row 1)"
if [[ "${rw_sel}" != "${rw_other}" ]]; then
  ((TESTS_PASS += 1))
else
  ((TESTS_FAIL += 1))
  printf 'FAIL [列表行宽：覆盖数与反向对照] 选中行与非选中行渲染结果相同 → *_SEL 没生效\n'
fi
# 选中行必须带选中标记「›」，否则说明量的不是选中行。
_core_width "$(printf '%s' "${rw_sel}" | sed 's/\x1b\[[0-9;]*m//g')"
assert_eq "$(printf '%s' "${rw_sel}" | grep -c '›')" "1" "选中行应恰有一个选中标记 ›"

# 新覆盖的四处（7~9）也要证明「量得出来差别」：settings 选择器里**非选中**的主题行
# 按设计不补齐（core_clip 只截断不填充），宽度必然 != UI_COLS。喂给同一条 rw_width
# 应当量出 != UI_COLS —— 否则说明量器对这两类行都给出同一个数、上面四条断言是恒真的。
rw_non_row="$(printf '%s\n' "${rw_picker_out}" | grep '暗色' | sed -n '1p')"
if [[ -n "${rw_non_row}" && "$(rw_width "${rw_non_row}")" != "${UI_COLS}" ]]; then
  ((TESTS_PASS += 1))
else
  ((TESTS_FAIL += 1))
  printf 'FAIL [列表行宽：覆盖数与反向对照] 非选中行竟也等于 UI_COLS → 量器没有分辨力（或没取到非选中行）\n'
fi
# 宽度引擎自检：UI_COLS 真的被采纳（100 列下量一条 100 列的纯 ASCII 串 = 100）。
assert_eq "$(rw_width "$(printf '%*s' "${UI_COLS}" '')")" "${UI_COLS}" \
  "宽度引擎自检：100 个空格应量出 100 列"

rm -rf "${TMPROOT}"
t_summary

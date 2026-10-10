#!/usr/bin/env bash
# tests/unit_parse.sh —— 纯解析函数单元测试。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/parse.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# 单行周次列表。
_weeks() {
  parse_expand_week_numbers "$1" | paste -sd, -
}

# 由字段解析周次（带回退）。
_field_weeks() {
  parse_sjd_week_numbers "$1" "$2" | paste -sd, -
}

# ---- 周次展开 ----
t_begin "周次展开"
assert_eq "$(_weeks '1-5[周]')" "1,2,3,4,5" "1-5[周]"
assert_eq "$(_weeks '1-5[周](单)')" "1,3,5" "1-5[周](单)"
assert_eq "$(_weeks '2,4,6[周]')" "2,4,6" "2,4,6[周]"
assert_eq "$(_weeks '1-17单')" "1,3,5,7,9,11,13,15,17" "1-17单"
assert_eq "$(_weeks '2-18双')" "2,4,6,8,10,12,14,16,18" "2-18双"
assert_eq "$(_weeks '1-17单,2-18双')" "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18" "1-17单,2-18双"
assert_eq "$(_field_weeks '' '第1周,第3周')" "1,3" "第1周,第3周（回退提取）"
assert_eq "$(_field_weeks '2-18双' '1,3,5')" "2,4,6,8,10,12,14,16,18" "优先 classWeek"

# 回归：parse_sjd_week_numbers 末尾必须有换行，否则 while read 丢末行。
_count_weeks_via_read() {
  local c=0
  while IFS= read -r w; do c=$((c + 1)); done < <(parse_sjd_week_numbers "$1" "$2")
  printf '%s' "$c"
}
assert_eq "$(_count_weeks_via_read '' '1-16')" "16" "while read 读到全部 16 个周次"

# ---- 节次解析 ----
t_begin "节次解析"
assert_eq "$(parse_sjd_slots '1030405')" "2 4" "1030405 -> 节3..5"
assert_eq "$(parse_sjd_slots '20607')" "5 6" "20607 -> 节6..7"
assert_eq "$(parse_sjd_slots '115')" "" "越界(15) -> 空"

# ---- 教室归一 ----
t_begin "教室归一"
assert_eq "$(parse_normalize_room '3-335')" "335" "3-335"
assert_eq "$(parse_normalize_room '教1-101')" "101" "教1-101"
assert_eq "$(parse_normalize_room '202-203')" "202-203" "202-203 保留"

# ---- 楼名归一 ----
t_begin "楼名归一"
assert_eq "$(parse_building_name '教一楼')" "教1" "教一楼"
assert_eq "$(parse_building_name '校本部-教三楼')" "教3" "校本部-教三楼"
assert_eq "$(parse_building_name '未来学习大楼')" "主楼" "未来学习大楼"
assert_eq "$(parse_building_name '沙河-N楼')" "综合教学楼N" "沙河-N楼"
assert_eq "$(parse_building_name '综教S楼')" "教学实验综合楼S" "综教S楼"
assert_eq "$(parse_building_name '智慧教室楼')" "智慧教学楼" "智慧教室楼"
assert_eq "$(parse_building_name '教师自行安排')" "教师自行安排" "非白名单原样"

# ---- 学期推断 ----
t_begin "学期推断"
assert_eq "$(parse_suggested_term '2026-03-15')" "2025-2026-2 2026-03-02" "春季"
assert_eq "$(parse_suggested_term '2026-08-24')" "2026-2027-1 2026-08-31" "秋季"
assert_eq "$(parse_suggested_term '2026-01-15')" "2025-2026-1 2025-09-01" "一月算上一年"

# ---- 学期号校验 ----
t_begin "学期号校验"
assert_ok parse_is_valid_term_id "2025-2026-1"
assert_ok parse_is_valid_term_id " 2025-2026-2 "
assert_fail parse_is_valid_term_id "2025-2026-3"
assert_fail parse_is_valid_term_id "garbage"

# ---- 时间解析 ----
t_begin "分钟解析"
assert_eq "$(parse_minutes '24:00')" "1440" "24:00"
assert_fail parse_minutes "24:01"
assert_fail parse_minutes "09:60"
assert_fail parse_minutes "x:00"

t_summary

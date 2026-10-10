#!/usr/bin/env bash
# tests/unit_schedule.sh —— 教务课表（sjd.sh）纯函数单元测试（全离线 fixture）。
# 只测可离线、无副作用的纯函数，不调用 sjd_login / sjd_fetch_schedule。
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
source "${BUPTY_HOME}/lib/parse.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/sjd.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

CURRENT_PAYLOAD="$(cat "${BUPTY_HOME}/tests/fixtures/sjd-current-week.json")"
BEFORE_PAYLOAD="$(cat "${BUPTY_HOME}/tests/fixtures/sjd-before-first-week.json")"
CURRICULUM_PAYLOAD="$(cat "${BUPTY_HOME}/tests/fixtures/sjd-curriculum.json")"
SCHEDULE="$(cat "${BUPTY_HOME}/tests/fixtures/schedule.json")"

# ---------------------------------------------------------------------------
# 1. 学期号推断
# ---------------------------------------------------------------------------
t_begin "学期号推断"
assert_eq "$(sjd_infer_term_id "${CURRENT_PAYLOAD}")" "2025-2026-2" "当前周 payload -> 2025-2026-2"
assert_eq "$(sjd_infer_term_id "${BEFORE_PAYLOAD}")" "2026-2027-1" "开学前 payload（topInfo 回退）-> 2026-2027-1"

# ---------------------------------------------------------------------------
# 2. 开学日期推断
# ---------------------------------------------------------------------------
t_begin "开学日期推断"
assert_eq "$(sjd_infer_term_start_date "${CURRENT_PAYLOAD}")" "2026-03-02" "当前周 payload -> 2026-03-02"
assert_eq "$(sjd_infer_term_start_date "${BEFORE_PAYLOAD}")" "2026-08-31" "开学前 payload（zc=0 向前推一周）-> 2026-08-31"

# ---------------------------------------------------------------------------
# 3. 当前周计算
# ---------------------------------------------------------------------------
t_begin "当前周计算"
past_start="2026-08-31"
past_days="$(core_days_between "$(core_today)" "${past_start}")"
assert_eq "$(sjd_compute_current_week "${past_start}")" "$(( past_days / 7 + 1 ))" "过去开学日 -> floor(days/7)+1"
future_week="$(sjd_compute_current_week '2099-09-01')"
if [[ "${future_week}" =~ ^-?[0-9]+$ && "${future_week}" -le 0 ]]; then
  ((TESTS_PASS += 1))
else
  ((TESTS_FAIL += 1))
  printf 'FAIL [当前周计算] 未来开学日应返回非正数，got: %q\n' "${future_week}"
fi

# ---------------------------------------------------------------------------
# 4. 课表解析
# ---------------------------------------------------------------------------
courses="$(sjd_parse_schedule_courses "${CURRICULUM_PAYLOAD}")"

t_begin "课表解析：数量"
assert_eq "$(printf '%s' "${courses}" | jq 'length')" \
  "$(printf '%s' "${SCHEDULE}" | jq '.courses | length')" \
  "课程数量与 schedule.json 一致"

t_begin "课表解析：逐字段对比"
want="$(printf '%s' "${SCHEDULE}" | jq -c '.courses | map({name, teacher, room, week_numbers, weekday, start_slot, end_slot, section_text, time_range})')"
got="$(printf '%s' "${courses}" | jq -c 'map({name, teacher, room, week_numbers, weekday, start_slot, end_slot, section_text, time_range})')"
assert_eq "${got}" "${want}" "name/teacher/room/week_numbers/weekday/start_slot/end_slot/section_text/time_range 与 schedule.json 一致（忽略 id）"

t_begin "课表解析：排序"
assert_eq "$(printf '%s' "${courses}" | jq -c 'sort_by(.weekday, .start_slot, .name)')" \
  "${courses}" \
  "按 (weekday, start_slot, name) 升序"

t_begin "课表解析：去重"
assert_eq "$(printf '%s' "${courses}" | jq '[.[].id] | length')" \
  "$(printf '%s' "${courses}" | jq '[.[].id] | unique | length')" \
  "同一 jx0408id 只出现一次"
assert_eq "$(printf '%s' "${courses}" | jq -c '[.[].id]')" \
  '["fixture-course-1","fixture-course-2"]' \
  "id 直接取源 jx0408id"

# ---------------------------------------------------------------------------
# 5. 考试不混入课程（普通课程解析只处理含 courseName/jx0408id 的对象）
# ---------------------------------------------------------------------------
EXAMS_PAYLOAD="$(cat "${BUPTY_HOME}/tests/fixtures/schedule-exams.synthetic.json")"
t_begin "考试不混入课程"
assert_eq "$(sjd_parse_schedule_courses "${EXAMS_PAYLOAD}")" "[]" \
  "仅含 name/考试字段的对象不解析为课程"

t_summary

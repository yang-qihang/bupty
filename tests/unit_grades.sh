#!/usr/bin/env bash
# tests/unit_grades.sh —— 成绩与考试（sjd.sh / parse.sh）纯函数单元测试（全离线 fixture）。
# 只测可离线、无副作用的纯函数，不调用 sjd_login / sjd_fetch_grade_terms / sjd_fetch_grades / sjd_fetch_exams。
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

# ---------------------------------------------------------------------------
# 1. 考试时间解析 parse_exam_time（16 例，逐条断言）
# ---------------------------------------------------------------------------
t_begin "考试时间解析"
assert_eq "$(parse_exam_time '2026-09-07 09:20-11:00')" "2026-09-07|09:20|11:00" "ISO 日期 + 半角横线"
assert_eq "$(parse_exam_time '2026年9月7日 9:20～11:00')" "2026-09-07|09:20|11:00" "中文年月日 + 全角波浪线"
assert_eq "$(parse_exam_time '2026/9/7 09:20:00 至 11:00:00')" "2026-09-07|09:20|11:00" "斜杠日期 + 至 + 秒"
assert_eq "$(parse_exam_time '2026-09-07 09:20 - 2026-09-07 11:00')" "2026-09-07|09:20|11:00" "双日期夹横线（唯一日期去重）"
assert_eq "$(parse_exam_time '2026-09-07 23:00-24:00')" "2026-09-07|23:00|24:00" "24:00 作结束时刻合法"
assert_eq "$(parse_exam_time '另行通知')" "||" "另行通知 -> 全空"
assert_eq "$(parse_exam_time '2026-09-07 11:00-09:00')" "2026-09-07||" "start>=end 只留日期"
assert_eq "$(parse_exam_time '2026-09-07 09:60-11:00')" "2026-09-07||" "分钟越界 09:60"
assert_eq "$(parse_exam_time '2026-02-30 09:00-11:00')" "||" "不存在的日期"
assert_eq "$(parse_exam_time '2026-09-07 09:00:30-11:00')" "2026-09-07||" "秒非 00"
assert_eq "$(parse_exam_time '2026-09-07 24:00-24:00')" "2026-09-07||" "start 为 24:00 非法"
assert_eq "$(parse_exam_time '2026-09-07 09:00 11:00')" "2026-09-07||" "分隔符仅空白非法"
assert_eq "$(parse_exam_time '2026-09-07 上午')" "2026-09-07||" "缺两个时刻"
assert_eq "$(parse_exam_time '2026-09-07 109:00-11:00')" "2026-09-07||" "时刻两侧紧邻数字非法"
assert_eq "$(parse_exam_time '2026-09-07/2026-09-08 09:00-11:00')" "||" "两个日期非法"
assert_eq "$(parse_exam_time '2026-09-071 09:00-11:00')" "||" "日期后紧邻数字非法"

# ---------------------------------------------------------------------------
# 2. 时刻解析 parse_minutes（考试范围边界）
# ---------------------------------------------------------------------------
t_begin "分钟解析"
assert_eq "$(parse_minutes '00:00')" "0" "00:00"
assert_eq "$(parse_minutes '23:59')" "1439" "23:59"
assert_eq "$(parse_minutes '24:00')" "1440" "24:00"
assert_fail parse_minutes "24:01"
assert_fail parse_minutes "09:60"

# ---------------------------------------------------------------------------
# 3. 学期解析 sjd_parse_grade_terms（用 grade-terms.synthetic.json 构造 current/list payload）
# ---------------------------------------------------------------------------
CURRENT_PAYLOAD='{"code":1,"data":[{"semesterId":"2026-2027-1"}]}'
# 列表带一条重复项，用于验证去重。
LIST_PAYLOAD='{"code":1,"data":[
  {"semesterId":"2026-2027-1","semesterName":"2026-2027-1（合成学期示例）"},
  {"semesterId":"2025-2026-2","semesterName":"2025-2026-2（合成学期示例）"},
  {"semesterId":"2025-2026-2","semesterName":"2025-2026-2（合成学期示例）"}
]}'
TERMS_CONTRACT="$(cat "${BUPTY_HOME}/tests/fixtures/grade-terms.synthetic.json")"

terms_out="$(sjd_parse_grade_terms "${CURRENT_PAYLOAD}" "${LIST_PAYLOAD}")"

t_begin "学期解析：current_term_id"
assert_eq "$(printf '%s' "${terms_out}" | jq -r '.current_term_id')" "2026-2027-1" "当前学期 id"

t_begin "学期解析：terms 正确且去重"
assert_eq "$(printf '%s' "${terms_out}" | jq -c '.terms | sort_by(.id)')" \
  "$(printf '%s' "${TERMS_CONTRACT}" | jq -c '.terms | sort_by(.id)')" \
  "terms（id/name，按 id 排序后）与 grade-terms.synthetic.json 一致（重复项已去重）"

t_begin "学期解析：name 空回退 id + 当前学期前置"
LIST_EMPTY_NAME='{"code":1,"data":[{"semesterId":"2025-2026-2","semesterName":""}]}'
assert_eq "$(sjd_parse_grade_terms "${CURRENT_PAYLOAD}" "${LIST_EMPTY_NAME}" | jq -c '.')" \
  '{"current_term_id":"2026-2027-1","terms":[{"id":"2026-2027-1","name":"2026-2027-1"},{"id":"2025-2026-2","name":"2025-2026-2"}]}' \
  "name 空用 id 填充，当前学期不在列表时插入到最前"

t_begin "学期解析：current 缺失报错"
assert_fail sjd_parse_grade_terms '{"code":1,"data":[]}' "${LIST_PAYLOAD}"

# ---------------------------------------------------------------------------
# 4. 成绩解析 sjd_parse_grades（sjd-grades.synthetic.json -> grade-report.synthetic.json）
# ---------------------------------------------------------------------------
GRADES_PAYLOAD="$(cat "${BUPTY_HOME}/tests/fixtures/sjd-grades.synthetic.json")"
GRADE_REPORT="$(cat "${BUPTY_HOME}/tests/fixtures/grade-report.synthetic.json")"

grades_out="$(sjd_parse_grades "${GRADES_PAYLOAD}" "2026-2027-1" "1")"

t_begin "成绩解析：items 与契约一致"
assert_eq "$(printf '%s' "${grades_out}" | jq -c '[.items[] | {name, score, credits, course_code, course_attribute, course_nature, exam_nature, semester_name, grade_status}]')" \
  "$(printf '%s' "${GRADE_REPORT}" | jq -c '[.items[] | {name, score, credits, course_code, course_attribute, course_nature, exam_nature, semester_name, grade_status}]')" \
  "name/score/credits/course_code/course_attribute/course_nature/exam_nature/semester_name/grade_status 与 grade-report.synthetic.json 一致（忽略 id）"

t_begin "成绩解析：fraction/credit 数字与空值串化"
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.items[0].score')" "0" "数字 0 -> \"0\""
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.items[0].credits')" "0" "数字 0 -> \"0\""
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.items[1].score')" "通过" "文字保留"
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.items[1].credits')" "2.5" "小数 -> \"2.5\""
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.items[2].score')" "" "null -> 空"
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.items[2].credits')" "" "null -> 空"

t_begin "成绩解析：元数据"
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.term_id')" "2026-2027-1" "term_id 透传"
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.record_type')" "1" "record_type=1 透传"
assert_eq "$(printf '%s' "${grades_out}" | jq -r '.average_grade_point')" "" "pjxfjd=null -> 空"

t_begin "成绩解析：record_type 合法值透传"
assert_eq "$(sjd_parse_grades "${GRADES_PAYLOAD}" "2026-2027-1" "0" | jq -r '.record_type')" "0" "record_type=0（首次）"
assert_eq "$(sjd_parse_grades "${GRADES_PAYLOAD}" "2026-2027-1" "" | jq -r '.record_type')" "" "record_type 空（全部）"

t_begin "成绩解析：非法 record_type 报错"
assert_fail sjd_parse_grades "${GRADES_PAYLOAD}" "2026-2027-1" "2"
assert_fail sjd_parse_grades "${GRADES_PAYLOAD}" "2026-2027-1" "abc"

t_begin "成绩解析：课程名缺失报错"
assert_fail sjd_parse_grades '{"code":1,"data":[{"achievement":[{"courseName":""}]}]}' "2026-2027-1" "1"

# ---------------------------------------------------------------------------
# 5. 考试安排解析 sjd_parse_exams（sjd-exams.synthetic.json）
# ---------------------------------------------------------------------------
EXAMS_PAYLOAD="$(cat "${BUPTY_HOME}/tests/fixtures/sjd-exams.synthetic.json")"
exams_out="$(sjd_parse_exams "${EXAMS_PAYLOAD}" "2026-2027-1")"

t_begin "考试解析：items 字段"
assert_eq "$(printf '%s' "${exams_out}" | jq -c '[.items[] | {name, date, start_time, end_time, room, time_text}]')" \
  '[{"name":"合成考试示例：精确时间（非真实安排）","date":"2026-09-07","start_time":"08:30","end_time":"10:07","room":"合成考场-201","time_text":"2026-09-07 08:30-10:07"},{"name":"合成考试示例：教学周外（非真实安排）","date":"2026-12-21","start_time":"06:15","end_time":"07:20","room":"合成考场-202","time_text":"2026-12-21 06:15-07:20"},{"name":"合成考试示例：时间待定（非真实安排）","date":"2026-09-14","start_time":"","end_time":"","room":"","time_text":"2026-09-14，具体时间待公布（合成示例）"},{"name":"合成考试示例：日期待定（非真实安排）","date":"","start_time":"","end_time":"","room":"","time_text":"日期与时间待公布（合成示例）"}]' \
  "name/date/start_time/end_time/room/time_text（含时间待定/日期待定）"

t_begin "考试解析：term_id"
assert_eq "$(printf '%s' "${exams_out}" | jq -r '.term_id')" "2026-2027-1" "term_id 透传"

t_begin "考试解析：课程名缺失报错"
assert_fail sjd_parse_exams '{"code":"1","data":[{"courseName":"","examinationPlace":"合成考场-201","time":"2026-09-07 09:20-11:00"}]}' "2026-2027-1"

t_summary

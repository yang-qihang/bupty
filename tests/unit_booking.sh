#!/usr/bin/env bash
# tests/unit_booking.sh —— 图书馆研修间预约（booking.sh）纯函数单元测试（全离线 fixture）。
# 只测可离线、无网络副作用的解析 / 组装 / 持久化函数，不调用 booking_login 等网络函数。
set -uo pipefail

# 隔离配置目录：设置 XDG_CONFIG_HOME/HOME 到临时目录，避免污染真实配置。
TMPROOT="$(mktemp -d)"
export XDG_CONFIG_HOME="${TMPROOT}/config"
export HOME="${TMPROOT}/home"
mkdir -p "${XDG_CONFIG_HOME}" "${HOME}"

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
source "${BUPTY_HOME}/lib/settings.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/booking.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# 日期时刻 -> epoch 毫秒（北京时间）。
_ms() {
  local sec
  sec="$(TZ=Asia/Shanghai date -d "2026-10-14 $1" +%s 2>/dev/null || date -d "2026-10-14 $1" +%s)"
  printf '%s' "$(( sec * 1000 ))"
}

# 完整 "YYYY-MM-DD HH:MM" -> epoch 毫秒（北京时间，用于跨日过滤测试）。
_ms_on() {
  local sec
  sec="$(TZ=Asia/Shanghai date -d "$1" +%s 2>/dev/null || date -d "$1" +%s)"
  printf '%s' "$(( sec * 1000 ))"
}

# 计数辅助（纯 bash，无 jq）。
_booking_pending_n() {
  local s="$1" n=0 line
  if [[ -z "${s}" ]]; then printf '0'; return 0; fi
  while IFS= read -r line; do
    [[ -n "${line}" ]] && n=$(( n + 1 ))
  done <<< "${s}"
  printf '%s' "${n}"
}

# ---------------------------------------------------------------------------
# 1. 分类解析（roomMenu -> [{id,name}]）
# ---------------------------------------------------------------------------
t_begin "分类解析"
CATS="$( _booking_parse_categories "$(cat "${BUPTY_HOME}/tests/fixtures/booking-roommenu.json")" )"
want_cats='[{"id":"100888904","name":"沙河校区·一楼·朗读亭"},{"id":"100651191","name":"沙河校区·三楼·研讨间"},{"id":"101346349","name":"西土城校区·一楼·朗读亭"},{"id":"105106622","name":"西土城校区·红色主题阅览室"}]'
assert_eq "$(printf '%s' "${CATS}" | jq -cS '.')" "$(printf '%s' "${want_cats}" | jq -cS '.')" "id/name 与校区层级拼接"

t_begin "分类解析（childList/nodes/campusName/labName/menuName 兼容）"
CATBODY='{"code":0,"data":[{"campusName":"沙河","nodes":[{"id":1,"labName":"一楼"}]},{"name":"西土城","childList":[{"id":2,"menuName":"二楼"}]}]}'
want_cats2='[{"id":"1","name":"沙河·一楼"},{"id":"2","name":"西土城·二楼"}]'
assert_eq "$( _booking_parse_categories "${CATBODY}" | jq -cS '.' )" \
  "$(printf '%s' "${want_cats2}" | jq -cS '.')" "childList/nodes/campusName/labName/menuName 兼容"

# ---------------------------------------------------------------------------
# 2. 房间解析 + 空闲时段计算（openTimes 减 resvInfo，忽略非目标日期预约）
# ---------------------------------------------------------------------------
t_begin "房间空闲时段计算"
ROOMS="$( _booking_parse_rooms "$(cat "${BUPTY_HOME}/tests/fixtures/booking-reserve.json")" "2026-10-14" )"
# 朗读亭：14:00-14:30 被占用，前/后各一段；10-13 的预约应被忽略。
free_a="$(printf '%s' "${ROOMS}" | jq -cS '[.[] | select(.devId == "100888915") | .free[]]')"
assert_eq "${free_a}" '[{"end":"14:00","start":"08:00"},{"end":"22:00","start":"14:30"}]' "朗读亭空闲时段（减去 14:00-14:30）"
assert_eq "$(printf '%s' "${ROOMS}" | jq -r '[.[] | select(.devId == "100888915") | .minUser] | .[0]')" "1" "朗读亭 minUser=1"
assert_eq "$(printf '%s' "${ROOMS}" | jq -r '[.[] | select(.devId == "100888915") | .maxUser] | .[0]')" "1" "朗读亭 maxUser=1"
# 研讨间：无预约，全天一整段。
free_b="$(printf '%s' "${ROOMS}" | jq -cS '[.[] | select(.devId == "100651195") | .free[]]')"
assert_eq "${free_b}" '[{"end":"22:00","start":"08:00"}]' "研讨间 314 全天空闲"
assert_eq "$(printf '%s' "${ROOMS}" | jq -r '[.[] | select(.devId == "100651195") | .minUser] | .[0]')" "2" "研讨间 minUser=2"

# ---------------------------------------------------------------------------
# 3. 空闲时段计算：步进 / 最短时长过滤 / 时间转 HH:MM
# ---------------------------------------------------------------------------
t_begin "空闲时段计算（步进与最短时长）"
# 08:00-09:00 开放，08:15-08:45 被占；步进 15、最少 15 分钟。
OPEN='[{"openStartTime":"08:00","openEndTime":"09:00"}]'
RESV="$(jq -cn --argjson s "$(_ms '08:15')" --argjson e "$(_ms '08:45')" '[{startTime:$s,endTime:$e}]')"
got_free="$( _booking_compute_free_slots "${OPEN}" "${RESV}" 15 15 "2026-10-14" )"
assert_eq "$(printf '%s' "${got_free}" | jq -cS '.')" '[{"end":"08:15","start":"08:00"},{"end":"09:00","start":"08:45"}]' "两段空闲 HH:MM"
# 步进 30、最少 30 分钟时，08:00-09:00 整体不足两段，只剩 08:00-08:15 短于 30 应被丢弃。
got_short="$( _booking_compute_free_slots "${OPEN}" "${RESV}" 30 30 "2026-10-14" )"
assert_eq "$(printf '%s' "${got_short}" | jq -cS '.')" '[]' "步进 30 下无满足最短时长的片段"

t_begin "空闲时段计算（全天占用/跨开放边界/重叠合并）"
OPEN_DAY='[{"openStartTime":"08:00","openEndTime":"22:00"}]'
# 全天被占 -> 零空闲。
RESV_FULL="$(jq -cn --argjson s "$(_ms '08:00')" --argjson e "$(_ms '22:00')" '[{startTime:$s,endTime:$e}]')"
assert_eq "$( _booking_compute_free_slots "${OPEN_DAY}" "${RESV_FULL}" 5 10 "2026-10-14" | jq -cS '.' )" '[]' "全天占用零空闲"
# 预约从开放前跨到 09:00 -> 仅 09:00-22:00 空闲。
RESV_EARLY="$(jq -cn --argjson s "$(_ms '07:00')" --argjson e "$(_ms '09:00')" '[{startTime:$s,endTime:$e}]')"
assert_eq "$( _booking_compute_free_slots "${OPEN_DAY}" "${RESV_EARLY}" 5 10 "2026-10-14" | jq -cS '.' )" '[{"end":"22:00","start":"09:00"}]' "预约跨过开放开始"
# 预约跨过开放结束（21:00-23:00）-> 08:00-21:00 空闲。
RESV_LATE="$(jq -cn --argjson s "$(_ms '21:00')" --argjson e "$(_ms '23:00')" '[{startTime:$s,endTime:$e}]')"
assert_eq "$( _booking_compute_free_slots "${OPEN_DAY}" "${RESV_LATE}" 5 10 "2026-10-14" | jq -cS '.' )" '[{"end":"21:00","start":"08:00"}]' "预约跨过开放结束"
# 重叠预约合并（08:15-08:45 与 08:30-09:00）-> 08:00-08:15 与 09:00-22:00。
RESV_OVERLAP="$(jq -cn --argjson s1 "$(_ms '08:15')" --argjson e1 "$(_ms '08:45')" --argjson s2 "$(_ms '08:30')" --argjson e2 "$(_ms '09:00')" '[{startTime:$s1,endTime:$e1},{startTime:$s2,endTime:$e2}]')"
assert_eq "$( _booking_compute_free_slots "${OPEN_DAY}" "${RESV_OVERLAP}" 5 10 "2026-10-14" | jq -cS '.' )" \
  '[{"end":"08:15","start":"08:00"},{"end":"22:00","start":"09:00"}]' "重叠预约合并"

t_begin "空闲时段计算（跨日预约仅保留目标日期）"
# 10-13 全天占用应被忽略，10-14 14:00-14:30 应被减去。
RESV_MIX="$(jq -cn \
  --argjson s1 "$(_ms_on '2026-10-13 08:00')" --argjson e1 "$(_ms_on '2026-10-13 22:00')" \
  --argjson s2 "$(_ms_on '2026-10-14 14:00')" --argjson e2 "$(_ms_on '2026-10-14 14:30')" \
  '[{startTime:$s1,endTime:$e1},{startTime:$s2,endTime:$e2}]')"
assert_eq "$( _booking_compute_free_slots "${OPEN_DAY}" "${RESV_MIX}" 5 10 "2026-10-14" | jq -cS '.' )" \
  '[{"end":"14:00","start":"08:00"},{"end":"22:00","start":"14:30"}]' "仅减目标日期占用"

t_begin "空闲时段计算（短于/等于最短时长边界）"
# 08:00-08:05 只有 5 分钟，短于 minResvTime=10，应被丢弃。
assert_eq "$( _booking_compute_free_slots '[{"openStartTime":"08:00","openEndTime":"08:05"}]' '[]' 5 10 "2026-10-14" | jq -cS '.' )" '[]' "5 分钟片段被丢弃"
# 08:00-08:10 恰好 10 分钟，等于 minResvTime，应保留。
assert_eq "$( _booking_compute_free_slots '[{"openStartTime":"08:00","openEndTime":"08:10"}]' '[]' 5 10 "2026-10-14" | jq -cS '.' )" '[{"end":"08:10","start":"08:00"}]' "恰好等于最短时长被保留"

# ---------------------------------------------------------------------------
# 4. 预约 body 组装（accNo 非学号、时间补 :00、resvDates/成员数组）
# ---------------------------------------------------------------------------
t_begin "预约 body 组装"
booking_session_set "deadbeefdeadbeefdeadbeefdeadbeef" "100000001" "2025211681" "/tmp/nonexistent.jar"
body="$( _booking_build_submit_body "100888915" "2026-10-14 14:00" "2026-10-14 14:30" "科研讨论" "100000001,100000002" "2" )"
assert_eq "$(printf '%s' "${body}" | jq -c '.appAccNo')" "100000001" "appAccNo 用 accNo"
assert_eq "$(printf '%s' "${body}" | jq -c '.memberKind')" "2" "多人 memberKind=2"
assert_eq "$(printf '%s' "${body}" | jq -r '.resvBeginTime')" "2026-10-14 14:00:00" "开始时间补秒"
assert_eq "$(printf '%s' "${body}" | jq -r '.resvEndTime')" "2026-10-14 14:30:00" "结束时间补秒"
assert_eq "$(printf '%s' "${body}" | jq -c '.resvMember')" "[100000001,100000002]" "resvMember 为 accNo 数组"
assert_eq "$(printf '%s' "${body}" | jq -c '.resvDev')" "[100888915]" "resvDev 数组"
assert_eq "$(printf '%s' "${body}" | jq -c '.sysKind')" "1" "sysKind=1"
assert_eq "$(printf '%s' "${body}" | jq -c '.resvKind')" "2" "resvKind=2"
assert_eq "$(printf '%s' "${body}" | jq -r '.testName')" "科研讨论" "主题透传"

t_begin "预约 body 组装（单人/空成员）"
body1="$( _booking_build_submit_body "100888915" "2026-10-14 08:00" "2026-10-14 08:30" "科研讨论" "100000001" "1" )"
assert_eq "$(printf '%s' "${body1}" | jq -c '.memberKind')" "1" "单人 memberKind=1"
assert_eq "$(printf '%s' "${body1}" | jq -c '.resvMember')" "[100000001]" "单人 resvMember 为自身 accNo"
assert_eq "$(printf '%s' "${body1}" | jq -c '.resvDev')" "[100888915]" "单人 resvDev 数组"
body2="$( _booking_build_submit_body "100888915" "2026-10-14 08:00" "2026-10-14 08:30" "科研讨论" "" "1" )"
assert_eq "$(printf '%s' "${body2}" | jq -c '.resvMember')" "[]" "空成员 -> 空数组"

# ---------------------------------------------------------------------------
# 5. 我的预约解析（epoch -> YYYY-MM-DD HH:MM，状态标签）
# ---------------------------------------------------------------------------
t_begin "我的预约解析"
OWN="$( _booking_parse_own "$(cat "${BUPTY_HOME}/tests/fixtures/booking-own.json")" )"
assert_eq "$(printf '%s' "${OWN}" | jq -cS '.')" \
  '[{"begin":"2026-10-14 14:00","devName":"朗读亭（沙河东侧）","end":"2026-10-14 14:30","status_label":"待履约","uuid":"2ea545a5bdc840218f472b34def1b8c6"}]' \
  "uuid/devName/begin/end/status_label"

# ---------------------------------------------------------------------------
# 6. 错误透传（服务器 message 原样展示；code==300 视为失效）
# ---------------------------------------------------------------------------
t_begin "错误透传与失效判定"
HTTP_STATUS=200
HTTP_BODY='{"code":1,"message":"不能连续预约","data":null}'
assert_eq "$(_booking_error_message)" "不能连续预约" "透传服务器 message"
HTTP_BODY='{"code":300,"message":"用户未登录，请重新登录","data":null}'
assert_ok _booking_is_expired
HTTP_BODY='{"code":0,"message":"成功","data":null}'
assert_fail _booking_is_expired
HTTP_STATUS=500
HTTP_BODY='{"code":1,"data":null}'
assert_eq "$(_booking_error_message)" "图书馆预约服务返回错误（HTTP 500）。" "无 message 回退 HTTP 状态"

# ---------------------------------------------------------------------------
# 7. pending_bookings 持久化往返
# ---------------------------------------------------------------------------
t_begin "待抢约持久化往返"
booking_pending_save ""
assert_eq "$(booking_pending_list)" "" "初始为空"
booking_pending_add '{"devId":"100888915","labIds":"100888904","begin":"2026-10-15 08:00","end":"2026-10-15 08:30","testName":"科研讨论","member_accnos_csv":"100000001","member_kind":"1","created_at":"2026-10-13T00:00:00+08:00"}'
booking_pending_add '{"devId":"100651195","labIds":"100651191","begin":"2026-10-15 09:00","end":"2026-10-15 10:00","testName":"学术交流","member_accnos_csv":"100000001,100000002","member_kind":"2","created_at":"2026-10-13T00:00:00+08:00"}'
assert_eq "$(_booking_pending_n "$(booking_pending_list)")" "2" "写入两条"
BUPTY_SETTINGS_JSON=""
assert_eq "$(_booking_pending_n "$(booking_pending_list)")" "2" "落盘后读回两条"
booking_pending_remove 0
assert_eq "$(_booking_pending_n "$(booking_pending_list)")" "1" "删除第一条后剩一条"
remaining="$(booking_pending_list)"
assert_eq "$(printf '%s' "${remaining}" | jq -r '.devId')" "100651195" "剩余为第二条"

t_summary

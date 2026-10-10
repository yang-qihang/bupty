#!/usr/bin/env bash
# sjd.sh —— 移动教务（jwglweixin.bupt.edu.cn）登录与数据查询。
# 课表/空教室/成绩/考试的具体拉取与解析见各自轮次，本文件提供登录、会话与请求基元。

if [[ -n "${_BUPTY_SJD_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_SJD_LOADED=1

SJD_ORIGIN="https://jwglweixin.bupt.edu.cn"
SJD_LOGIN_PAGE_URL="${SJD_ORIGIN}/sjd/#/login"
SJD_REST_CLASSROOM_PAGE_URL="${SJD_ORIGIN}/sjd/#/restClassroom"
EMPTY_CLASSROOM_LOGIN_URL="${SJD_ORIGIN}/bjyddx/login"
EMPTY_CLASSROOM_TODAY_URL="${SJD_ORIGIN}/bjyddx/todayClassrooms"
SJD_STUDENT_CURRICULUM_URL="${SJD_ORIGIN}/bjyddx/student/curriculum"
SJD_BASE="${SJD_ORIGIN}/bjyddx"

# 节次时刻表（0-based，每项 "start|end"）。
SLOT_TIMES=(
  "08:00|08:45" "08:50|09:35" "09:50|10:35" "10:40|11:25" "11:30|12:15"
  "13:00|13:45" "13:50|14:35" "14:45|15:30" "15:40|16:25" "16:35|17:20"
  "17:25|18:10" "18:30|19:15" "19:20|20:05" "20:10|20:55"
)

# 校区（id|name）。
CAMPUSES=("01|西土城" "04|沙河")

# SJD 响应是否业务成功（code == 1，数字或字符串）。
sjd_code_success() {
  local code
  code="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.code // empty' 2>/dev/null)"
  [[ "${code}" == "1" ]]
}

# SJD 响应是否认证失效（HTTP 401，或 200/500 且 code==401）。
sjd_is_expired() {
  [[ "${HTTP_STATUS}" == "401" ]] && return 0
  if [[ "${HTTP_STATUS}" == "200" || "${HTTP_STATUS}" == "500" ]]; then
    local code
    code="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.code // empty' 2>/dev/null)"
    [[ "${code}" == "401" ]] && return 0
  fi
  return 1
}

# 从 SJD 响应取错误消息。
sjd_error_message() {
  local msg
  msg="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.Msg // .msg // empty' 2>/dev/null)"
  if [[ -z "${msg}" || "${msg}" == "null" ]]; then
    msg="移动教务服务返回错误（HTTP ${HTTP_STATUS}）。"
  fi
  printf '%s' "${msg}"
}

# 登录：POST /bjyddx/login。成功缓存 token 到会话。返回 0/1。
sjd_login() {
  local account="$1" password="$2"
  sjd_session_clear
  http_request --max-time 20 \
    -H "Origin: ${SJD_ORIGIN}" \
    -H "Referer: ${SJD_LOGIN_PAGE_URL}" \
    -H "User-Agent: Mozilla/5.0" \
    --data-urlencode "userNo=${account}" \
    --data-urlencode "pwd=${password}" \
    "${EMPTY_CLASSROOM_LOGIN_URL}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接教务服务，请确认网络能访问 jwglweixin.bupt.edu.cn。"
    return 1
  fi
  if ! sjd_code_success; then
    core_err "$(sjd_error_message)"
    return 1
  fi
  local token
  token="$(printf '%s' "${HTTP_BODY}" | jq -r '.data.token // empty' 2>/dev/null)"
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    core_err "教务服务登录成功但未返回 token。"
    return 1
  fi
  sjd_session_set "${token}" "${account}"
  return 0
}

# 确保有当前账号的有效令牌，返回令牌或空（失败置 BUPTY_ERR）。
sjd_ensure_token() {
  local account="$1" password="$2"
  if sjd_session_owned_by "${account}"; then
    printf '%s' "$(sjd_session_get)"
    return 0
  fi
  if sjd_login "${account}" "${password}"; then
    printf '%s' "$(sjd_session_get)"
    return 0
  fi
  return 1
}

# 通用认证请求（带 token + 公共头）。用法：sjd_authed_request <METHOD> <URL> [curl 额外参数...]
sjd_authed_request() {
  local method="$1" url="$2"
  shift 2
  local token
  token="$(sjd_session_get)"
  http_request --max-time 30 \
    -H "Origin: ${SJD_ORIGIN}" \
    -H "Referer: ${SJD_REST_CLASSROOM_PAGE_URL}" \
    -H "User-Agent: Mozilla/5.0" \
    ${token:+-H "token: ${token}"} \
    -X "${method}" "$@" "${url}"
}

# 拉取 SJD JSON 并校验 code==1；若认证失效则清会话重登并重试一次。
# 成功时 HTTP_BODY 为有效 payload，返回 0；失败置 BUPTY_ERR 返回 1。
sjd_request_json() {
  local method="$1" url="$2" account="$3" password="$4"
  local attempt
  for attempt in 1 2; do
    sjd_authed_request "${method}" "${url}"
    if [[ "${HTTP_STATUS}" == "000" ]]; then
      core_err "无法连接教务服务，请确认网络能访问 jwglweixin.bupt.edu.cn。"
      return 1
    fi
    if sjd_code_success; then
      return 0
    fi
    if ! sjd_is_expired; then
      core_err "$(sjd_error_message)"
      return 1
    fi
    # 失效：清会话、重登、重试一次。
    sjd_session_clear
    if ! sjd_login "${account}" "${password}"; then
      return 1
    fi
  done
  core_err "移动教务请求失败。"
  return 1
}

# ---------------------------------------------------------------------------
# 课表（student/curriculum）
# ---------------------------------------------------------------------------

# 算法 A：从当前周 payload 推断学期号。输出 term_id。
sjd_infer_term_id() {
  local payload="$1"
  local root
  root="$(printf '%s' "${payload}" | jq -c '.data[0] // {}' 2>/dev/null || true)"
  local cand term_id
  if [[ -n "${root}" && "${root}" != "{}" ]]; then
    for cand in ".semesterId" ".xnxq01id" ".topInfo[0].semesterId" ".topInfo[0].xnxq01id"; do
      term_id="$(printf '%s' "${root}" | jq -r "${cand} // empty" 2>/dev/null || true)"
      term_id="$(core_trim "${term_id}")"
      if [[ -n "${term_id}" && "${term_id}" != "null" ]]; then
        printf '%s' "${term_id}"
        return 0
      fi
    done
  fi
  # 全空回退：按今天日期推断学期号。
  term_id="$(parse_suggested_term "$(core_today)")"
  printf '%s' "${term_id%% *}"
}

# 算法 B：从当前周 payload 推断开学第一周周一。输出 term_start_date。
sjd_infer_term_start_date() {
  local payload="$1"
  local root
  root="$(printf '%s' "${payload}" | jq -c '.data[0] // {}' 2>/dev/null || true)"
  local dated
  dated="$(printf '%s' "${root}" | jq -c '[.date[]? | select((( .mxrq // "") != "") and ((.zc // "") != "all"))][0] // empty' 2>/dev/null || true)"
  if [[ -z "${dated}" || "${dated}" == "null" ]]; then
    printf '%s' "$(_sjd_term_start_fallback)"
    return 0
  fi
  local day week weekday
  day="$(printf '%s' "${dated}" | jq -r '.mxrq // empty' 2>/dev/null || true)"
  week="$(printf '%s' "${dated}" | jq -r '.zc // empty' 2>/dev/null || true)"
  weekday="$(printf '%s' "${dated}" | jq -r '.xqid // empty' 2>/dev/null || true)"
  # 周次缺失时回退 data[0].week / topInfo[0].week。
  if ! [[ "${week}" =~ ^[0-9]+$ ]]; then
    week="$(printf '%s' "${root}" | jq -r '.week // empty' 2>/dev/null || true)"
    if ! [[ "${week}" =~ ^[0-9]+$ ]]; then
      week="$(printf '%s' "${root}" | jq -r '.topInfo[0].week // empty' 2>/dev/null || true)"
    fi
  fi
  local week_num=-1
  if [[ "${week}" =~ ^[0-9]+$ ]]; then
    week_num=$((10#$week))
  fi
  if [[ -z "${day}" ]] || (( week_num < 0 )); then
    printf '%s' "$(_sjd_term_start_fallback)"
    return 0
  fi
  # 星期：0 视为周日（7），1..7 原样，失败用 core_weekday。
  local weekday_num
  if [[ "${weekday}" =~ ^[0-9]+$ ]]; then
    weekday_num=$((10#$weekday))
    (( weekday_num == 0 )) && weekday_num=7
  else
    weekday_num="$(core_weekday "${day}")"
  fi
  # 越界（>7 等）视为无效，回退按日期自身星期。
  (( weekday_num < 1 || weekday_num > 7 )) && weekday_num="$(core_weekday "${day}")"
  local monday
  monday="$(date -d "${day} - $((weekday_num - 1)) days" +%Y-%m-%d 2>/dev/null || true)"
  if [[ -z "${monday}" ]]; then
    printf '%s' "$(_sjd_term_start_fallback)"
    return 0
  fi
  # 开学周一 = 周一 - (week_num - 1) 周；避免 date 对「双负号」的歧义解析，显式分支。
  local offset=$(( (week_num - 1) * 7 ))
  if (( offset >= 0 )); then
    date -d "${monday} - ${offset} days" +%Y-%m-%d 2>/dev/null || printf '%s' "$(_sjd_term_start_fallback)"
  else
    date -d "${monday} + $(( -offset )) days" +%Y-%m-%d 2>/dev/null || printf '%s' "$(_sjd_term_start_fallback)"
  fi
}

# 开学日期兜底：按今天日期推断（取 parse_suggested_term 的 start_date）。
_sjd_term_start_fallback() {
  local fb
  fb="$(parse_suggested_term "$(core_today)")"
  printf '%s' "${fb##* }"
}

# 当前周数：今天相对开学第一周周一，floor((today - start)/7) + 1。
sjd_compute_current_week() {
  local term_start_date="$1"
  local days
  days="$(core_days_between "$(core_today)" "${term_start_date}")"
  if (( days >= 0 )); then
    printf '%s' "$(( days / 7 + 1 ))"
  else
    printf '%s' "$(( 1 - ( ( -days + 6 ) / 7 ) ))"
  fi
}

# 稳定 ID 兜底哈希（sha1sum，缺失用 md5sum），取前 12 位。
_sjd_stable_id() {
  local stable="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "${stable}" | sha1sum | cut -c1-12
  else
    printf '%s' "${stable}" | md5sum | cut -c1-12
  fi
}

# 解析单个课程对象（已由 jq 提取的 JSON），输出课程 JSON 或空（丢弃）。
_sjd_parse_course() {
  local obj="$1"
  local classWeek classWeekDetails classTime weekNoteDetail weekDay courseName teacherName buildingName classroomName location startTime endTime jx0408id
  classWeek="$(printf '%s' "${obj}" | jq -r '.classWeek // empty' 2>/dev/null || true)"
  classWeekDetails="$(printf '%s' "${obj}" | jq -r '.classWeekDetails // empty' 2>/dev/null || true)"
  classTime="$(printf '%s' "${obj}" | jq -r '.classTime // empty' 2>/dev/null || true)"
  weekNoteDetail="$(printf '%s' "${obj}" | jq -r '.weekNoteDetail // empty' 2>/dev/null || true)"
  weekDay="$(printf '%s' "${obj}" | jq -r '.weekDay // empty' 2>/dev/null || true)"
  courseName="$(printf '%s' "${obj}" | jq -r '.courseName // empty' 2>/dev/null || true)"
  teacherName="$(printf '%s' "${obj}" | jq -r '.teacherName // empty' 2>/dev/null || true)"
  buildingName="$(printf '%s' "${obj}" | jq -r '.buildingName // empty' 2>/dev/null || true)"
  classroomName="$(printf '%s' "${obj}" | jq -r '.classroomName // empty' 2>/dev/null || true)"
  location="$(printf '%s' "${obj}" | jq -r '.location // empty' 2>/dev/null || true)"
  startTime="$(printf '%s' "${obj}" | jq -r '.startTime // empty' 2>/dev/null || true)"
  endTime="$(printf '%s' "${obj}" | jq -r '.endTIme // .endTime // empty' 2>/dev/null || true)"
  jx0408id="$(printf '%s' "${obj}" | jq -r '.jx0408id // empty' 2>/dev/null || true)"

  # 周次文本：优先 classWeek，否则 classWeekDetails。
  local week_text
  week_text="${classWeek}"
  [[ -z "$(core_trim "${week_text}")" ]] && week_text="${classWeekDetails}"

  # 周次数字（bash 数组）。
  local -a week_numbers=()
  local wn
  # 注意 parse_sjd_week_numbers 末行无换行，需用 || [[ -n ]] 兜底读取最后一行。
  while IFS= read -r wn || [[ -n "${wn}" ]]; do [[ -n "${wn}" ]] && week_numbers+=("${wn}"); done < <(parse_sjd_week_numbers "${classWeek}" "${classWeekDetails}")

  # 节次区间（0-based），解析失败丢弃。
  local slots start_slot end_slot
  slots="$(parse_sjd_slots "${classTime}" "${weekNoteDetail}")"
  [[ -z "${slots}" ]] && return 0
  read -r start_slot end_slot <<< "${slots}"

  # 星期：weekDay，回退 classTime 首字符，必须 1..7。
  local weekday_raw weekday
  weekday_raw="$(printf '%s' "${weekDay}" | tr -d '[:space:]')"
  if ! [[ "${weekday_raw}" =~ ^[0-9]+$ ]]; then
    weekday_raw="$(printf '%s' "${classTime}" | grep -oE '^[0-9]' || true)"
  fi
  [[ "${weekday_raw}" =~ ^[0-9]+$ ]] || return 0
  weekday="$((10#$weekday_raw))"
  if (( weekday < 1 || weekday > 7 )); then return 0; fi

  # 名称 / 教师。
  local name teacher
  name="$(core_trim "${courseName}")"
  [[ -z "${name}" ]] && name="未命名课程"
  teacher="$(core_trim "${teacherName}")"

  # 教室：building + 归一房间 → location。
  local building room location_val room_raw
  building="$(core_trim "${buildingName}")"
  room_raw="${classroomName:-${location}}"
  room="$(parse_normalize_room "${room_raw}")"
  room="$(core_trim "${room}")"
  if [[ -n "${building}" && -n "${room}" ]]; then
    if [[ "${room}" != *"${building}"* ]]; then
      location_val="${building}-${room}"
    else
      location_val="${room}"
    fi
  elif [[ -n "${room}" ]]; then
    location_val="${room}"
  else
    location_val="${building}"
  fi

  # 起止时刻与区间。
  local start_time end_time time_range
  start_time="$(core_trim "${startTime}")"
  end_time="$(core_trim "${endTime}")"
  if [[ -n "${start_time}" && -n "${end_time}" ]]; then
    time_range="${start_time}-${end_time}"
  else
    time_range="${SLOT_TIMES[${start_slot}]%%|*}-${SLOT_TIMES[${end_slot}]##*|}"
  fi

  # 节次文本。
  local section_text
  if [[ "${start_slot}" == "${end_slot}" ]]; then
    section_text="$((start_slot + 1))节"
  else
    section_text="$((start_slot + 1))-$((end_slot + 1))节"
  fi

  # 源课程 ID 与稳定 ID。
  local source_course_id id stable
  source_course_id="$(core_trim "${jx0408id}")"
  if [[ -n "${source_course_id}" ]]; then
    id="${source_course_id}"
  else
    stable="${jx0408id}|${name}|${teacher}|${location_val}|${week_text}|${weekday}|${start_slot}|${end_slot}"
    id="$(_sjd_stable_id "${stable}")"
  fi

  # 周次数字转 JSON 数组。
  local week_json="["
  local i=0 w
  for w in "${week_numbers[@]}"; do
    if (( i > 0 )); then week_json+=","; fi
    week_json+="${w}"
    i=$((i + 1))
  done
  week_json+="]"

  jq -n \
    --arg id "${id}" \
    --arg name "${name}" \
    --arg teacher "${teacher}" \
    --arg room "${location_val}" \
    --arg week_text "${week_text}" \
    --argjson week_numbers "${week_json}" \
    --argjson weekday "${weekday}" \
    --argjson start_slot "${start_slot}" \
    --argjson end_slot "${end_slot}" \
    --arg section_text "${section_text}" \
    --arg time_range "${time_range}" \
    '{id:$id, name:$name, teacher:$teacher, room:$room, week_text:$week_text, week_numbers:$week_numbers, weekday:$weekday, start_slot:$start_slot, end_slot:$end_slot, section_text:$section_text, time_range:$time_range}'
}

# 算法 C：从 week=all payload 解析课程数组（按 weekday/start_slot/name 升序、id 去重）。输出 JSON 数组。
sjd_parse_schedule_courses() {
  local payload="$1"
  local tmp
  tmp="$(mktemp)"
  local -A seen=()
  local line obj cid
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    obj="$(_sjd_parse_course "${line}")"
    [[ -z "${obj}" ]] && continue
    cid="$(printf '%s' "${obj}" | jq -r '.id // empty' 2>/dev/null || true)"
    if [[ -n "${cid}" && -z "${seen[${cid}]:-}" ]]; then
      seen[${cid}]=1
      printf '%s\n' "${obj}" >> "${tmp}"
    fi
  done < <(printf '%s' "${payload}" | jq -c '.. | objects | select(has("courseName") or has("jx0408id"))' 2>/dev/null)
  local out
  out="$(jq -s -c 'sort_by(.weekday, .start_slot, .name)' "${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}"
  if [[ -z "${out}" ]]; then out="[]"; fi
  printf '%s' "${out}"
}

# 拉取并解析课表。成功输出 JSON 对象到 stdout，失败返回 1 并置 BUPTY_ERR。
sjd_fetch_schedule() {
  local account="$1" password="$2"
  if core_is_blank "${account}" || core_is_blank "${password}"; then
    core_err "请先在设置中登录。"
    return 1
  fi
  if ! sjd_ensure_token "${account}" "${password}" >/dev/null; then
    return 1
  fi

  # 当前周 payload。
  if ! sjd_request_json POST "${SJD_STUDENT_CURRICULUM_URL}?week=" "${account}" "${password}"; then
    return 1
  fi
  local current_payload="${HTTP_BODY}"

  # 全学期 payload。
  if ! sjd_request_json POST "${SJD_STUDENT_CURRICULUM_URL}?week=all" "${account}" "${password}"; then
    return 1
  fi
  local all_payload="${HTTP_BODY}"

  local term_id term_start_date current_week courses
  term_id="$(sjd_infer_term_id "${current_payload}")"
  term_start_date="$(sjd_infer_term_start_date "${current_payload}")"
  current_week="$(sjd_compute_current_week "${term_start_date}")"
  courses="$(sjd_parse_schedule_courses "${all_payload}")"

  jq -n \
    --arg term_id "${term_id}" \
    --arg term_start_date "${term_start_date}" \
    --argjson current_week "${current_week}" \
    --argjson courses "${courses}" \
    '{term_id:$term_id, term_start_date:$term_start_date, current_week:$current_week, courses:$courses}'
}

# ---------------------------------------------------------------------------
# 空教室（todayClassrooms）
# ---------------------------------------------------------------------------

# 解析单个校区的空教室 payload，输出房间 JSON 数组（按 building/room 升序）。
_sjd_parse_classrooms_payload() {
  local payload="$1"
  local tmp
  tmp="$(mktemp)"
  local line nodename classrooms slot
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    # 学校接口字段大小写不统一（NODENAME/nodeName/nodename、CLASSROOMS/classrooms/Classrooms），
    # 统一转大写键后取值。
    nodename="$(printf '%s' "${line}" | jq -r 'to_entries | map({key:(.key|ascii_upcase), value:.value}) | from_entries | .NODENAME // empty' 2>/dev/null || true)"
    classrooms="$(printf '%s' "${line}" | jq -r 'to_entries | map({key:(.key|ascii_upcase), value:.value}) | from_entries | .CLASSROOMS // empty' 2>/dev/null || true)"
    slot="$(parse_node_to_slot "${nodename}")"
    [[ -z "${slot}" ]] && continue

    local room_raw parsed building_raw room_size
    local -a room_list=()
    local IFS=,
    read -ra room_list <<< "${classrooms}"
    for room_raw in "${room_list[@]}"; do
      room_raw="$(core_trim "${room_raw}")"
      [[ -z "${room_raw}" ]] && continue
      parsed="$(parse_classroom "${room_raw}")"
      [[ -z "${parsed}" ]] && continue
      IFS='|' read -r building_raw room_raw room_size <<< "${parsed}"

      local building
      building="$(parse_building_name "${building_raw}")"
      local side_out
      side_out="$(parse_teaching_experiment_side "${building}" "${room_raw}")"
      building="${side_out%%|*}"
      room_raw="${side_out#*|}"
      if [[ "$(parse_original_building "${building}")" != "0" ]]; then
        continue
      fi

      local room size_json
      room="$(parse_extract_room_name "${room_raw}" "${building}")"
      [[ -z "${room}" ]] && continue
      if [[ -n "${room_size}" ]]; then
        size_json="${room_size}"
      else
        size_json="null"
      fi
      jq -n --arg building "${building}" --arg room "${room}" --argjson size "${size_json}" --argjson slot "${slot}" \
        '{building:$building, room:$room, size:$size, slot:$slot}' >> "${tmp}" 2>/dev/null || true
    done
  done < <(printf '%s' "${payload}" | jq -c '.data[]?' 2>/dev/null || true)

  local out
  out="$(jq -s '
    reduce .[] as $r ({};
      .[$r.building + "-" + $r.room] |= (
        if . == null then
          {building: $r.building, room: $r.room, size: $r.size, slots: [$r.slot]}
        else
          {building: $r.building, room: $r.room,
           size: (if .size != null then .size else $r.size end),
           slots: (.slots + [$r.slot])}
        end
      )
    )
    | to_entries | map(.value)
    | map({building, room, size, available_slots: (.slots | unique | sort)})
    | sort_by(.building, .room)
  ' "${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}"
  [[ -z "${out}" ]] && out="[]"
  printf '%s' "${out}"
}

# 拉取并解析两校区空教室。成功输出 JSON 对象到 stdout，失败返回 1 并置 BUPTY_ERR。
sjd_fetch_classrooms() {
  local account="$1" password="$2"
  if core_is_blank "${account}" || core_is_blank "${password}"; then
    core_err "请先在设置中登录。"
    return 1
  fi
  if ! sjd_ensure_token "${account}" "${password}" >/dev/null; then
    return 1
  fi

  local -a campus_ids=() campus_names=() campus_payloads=()
  local entry id name
  for entry in "${CAMPUSES[@]}"; do
    id="${entry%%|*}"; name="${entry#*|}"
    if ! sjd_request_json GET "${EMPTY_CLASSROOM_TODAY_URL}?campusId=${id}" "${account}" "${password}"; then
      return 1
    fi
    campus_ids+=("${id}")
    campus_names+=("${name}")
    campus_payloads+=("${HTTP_BODY}")
  done

  local i rooms
  local campuses_json="["
  for i in "${!campus_ids[@]}"; do
    rooms="$(_sjd_parse_classrooms_payload "${campus_payloads[$i]}")"
    if (( i > 0 )); then campuses_json+=","; fi
    campuses_json+="$(jq -cn --arg id "${campus_ids[$i]}" --arg name "${campus_names[$i]}" --argjson rooms "${rooms}" \
      '{campus_id:$id, campus_name:$name, rooms:$rooms}')"
  done
  campuses_json+="]"

  jq -n \
    --arg target_date "$(core_today)" \
    --argjson campuses "${campuses_json}" \
    '{target_date:$target_date, campuses:$campuses}'
}

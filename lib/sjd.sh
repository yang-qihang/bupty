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

# 确保有当前账号的有效令牌（token 存会话全局，不向 stdout 输出，避免泄漏）。
# 成功返回 0，失败置 BUPTY_ERR 返回 1。
sjd_ensure_token() {
  local account="$1" password="$2"
  if sjd_session_owned_by "${account}"; then
    return 0
  fi
  if sjd_login "${account}" "${password}"; then
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

  # 1. 收集所有唯一房间字符串（一次 jq + sort -u），避免逐节次重复解析同一房间。
  # 字段大小写不统一（CLASSROOMS/classrooms/Classrooms），统一转大写键后取值。
  local all_rooms
  all_rooms="$(printf '%s' "${payload}" | jq -r '[.data[]? | to_entries | map({key:(.key|ascii_upcase), value:.value}) | from_entries | .CLASSROOMS // empty] | join(",")' 2>/dev/null \
    | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort -u)"

  # 2. 解析每个唯一房间（一次），构建 "原始串 → building\x1froom\x1fsize" 映射。
  local -A room_map=()
  local r parsed b room sz building side rn
  while IFS= read -r r; do
    [[ -z "${r}" ]] && continue
    parsed="$(parse_classroom "${r}")"
    [[ -z "${parsed}" ]] && continue
    IFS='|' read -r b room sz <<< "${parsed}"
    building="$(parse_building_name "${b}")"
    side="$(parse_teaching_experiment_side "${building}" "${room}")"
    building="${side%%|*}"; room="${side#*|}"
    [[ "$(parse_original_building "${building}")" != "0" ]] && continue
    rn="$(parse_extract_room_name "${room}" "${building}")"
    [[ -z "${rn}" ]] && continue
    room_map["${r}"]="${building}"$'\x1f'"${rn}"$'\x1f'"${sz:-}"
  done <<< "${all_rooms}"

  # 3. 逐节次遍历，内联 trim 后查映射，写 TSV（building\x1froom\x1fsize\x1fslot）。
  local tmp
  tmp="$(mktemp)"
  local line nodename classrooms slot
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    nodename="$(printf '%s' "${line}" | jq -r 'to_entries | map({key:(.key|ascii_upcase), value:.value}) | from_entries | .NODENAME // empty' 2>/dev/null || true)"
    classrooms="$(printf '%s' "${line}" | jq -r 'to_entries | map({key:(.key|ascii_upcase), value:.value}) | from_entries | .CLASSROOMS // empty' 2>/dev/null || true)"
    slot="$(parse_node_to_slot "${nodename}")"
    [[ -z "${slot}" ]] && continue
    local -a room_list=()
    local IFS=,
    read -ra room_list <<< "${classrooms}"
    local room_raw key
    for room_raw in "${room_list[@]}"; do
      room_raw="${room_raw#"${room_raw%%[![:space:]]*}"}"
      room_raw="${room_raw%"${room_raw##*[![:space:]]}"}"
      [[ -z "${room_raw}" ]] && continue
      key="${room_map[${room_raw}]:-}"
      [[ -z "${key}" ]] && continue
      printf '%s\x1f%s\n' "${key}" "${slot}" >> "${tmp}"
    done
  done < <(printf '%s' "${payload}" | jq -c '.data[]?' 2>/dev/null || true)

  # 4. 单次 jq 聚合、去重、排序。
  local out
  out="$(jq -R -s -c '
    split("\n") | map(select(. != ""))
    | map(split("\u001f"))
    | map({building: .[0], room: .[1],
           size: (if .[2] == "" then null else (.[2] | tonumber) end),
           slot: (.[3] | tonumber)})
    | group_by([.building, .room])
    | map({building: .[0].building, room: .[0].room,
           size: ([.[].size] | map(select(. != null)) | .[0] // null),
           available_slots: ([.[].slot] | unique | sort)})
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

# ---------------------------------------------------------------------------
# 成绩与学期（currentTerm / semesterList / student/termGPA）
# ---------------------------------------------------------------------------

# 校验学期号安全（字母数字 + -_，长度 1..64），防止畸形值拼进 URL。
_sjd_valid_term() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

# 解析学期列表 payload（semesterList），去重、name 空则用 id。输出 JSON 数组。
_sjd_parse_terms_list() {
  local list_payload="$1"
  local out
  out="$(printf '%s' "${list_payload}" | jq -c '
    [.data[]? | {id: ((.semesterId // "") | tostring), name: ((.semesterName // "") | tostring)}]
    | map(.id |= gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | map(.name |= gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | map(if .name == "" then .name = .id else . end)
    | map(select(.id != ""))
    | group_by(.id) | map(.[0])
  ' 2>/dev/null || true)"
  if [[ -z "${out}" ]]; then out="[]"; fi
  printf '%s' "${out}"
}

# 解析当前学期 + 学期列表为 {"current_term_id", "terms":[{id,name}]}。失败置 BUPTY_ERR 返回 1。
sjd_parse_grade_terms() {
  local current_payload="$1" list_payload="$2"
  local current_term_id
  current_term_id="$(printf '%s' "${current_payload}" | jq -r '.data[0].semesterId // empty' 2>/dev/null || true)"
  current_term_id="$(core_trim "${current_term_id}")"
  if core_is_blank "${current_term_id}"; then
    core_err "教务未返回当前学期。"
    return 1
  fi
  local terms_json has_current
  terms_json="$(_sjd_parse_terms_list "${list_payload}")"
  has_current="$(printf '%s' "${terms_json}" | jq --arg t "${current_term_id}" 'any(.id == $t)' 2>/dev/null || true)"
  if [[ "${has_current}" != "true" ]]; then
    terms_json="$(printf '%s' "${terms_json}" | jq -c --arg t "${current_term_id}" '[{id:$t, name:$t}] + .' 2>/dev/null || true)"
  fi
  # 排序：当前学期在前，接着过去的学期（按 id 降序，最近在前），再是未来学期（升序）。
  # 这样 t（下一个）先从当前往后走历史学期，方便查过往成绩。
  jq -n --arg t "${current_term_id}" --argjson terms "${terms_json}" '
    { current_term_id: $t,
      terms: (($terms | map(select(.id == $t)))
              + ($terms | map(select(.id < $t)) | sort_by(.id) | reverse)
              + ($terms | map(select(.id > $t)) | sort_by(.id))) }
  '
}

# 解析成绩 payload（student/termGPA）为 {"term_id","record_type","average_grade_point","items":[...]}。
# fraction/credit 可能是数字或字符串，一律转字符串保留原值；courseName 空则报错。
sjd_parse_grades() {
  local payload="$1" term="$2" record_type="$3"
  case "${record_type}" in
    0|1|"") ;;
    *) core_err "成绩记录类型不正确。"; return 1 ;;
  esac
  local avg
  avg="$(printf '%s' "${payload}" | jq -r '(.data[0].pjxfjd // null) | if . == null then "" else tostring end' 2>/dev/null || true)"
  avg="$(core_trim "${avg}")"

  local tmp
  tmp="$(mktemp)"
  local -A seen=()
  local line name rid id
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    name="$(printf '%s' "${line}" | jq -r '.name // ""' 2>/dev/null || true)"
    name="$(core_trim "${name}")"
    if [[ -z "${name}" ]]; then
      rm -f "${tmp}"
      core_err "成绩课程名称缺失。"
      return 1
    fi
    rid="$(printf '%s' "${line}" | jq -r '.rid // ""' 2>/dev/null || true)"
    rid="$(core_trim "${rid}")"
    if [[ -n "${rid}" ]]; then
      id="${rid}"
    else
      local score credits course_code course_attribute course_nature exam_nature semester_name grade_status
      score="$(printf '%s' "${line}" | jq -r '.score // ""' 2>/dev/null || true)"
      credits="$(printf '%s' "${line}" | jq -r '.credits // ""' 2>/dev/null || true)"
      course_code="$(printf '%s' "${line}" | jq -r '.course_code // ""' 2>/dev/null || true)"
      course_attribute="$(printf '%s' "${line}" | jq -r '.course_attribute // ""' 2>/dev/null || true)"
      course_nature="$(printf '%s' "${line}" | jq -r '.course_nature // ""' 2>/dev/null || true)"
      exam_nature="$(printf '%s' "${line}" | jq -r '.exam_nature // ""' 2>/dev/null || true)"
      semester_name="$(printf '%s' "${line}" | jq -r '.semester_name // ""' 2>/dev/null || true)"
      grade_status="$(printf '%s' "${line}" | jq -r '.grade_status // ""' 2>/dev/null || true)"
      id="$(_sjd_stable_id "${name}|${course_code}|${score}|${credits}|${course_attribute}|${course_nature}|${exam_nature}|${semester_name}|${grade_status}")"
    fi
    if [[ -n "${id}" && -z "${seen[${id}]:-}" ]]; then
      seen[${id}]=1
      printf '%s\n' "$(printf '%s' "${line}" | jq -c --arg id "${id}" --arg name "${name}" 'del(.rid) | .id = $id | .name = $name' 2>/dev/null || true)" >> "${tmp}"
    fi
  done < <(printf '%s' "${payload}" | jq -c '
    def tostr: if . == null then "" else tostring end;
    def trimstr: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    .data[0].achievement[]?
    | {
        rid: (.cj0708id | tostr | trimstr),
        name: (.courseName | tostr | trimstr),
        score: (.fraction | tostr),
        credits: (.credit | tostr),
        course_code: (.kcbh | tostr | trimstr),
        course_attribute: (.curriculumAttributes | tostr | trimstr),
        course_nature: (.courseNature | tostr | trimstr),
        exam_nature: (.examinationNature | tostr | trimstr),
        semester_name: (.curSemesterName | tostr | trimstr),
        grade_status: (.cjbs | tostr | trimstr)
      }
  ' 2>/dev/null || true)

  local items
  items="$(jq -s -c '.' "${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}"
  if [[ -z "${items}" ]]; then items="[]"; fi
  jq -n --arg t "${term}" --arg rt "${record_type}" --arg avg "${avg}" --argjson items "${items}" \
    '{term_id:$t, record_type:$rt, average_grade_point:$avg, items:$items}'
}

# 拉取并解析学期列表。成功输出 JSON 对象到 stdout，失败返回 1 并置 BUPTY_ERR。
sjd_fetch_grade_terms() {
  local account="$1" password="$2"
  if core_is_blank "${account}" || core_is_blank "${password}"; then
    core_err "请先在设置中登录。"
    return 1
  fi
  if ! sjd_ensure_token "${account}" "${password}" >/dev/null; then
    return 1
  fi
  if ! sjd_request_json POST "${SJD_BASE}/currentTerm" "${account}" "${password}"; then
    return 1
  fi
  local current_payload="${HTTP_BODY}"
  if ! sjd_request_json POST "${SJD_BASE}/semesterList" "${account}" "${password}"; then
    return 1
  fi
  local list_payload="${HTTP_BODY}"
  if ! sjd_parse_grade_terms "${current_payload}" "${list_payload}"; then
    return 1
  fi
}

# 拉取并解析指定学期/记录类型的成绩。record_type：0=首次、1=最好、""=全部。
sjd_fetch_grades() {
  local account="$1" password="$2" term_id="$3" record_type="$4"
  if core_is_blank "${account}" || core_is_blank "${password}"; then
    core_err "请先在设置中登录。"
    return 1
  fi
  if ! _sjd_valid_term "${term_id}"; then
    core_err "请选择学校返回的有效学期。"
    return 1
  fi
  case "${record_type}" in
    0|1|"") ;;
    *) core_err "成绩记录类型不正确。"; return 1 ;;
  esac
  if ! sjd_ensure_token "${account}" "${password}" >/dev/null; then
    return 1
  fi
  if ! sjd_request_json POST "${SJD_BASE}/student/termGPA?semester=${term_id}&type=${record_type}" "${account}" "${password}"; then
    return 1
  fi
  if ! sjd_parse_grades "${HTTP_BODY}" "${term_id}" "${record_type}"; then
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 考试安排（student/examinationArrangement）
# ---------------------------------------------------------------------------

# 校验 YYYY-MM-DD 真实日期（1900..2200）。
_sjd_valid_date() {
  local v="$1"
  [[ "${v}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  local y="${v:0:4}"
  (( 10#$y >= 1900 && 10#$y <= 2200 )) || return 1
  [[ "$(date -d "${v}" +%Y-%m-%d 2>/dev/null)" == "${v}" ]]
}

# 解析考试 payload（examinationArrangement）为 {"term_id","items":[{id,name,date,start_time,end_time,room,time_text}]}。
# time 用 parse_exam_time 解析；time 为空时回退 ksqssj/zssj1/zssj2 三字段；courseName 空则报错。
sjd_parse_exams() {
  local payload="$1" term="$2"
  local tmp
  tmp="$(mktemp)"
  local -A seen=()
  local line name room time_text
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    name="$(printf '%s' "${line}" | jq -r '.courseName // ""' 2>/dev/null || true)"
    name="$(core_trim "${name}")"
    if [[ -z "${name}" ]]; then
      rm -f "${tmp}"
      core_err "考试课程名称缺失。"
      return 1
    fi
    room="$(printf '%s' "${line}" | jq -r '.examinationPlace // ""' 2>/dev/null || true)"
    room="$(core_trim "${room}")"
    time_text="$(printf '%s' "${line}" | jq -r '.time // ""' 2>/dev/null || true)"
    time_text="$(core_trim "${time_text}")"

    local aux=""
    if [[ -z "${time_text}" ]]; then
      local ksqssj zssj1 zssj2 sm em
      ksqssj="$(printf '%s' "${line}" | jq -r '.ksqssj // ""' 2>/dev/null || true)"
      zssj1="$(printf '%s' "${line}" | jq -r '.zssj1 // ""' 2>/dev/null || true)"
      zssj2="$(printf '%s' "${line}" | jq -r '.zssj2 // ""' 2>/dev/null || true)"
      ksqssj="$(core_trim "${ksqssj}")"; zssj1="$(core_trim "${zssj1}")"; zssj2="$(core_trim "${zssj2}")"
      # 三字段都合法且 start<end 时用它们作为日期/起止时刻。
      if _sjd_valid_date "${ksqssj}" && [[ "${zssj1}" =~ ^[0-9]{2}:[0-9]{2}$ && "${zssj2}" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
        sm="$(parse_minutes "${zssj1}" 2>/dev/null)" || sm=""
        em="$(parse_minutes "${zssj2}" 2>/dev/null)" || em=""
        if [[ -n "${sm}" && -n "${em}" ]] && (( sm < em && sm < 1440 )); then
          aux="${ksqssj}|${zssj1}|${zssj2}"
        fi
      fi
      time_text="$(core_trim "${ksqssj} ${zssj1} ${zssj2}")"
    fi

    local date start_time end_time parsed
    if [[ -n "${aux}" ]]; then
      IFS='|' read -r date start_time end_time <<< "${aux}"
    else
      parsed="$(parse_exam_time "${time_text}")"
      IFS='|' read -r date start_time end_time <<< "${parsed}"
    fi

    local id
    id="$(_sjd_stable_id "${name}|${date}|${start_time}|${end_time}|${room}|${time_text}")"
    if [[ -z "${seen[${id}]:-}" ]]; then
      seen[${id}]=1
      jq -n --arg id "${id}" --arg name "${name}" --arg date "${date}" --arg s "${start_time}" --arg e "${end_time}" --arg room "${room}" --arg t "${time_text}" \
        '{id:$id, name:$name, date:$date, start_time:$s, end_time:$e, room:$room, time_text:$t}' >> "${tmp}" 2>/dev/null || true
    fi
  done < <(printf '%s' "${payload}" | jq -c '.data[]?' 2>/dev/null || true)

  local items
  items="$(jq -s -c '.' "${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}"
  if [[ -z "${items}" ]]; then items="[]"; fi
  jq -n --arg t "${term}" --argjson items "${items}" '{term_id:$t, items:$items}'
}

# 拉取并解析指定学期考试安排。成功输出 JSON 对象到 stdout，失败返回 1 并置 BUPTY_ERR。
sjd_fetch_exams() {
  local account="$1" password="$2" term_id="$3"
  if core_is_blank "${account}" || core_is_blank "${password}"; then
    core_err "请先在设置中登录。"
    return 1
  fi
  if ! _sjd_valid_term "${term_id}"; then
    core_err "请选择学校返回的有效学期。"
    return 1
  fi
  if ! sjd_ensure_token "${account}" "${password}" >/dev/null; then
    return 1
  fi
  if ! sjd_request_json POST "${SJD_BASE}/student/examinationArrangement?semester=${term_id}" "${account}" "${password}"; then
    return 1
  fi
  if ! sjd_parse_exams "${HTTP_BODY}" "${term_id}"; then
    return 1
  fi
}

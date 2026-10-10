#!/usr/bin/env bash
# parse.sh —— 纯解析函数（无网络、无副作用），便于单元测试。
# 与参考仓库 src-tauri/src/{schedule,classrooms,academic,config}.rs 逻辑对齐。

if [[ -n "${_BUPTY_PARSE_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_PARSE_LOADED=1

# ---------------------------------------------------------------------------
# 周次展开
# ---------------------------------------------------------------------------

# 展开周次文本（如 "1-18"、"2-18双"、"1,3,5"、"第1周,第3周"），每行一个周次，升序去重。
parse_expand_week_numbers() {
  local raw="${1:-}"
  raw="${raw//，/,}"
  raw="${raw// /}"
  local global_odd=0 global_even=0
  [[ "${raw}" == *单* ]] && global_odd=1
  [[ "${raw}" == *双* ]] && global_even=1
  raw="${raw//周/}"
  raw="$(printf '%s' "${raw}" | sed 's/\[[^]]*\]//g' | sed 's/([^)]*)//g')"

  local -a weeks=()
  local item item_odd item_even clean l r i w
  local IFS=,
  for item in ${raw}; do
    [[ -z "${item}" ]] && continue
    item_odd=0; item_even=0
    [[ "${item}" == *单* ]] && item_odd=1
    [[ "${item}" == *双* ]] && item_even=1
    clean="${item//单/}"
    clean="${clean//双/}"
    local -a ex=()
    if [[ "${clean}" == *-* ]]; then
      l="${clean%%-*}"; r="${clean##*-}"
      if [[ "${l}" =~ ^[0-9]+$ && "${r}" =~ ^[0-9]+$ ]]; then
        for ((i = 10#$l; i <= 10#$r; i++)); do ex+=("${i}"); done
      fi
    elif [[ "${clean}" =~ ^[0-9]+$ ]]; then
      ex+=("$((10#$clean))")
    fi
    for w in "${ex[@]}"; do
      if (( item_odd || (!item_even && global_odd) )); then
        (( w % 2 == 1 )) && weeks+=("${w}")
      elif (( item_even || (!item_odd && global_even) )); then
        (( w % 2 == 0 )) && weeks+=("${w}")
      else
        weeks+=("${w}")
      fi
    done
  done
  if [[ ${#weeks[@]} -gt 0 ]]; then
    printf '%s\n' "${weeks[@]}" | sort -n -u
  fi
}

# ---------------------------------------------------------------------------
# 周次解析（含回退）
# ---------------------------------------------------------------------------

# 由课表的 classWeek / classWeekDetails 字段解析周次（每行一个，升序去重）。
# 优先 classWeek，其次 classWeekDetails 的周次展开，最后回退对 classWeekDetails 的裸数字提取。
parse_sjd_week_numbers() {
  local cw="${1:-}" cwd="${2:-}"
  local weeks
  weeks="$(parse_expand_week_numbers "${cw}")"
  if [[ -z "${weeks}" ]]; then
    weeks="$(parse_expand_week_numbers "${cwd}")"
  fi
  if [[ -z "${weeks}" ]]; then
    weeks="$(printf '%s' "${cwd}" | grep -oE '[0-9]+' | sort -n -u)"
  fi
  # 末尾补换行：保证 while read 能读到最后一个周次（否则末行会被丢弃）。
  [[ -n "${weeks}" ]] && printf '%s\n' "${weeks}"
}

# ---------------------------------------------------------------------------
# 节次解析
# ---------------------------------------------------------------------------

# 由 classTime（如 "1030405"）与可选 weekNoteDetail 解析节次区间。
# 输出 "start_slot end_slot"（0-based），无结果输出空。
parse_sjd_slots() {
  local ct="${1:-}" wnd="${2:-}"
  local tail="${ct:1}"
  local -a nodes=()
  local m
  while IFS= read -r m; do [[ -n "${m}" ]] && nodes+=("${m}"); done < <(printf '%s' "${tail}" | grep -oE '[0-9]{2}')
  if [[ ${#nodes[@]} -eq 0 ]]; then
    while IFS= read -r m; do [[ -n "${m}" ]] && nodes+=("${m}"); done < <(printf '%s' "${wnd}" | grep -oE '[0-9]+')
  fi
  [[ ${#nodes[@]} -eq 0 ]] && return 0
  local min=999 max=0 n
  for n in "${nodes[@]}"; do
    ((n = 10#$n))
    ((n < min)) && min=$n
    ((n > max)) && max=$n
  done
  ((min < 1 || max > 14)) && return 0
  local start=$((min - 1)) end=$((max - 1))
  ((start > end)) && return 0
  printf '%s %s' "${start}" "${end}"
}

# ---------------------------------------------------------------------------
# 教室 / 楼名归一
# ---------------------------------------------------------------------------

# 归一教室名：全角横线→'-'；"<单数字>-<3位数字>" 去楼号前缀（3-335→335、教1-101→101）。
parse_normalize_room() {
  local v="${1:-}"
  v="${v//－/-}"; v="${v//—/-}"; v="${v//–/-}"
  v="$(core_trim "${v}")"
  local prefix room bp
  if [[ "${v}" == *-* ]]; then
    prefix="${v%%-*}"
    room="${v#*-}"
    bp="${prefix#教}"
    if [[ "${bp}" =~ ^[0-9]$ && "${room}" =~ ^[0-9]{3}$ ]]; then
      printf '%s' "${room}"
      return 0
    fi
  fi
  printf '%s' "${v}"
}

# 归一教学楼名（去校区前缀、去空格、映射白名单）。返回标准楼名。
parse_building_name() {
  local v="${1:-}"
  local norm
  norm="$(core_trim "${v}")"
  norm="${norm//－/-}"; norm="${norm//—/-}"; norm="${norm//–/-}"
  for p in "校本部-" "西土城-" "沙河-"; do
    norm="${norm#"${p}"}"
  done
  local clean="${norm// /}"
  clean="${clean//　/}"
  case "${clean}" in
    1|教一楼) printf '教1' ;;
    2|教二楼) printf '教2' ;;
    3|教三楼) printf '教3' ;;
    4|教四楼) printf '教4' ;;
    未来学习大楼) printf '主楼' ;;
    N|N楼|N座|北楼|综合教学楼N|综合教学楼N楼|综合教学楼N座|综合楼N|综合楼N楼|综合N) printf '综合教学楼N' ;;
    S|S楼|S座|南楼|综合教学楼S|综合教学楼S楼|综合教学楼S座|综合楼S|综合楼S楼|综合S) printf '综合教学楼S' ;;
    教学实验综合楼N|教学实验综合楼N楼|教学实验综合楼N座|教学实验综合楼北|教学实验综合楼北楼|教学实验综合楼-N|教学实验综合楼-N楼|教学实验综合楼\(综教\)N|教学实验综合楼（综教）N|教学实验综合楼N\(综教\)|教学实验综合楼N（综教）|综教N|综教N楼|综教N座|综教北|综教北楼|综教-N|综教-N楼) printf '教学实验综合楼N' ;;
    教学实验综合楼S|教学实验综合楼S楼|教学实验综合楼S座|教学实验综合楼南|教学实验综合楼南楼|教学实验综合楼-S|教学实验综合楼-S楼|教学实验综合楼\(综教\)S|教学实验综合楼（综教）S|教学实验综合楼S\(综教\)|教学实验综合楼S（综教）|综教S|综教S楼|综教S座|综教南|综教南楼|综教-S|综教-S楼) printf '教学实验综合楼S' ;;
    智慧楼|智慧教室楼|智慧教室) printf '智慧教学楼' ;;
    "") printf '未知教学楼' ;;
    *) printf '%s' "${clean}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 学期推断
# ---------------------------------------------------------------------------

# 校验学期号格式 YYYY-YYYY-1|2。
parse_is_valid_term_id() {
  local v="$(core_trim "${1:-}")"
  [[ "${v}" =~ ^[0-9]{4}-[0-9]{4}-[12]$ ]]
}

# 由日期推断 (term_id, 开学第一周周一)。输出 "term_id term_start_date"。
parse_suggested_term() {
  local date="${1:-$(core_today)}"
  local y m
  y="$(date -d "${date}" +%Y 2>/dev/null)"
  m="$(date -d "${date}" +%-m 2>/dev/null)"
  local term_id anchor
  if (( m >= 2 && m <= 7 )); then
    term_id="$((y - 1))-${y}-2"
    anchor="${y}-03-02"
  else
    local fall=$(( m == 1 ? y - 1 : y ))
    term_id="${fall}-$((fall + 1))-1"
    anchor="${fall}-09-01"
  fi
  # 锚点所在周的周一
  local dow
  dow="$(TZ=Asia/Shanghai date -d "${anchor}" +%u 2>/dev/null)"
  local monday
  monday="$(TZ=Asia/Shanghai date -d "${anchor} - $((dow - 1)) days" +%Y-%m-%d 2>/dev/null)"
  printf '%s %s' "${term_id}" "${monday}"
}

# ---------------------------------------------------------------------------
# 时间解析
# ---------------------------------------------------------------------------

# 解析 HH:MM 为分钟（0..1440）。合法：HH<24 或 HH==24 且 MM==00。
parse_minutes() {
  local v="${1:-}"
  [[ "${v}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  local h="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"
  h=$((10#$h)); m=$((10#$m))
  if (( h < 24 && m < 60 )) || (( h == 24 && m == 0 )); then
    printf '%s' "$((h * 60 + m))"
    return 0
  fi
  return 1
}

# 严格解析考试时间文本为 "date|start|end"（缺省为空串）。
# 支持 "2026-09-07 09:20-11:00"、"2026年9月7日 9:20～11:00" 等；"另行通知"→date/start/end 全空。
# TODO(Round 4): 完善 ":00" 秒级格式与相邻数字边界校验，并与参考仓库 parse_exam_time 测试逐条对齐。
parse_exam_time() {
  local value="${1:-}"
  local norm="${value//：/:}"

  # 提取所有日期候选
  local -a dates=()
  local d
  while IFS= read -r d; do dates+=("${d}"); done < <(printf '%s' "${norm}" | grep -oE '[12][0-9]{3}[-/年.][0-9]{1,2}[-/月.][0-9]{1,2}日?')
  if [[ ${#dates[@]} -ne 1 ]]; then
    printf '||'
    return 0
  fi
  # 归一日期为 YYYY-MM-DD 并校验真实日期
  local y m dd
  y="$(printf '%s' "${dates[0]}" | grep -oE '^[12][0-9]{3}')"
  m="$(printf '%s' "${dates[0]}" | sed -E 's/^[0-9]{4}[^0-9]([0-9]{1,2}).*/\1/')"
  dd="$(printf '%s' "${dates[0]}" | grep -oE '[0-9]{1,2}日?$' | tr -d '日')"
  local date
  date="$(printf '%04d-%02d-%02d' "$((10#$y))" "$((10#$m))" "$((10#$dd))" 2>/dev/null)"
  # 回读校验（拒绝 2026-02-30 之类非法日期）
  if ! date -d "${date}" +%Y-%m-%d >/dev/null 2>&1 || [[ "$(date -d "${date}" +%Y-%m-%d 2>/dev/null)" != "${date}" ]]; then
    printf '||'
    return 0
  fi

  # 提取时刻候选（HH:MM，可带 :SS 但 SS 必须为 00）
  local -a clocks=()
  local c
  while IFS= read -r c; do
    if [[ "${c}" =~ :[0-9]{2}$ && ! "${c}" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
      # 含秒，忽略
      continue
    fi
    clocks+=("${c}")
  done < <(printf '%s' "${norm}" | grep -oE '[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?')
  if [[ ${#clocks[@]} -ne 2 ]]; then
    printf '%s||' "${date}"
    return 0
  fi
  local s="${clocks[0]}" e="${clocks[1]}"
  # 校验时刻格式严格（无秒）且 start<end
  if ! [[ "${s}" =~ ^[0-9]{1,2}:[0-9]{2}$ && "${e}" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    printf '%s||' "${date}"
    return 0
  fi
  local sm em
  sm="$(parse_minutes "${s}" 2>/dev/null)" || { printf '%s||' "${date}"; return 0; }
  em="$(parse_minutes "${e}" 2>/dev/null)" || { printf '%s||' "${date}"; return 0; }
  if (( sm >= em || sm >= 1440 )); then
    printf '%s||' "${date}"
    return 0
  fi
  printf '%s|%s|%s' "${date}" "${s}" "${e}"
}

#!/usr/bin/env bash
# lib/public.sh —— 公共查询（班车 / 节假日 / 活动）。全部无需登录的公开 HTTPS GET 接口。
# 协议见 docs/protocols.md 第 3 节；固定 URL、禁止重定向（http.sh 默认不跟随）。

set -euo pipefail

if [[ -n "${_BUPTY_PUBLIC_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_PUBLIC_LOADED=1

PUBLIC_SHUTTLE_URL="https://where-to-study.cn/api/shuttle-bus"
PUBLIC_HOLIDAY_SOURCE="https://unpkg.com/holiday-calendar@1.3.3/data/CN"
PUBLIC_HOLIDAY_FALLBACK_SOURCE="https://www.gov.cn/yaowen/liebiao/202511/content_7047099.htm"
PUBLIC_EVENTS_PRIMARY_URL="https://nemoyuzx.github.io/contest-ddl/data/competitions.json"
PUBLIC_EVENTS_MIRROR_URL="https://where-to-study.cn/contest-ddl/data/competitions.json"
PUBLIC_EVENTS_BACKUP_URL="https://where-to-study.cn/api/contest-events"
PUBLIC_NOTICES_URL="https://where-to-study.cn/api/contest-notices"

# 事件六类（协议 3.2）。
PUBLIC_EVENT_TYPES=(competition conference journal_special_issue hackathon summer_camp pre_admission)

# 判断值是否为可解析的 RFC3339 时间。
_public_valid_rfc3339() {
  local value="${1:-}"
  if core_is_blank "${value}"; then
    return 1
  fi
  date -d "${value}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 班车（协议 3.1）
# ---------------------------------------------------------------------------

# 从班车源数据解析当日展示。成功输出 JSON，失败置 BUPTY_ERR 并返回 1。
# 输出：{"date","status","next_departure","notice_title","routes"}。
_public_parse_shuttle() {
  local body="$1"
  local schema
  schema="$(printf '%s' "${body}" | jq -r '.schema_version // empty' 2>/dev/null || true)"
  if [[ "${schema}" != "1.0" ]]; then
    core_err "班车数据不符合 Schema 1.0。"
    return 1
  fi

  local today now_hm weekday wname
  today="$(core_today)"
  now_hm="$(core_now_hm)"
  weekday="$(core_weekday "${today}")"
  local -a weekday_names=(monday tuesday wednesday thursday friday saturday sunday)
  if [[ "${weekday}" =~ ^[1-7]$ ]]; then
    wname="${weekday_names[$((weekday - 1))]}"
  else
    wname="monday"
  fi

  # 1) 取 published_at <= 今天 的通知，按 (published_at, id) 降序。
  local sorted nid decision action notice_title="" schedules_json=""
  sorted="$(printf '%s' "${body}" | jq -r --arg t "${today}" '
    [.items[]? | select((.published_at // "") != "" and (.published_at <= $t))]
    | sort_by(.published_at, .id) | reverse | .[].id // empty
  ' 2>/dev/null || true)"

  # 2) 逐条找 parsed 且当前时段 active 的 schedule；若该通知有 parsed 但无 active → 放弃。
  while IFS= read -r nid; do
    [[ -z "${nid}" ]] && continue
    decision="$(printf '%s' "${body}" | jq -c --arg id "${nid}" --arg t "${today}" '
      [.items[]? | select(.id == $id)][0] as $n
      | ($n.schedules // []) as $s
      | ([$s[] | select(.parse_status == "parsed" and ((.rows // []) | length) > 0)] | length) as $parsed_n
      | if $parsed_n == 0 then {action:"skip"}
        else
          ([$s[] | select(.parse_status == "parsed"
                          and ((.rows // []) | length) > 0
                          and ((.period.start_date // "") != "")
                          and (.period.start_date <= $t)
                          and ((.period.end_date == null) or ($t <= .period.end_date)))]
          ) as $active
          | if ($active | length) == 0 then {action:"abandon"}
            else
              ($active | map(.period.start_date) | max) as $latest
              | {action:"ok", title: ($n.title // ""), schedules: [$active[] | select(.period.start_date == $latest)]}
            end
        end
    ' 2>/dev/null || true)"
    action="$(printf '%s' "${decision}" | jq -r '.action // empty' 2>/dev/null || true)"
    if [[ "${action}" == "ok" ]]; then
      notice_title="$(printf '%s' "${decision}" | jq -r '.title // ""' 2>/dev/null || true)"
      schedules_json="$(printf '%s' "${decision}" | jq -c '.schedules // []' 2>/dev/null || true)"
      break
    elif [[ "${action}" == "abandon" ]]; then
      break
    fi
    # action == "skip"：继续下一条更旧的通知。
  done < <(printf '%s\n' "${sorted}")

  # 3) 组装 routes（按今天星期取 services.<weekday>）、标记 departed 与全局最早未发车的 next。
  local computed=""
  if [[ -n "${schedules_json}" ]]; then
    computed="$(printf '%s' "${schedules_json}" | jq -c --arg w "${wname}" --arg now "${now_hm}" '
      [ .[]
        | select(.from != null and .to != null)
        | { from: (.from // ""),
            to: (.to // ""),
            period_label: (.period.label // ""),
            departures: ([ .rows[]?
                | (.services[$w] // null) as $svc
                | select($svc != null)
                | { time: (.departure_time // ""),
                    vehicle: ($svc.vehicle // ""),
                    count: (($svc.count // 0) | tonumber),
                    departed: ((.departure_time // "99:99") <= $now),
                    next: false }
              ] | sort_by(.time))
          }
      ] | sort_by(.from, .to, .period_label) as $routes
      | ([$routes[].departures[]]) as $deps
      | ([range(0; ($routes | length)) as $ri
          | range(0; ($routes[$ri].departures | length)) as $di
          | select($routes[$ri].departures[$di].departed == false)
          | {ri: $ri, di: $di, time: $routes[$ri].departures[$di].time}]
         | sort_by(.time, .ri, .di) | .[0]) as $first
      | { routes: ($routes | if $first == null then .
                   else .[$first.ri].departures[$first.di].next = true end),
          departure_count: ($deps | length),
          vehicle_count: (([$deps[].count] | map(tonumber) | add) // 0),
          next: (if $first == null then null
                 else {time: $first.time, from: $routes[$first.ri].from, to: $routes[$first.ri].to} end) }
    ' 2>/dev/null || true)"
  fi
  if [[ -z "${computed}" || "${computed}" == "null" ]]; then
    computed='{"routes":[],"departure_count":0,"vehicle_count":0,"next":null}'
  fi

  local dep_count veh_count next_json routes_final
  dep_count="$(printf '%s' "${computed}" | jq -r '.departure_count // 0' 2>/dev/null || true)"
  veh_count="$(printf '%s' "${computed}" | jq -r '.vehicle_count // 0' 2>/dev/null || true)"
  next_json="$(printf '%s' "${computed}" | jq -c '.next // null' 2>/dev/null || true)"
  routes_final="$(printf '%s' "${computed}" | jq -c '.routes // []' 2>/dev/null || true)"
  [[ -n "${routes_final}" ]] || routes_final="[]"

  local status next_dep nt nf nto
  if [[ -z "${schedules_json}" ]]; then
    status="未找到当前生效的班车时刻表"
    next_dep=""
  elif [[ "${dep_count}" == "0" ]]; then
    status="今日暂无已安排班车"
    next_dep=""
  else
    status="今日安排 ${dep_count} 个发车时刻 · ${veh_count} 辆车"
  fi

  if [[ "${next_json}" != "null" && -n "${next_json}" ]]; then
    nt="$(printf '%s' "${next_json}" | jq -r '.time // ""' 2>/dev/null || true)"
    nf="$(printf '%s' "${next_json}" | jq -r '.from // ""' 2>/dev/null || true)"
    nto="$(printf '%s' "${next_json}" | jq -r '.to // ""' 2>/dev/null || true)"
    next_dep="下一班 ${nt} · ${nf} → ${nto}"
  elif [[ "${dep_count}" != "0" ]]; then
    next_dep="今日班车已结束"
  else
    next_dep=""
  fi

  jq -n --arg date "${today}" --arg status "${status}" --arg next "${next_dep}" \
    --arg title "${notice_title}" --argjson routes "${routes_final}" \
    '{date:$date, status:$status, next_departure:$next, notice_title:$title, routes:$routes}'
}

# 拉取班车（协议 3.1）。成功输出 JSON，失败置 BUPTY_ERR 并返回 1。
public_fetch_shuttle() {
  http_get "${PUBLIC_SHUTTLE_URL}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接班车服务，请确认网络能访问 where-to-study.cn。"
    return 1
  fi
  if [[ "${HTTP_STATUS}" != 2* ]]; then
    core_err "班车接口返回错误（HTTP ${HTTP_STATUS}）。"
    return 1
  fi
  _public_parse_shuttle "${HTTP_BODY}"
}

# ---------------------------------------------------------------------------
# 节假日（协议 3.3）
# ---------------------------------------------------------------------------

# 解析节假日源数据，输出 items JSON 数组 [{date,name,type}]（按 date,type,name 升序）。
# 结构非法（region 非 CN / year 不匹配）置 BUPTY_ERR 并返回 1。
_public_parse_holiday_items() {
  local body="$1" year="$2"
  local region src_year
  region="$(printf '%s' "${body}" | jq -r '.region // empty' 2>/dev/null || true)"
  if [[ "${region}" != "CN" ]]; then
    core_err "节假日数据区域不正确。"
    return 1
  fi
  src_year="$(printf '%s' "${body}" | jq -r '.year // empty' 2>/dev/null || true)"
  if [[ "${src_year}" != "${year}" ]]; then
    core_err "节假日数据年份与请求不一致。"
    return 1
  fi

  local out="" line kind date name type
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    kind="$(printf '%s' "${line}" | jq -r '.type // empty' 2>/dev/null || true)"
    if [[ "${kind}" != "public_holiday" && "${kind}" != "transfer_workday" ]]; then
      continue
    fi
    date="$(printf '%s' "${line}" | jq -r '.date // empty' 2>/dev/null || true)"
    name="$(printf '%s' "${line}" | jq -r '.name_cn // empty' 2>/dev/null || true)"
    if core_is_blank "${name}"; then
      name="$(printf '%s' "${line}" | jq -r '.name // empty' 2>/dev/null || true)"
    fi
    name="$(core_trim "${name}")"
    if [[ ! "${date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      continue
    fi
    if [[ "${date:0:4}" != "${year}" ]]; then
      continue
    fi
    if core_is_blank "${name}"; then
      continue
    fi
    if [[ "${kind}" == "public_holiday" ]]; then
      type="holiday"
    else
      type="workday"
    fi
    out+="$(jq -n --arg d "${date}" --arg n "${name}" --arg t "${type}" \
      '{date:$d, name:$n, type:$t}' 2>/dev/null || true)"$'\n'
  done < <(printf '%s' "${body}" | jq -c '.dates[]? // empty' 2>/dev/null)

  printf '%s' "${out}" | jq -s -c 'sort_by(.date, .type, .name)' 2>/dev/null || true
}

# 2026 年内置离线兜底（协议 3.3 fallback_2026_items，逐日展开）。
_public_fallback_2026_items() {
  local -a ranges=(
    "元旦|2026-01-01|2026-01-03|holiday"
    "元旦补班|2026-01-04|2026-01-04|workday"
    "春节补班|2026-02-14|2026-02-14|workday"
    "春节|2026-02-15|2026-02-23|holiday"
    "春节补班|2026-02-28|2026-02-28|workday"
    "清明节|2026-04-04|2026-04-06|holiday"
    "劳动节|2026-05-01|2026-05-05|holiday"
    "劳动节补班|2026-05-09|2026-05-09|workday"
    "端午节|2026-06-19|2026-06-21|holiday"
    "中秋节|2026-09-25|2026-09-27|holiday"
    "国庆节补班|2026-09-20|2026-09-20|workday"
    "国庆节|2026-10-01|2026-10-07|holiday"
    "国庆节补班|2026-10-10|2026-10-10|workday"
  )
  local out="" range name start end type cur
  for range in "${ranges[@]}"; do
    name="${range%%|*}"; range="${range#*|}"
    start="${range%%|*}"; range="${range#*|}"
    end="${range%%|*}"; type="${range##*|}"
    cur="${start}"
    while true; do
      if core_is_blank "${cur}"; then break; fi
      out+="$(jq -n --arg d "${cur}" --arg n "${name}" --arg t "${type}" \
        '{date:$d, name:$n, type:$t}' 2>/dev/null || true)"$'\n'
      if [[ "${cur}" == "${end}" ]]; then break; fi
      cur="$(TZ=Asia/Shanghai date -d "${cur} +1 day" +%Y-%m-%d 2>/dev/null || true)"
    done
  done
  printf '%s' "${out}" | jq -s -c 'sort_by(.date, .type, .name)' 2>/dev/null || true
}

# 拉取节假日（协议 3.3）。成功输出 {"year","source","items"}；
# 请求失败或响应非法时，2026 用内置兜底、其它年份输出空 items 且 source 标 unavailable。
public_fetch_holidays() {
  local year="$1"
  local url="${PUBLIC_HOLIDAY_SOURCE}/${year}.json"
  http_get "${url}"
  if [[ "${HTTP_STATUS}" == 2* ]]; then
    local items
    if items="$(_public_parse_holiday_items "${HTTP_BODY}" "${year}")"; then
      core_clear_err
      jq -n --argjson y "${year}" --arg s "${PUBLIC_HOLIDAY_SOURCE}" --argjson items "${items}" \
        '{year:$y, source:$s, items:$items}'
      return 0
    fi
  fi

  # 离线兜底。
  core_clear_err
  if [[ "${year}" == "2026" ]]; then
    local items
    items="$(_public_fallback_2026_items)"
    jq -n --argjson y "${year}" --arg s "${PUBLIC_HOLIDAY_FALLBACK_SOURCE}" --argjson items "${items}" \
      '{year:$y, source:$s, items:$items}'
  else
    jq -n --argjson y "${year}" --arg s "unavailable: ${PUBLIC_HOLIDAY_SOURCE}" \
      '{year:$y, source:$s, items:[]}'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 活动 / 竞赛 DDL（协议 3.2）
# ---------------------------------------------------------------------------

# 解析竞赛 DDL 源（schema 1.4，timezone Asia/Shanghai）。输出 {"generated_at","items"}。
_public_parse_contest() {
  local body="$1"
  local schema tz generated_at
  schema="$(printf '%s' "${body}" | jq -r '.schema_version // empty' 2>/dev/null || true)"
  if [[ "${schema}" != "1.4" ]]; then
    core_err "竞赛数据不符合 Schema 1.4。"
    return 1
  fi
  tz="$(printf '%s' "${body}" | jq -r '.timezone // empty' 2>/dev/null || true)"
  if [[ "${tz}" != "Asia/Shanghai" ]]; then
    core_err "竞赛数据时区不正确。"
    return 1
  fi
  generated_at="$(printf '%s' "${body}" | jq -r '.generated_at // empty' 2>/dev/null || true)"
  if ! _public_valid_rfc3339 "${generated_at}"; then
    core_err "竞赛数据更新时间无效。"
    return 1
  fi

  local raw out="" line pd
  raw="$(printf '%s' "${body}" | jq -c '
    [.items[]?
      | select((.archived != true))
      | select(.event_type == "competition" or .event_type == "conference"
               or .event_type == "journal_special_issue" or .event_type == "hackathon"
               or .event_type == "summer_camp" or .event_type == "pre_admission")
      | {
          id: ((.id // "") | tostring),
          name: (.name // ""),
          event_type: .event_type,
          source_type: "contest_ddl",
          primary_deadline: (.primary_deadline // ""),
          deadline_label: (if (.primary_deadline == .registration_deadline) then "报名截止"
                           elif (.primary_deadline == .abstract_deadline) then "摘要截止"
                           elif (.primary_deadline == .submission_deadline) then "提交截止"
                           elif (.primary_deadline == .competition_start) then "活动开始"
                           elif (.primary_deadline == .competition_end) then "活动结束"
                           else "" end),
          organizer: (.organizer // ""),
          categories: (.categories // []),
          tags: (.tags // []),
          level: (.level // ""),
          location: (.location // "")
        }
      | select(.id != "" and .name != "")
    ] | sort_by(.primary_deadline, .name)
  ' 2>/dev/null || true)"

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    pd="$(printf '%s' "${line}" | jq -r '.primary_deadline // empty' 2>/dev/null || true)"
    if core_is_blank "${pd}"; then continue; fi
    if ! _public_valid_rfc3339 "${pd}"; then continue; fi
    out+="${line}"$'\n'
  done < <(printf '%s' "${raw}" | jq -c '.[]' 2>/dev/null)

  local items_json
  items_json="$(printf '%s' "${out}" | jq -s -c '.' 2>/dev/null || true)"
  [[ -n "${items_json}" ]] || items_json="[]"
  # items 可能很大，须经 stdin 传入，避免超出 argv 上限。
  printf '%s' "${items_json}" | jq -c --arg g "${generated_at}" '{generated_at:$g, items:.}'
}

# 解析校内竞赛通知（schema 1.0）。输出 items JSON 数组（按 primary_deadline,name 升序）。
_public_parse_notices() {
  local body="$1"
  local schema src_name
  schema="$(printf '%s' "${body}" | jq -r '.schema_version // empty' 2>/dev/null || true)"
  if [[ "${schema}" != "1.0" ]]; then
    core_err "校内竞赛通知不符合 Schema 1.0。"
    return 1
  fi
  src_name="$(printf '%s' "${body}" | jq -r '.source.name // ""' 2>/dev/null || true)"

  local out="" line id name org deadlines has_dl pd pd_label idx d dd dl
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    id="$(printf '%s' "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
    name="$(printf '%s' "${line}" | jq -r '.name // empty' 2>/dev/null || true)"
    if core_is_blank "${name}"; then
      name="$(printf '%s' "${line}" | jq -r '.title // empty' 2>/dev/null || true)"
    fi
    name="$(core_trim "${name}")"
    [[ -n "${id}" && -n "${name}" ]] || continue

    org="$(printf '%s' "${line}" | jq -r '.source // empty' 2>/dev/null || true)"
    org="$(core_trim "${org}")"
    [[ -n "${org}" ]] || org="${src_name}"

    deadlines="$(printf '%s' "${line}" | jq -c '.deadlines // []' 2>/dev/null || true)"
    has_dl="$(printf '%s' "${deadlines}" | jq -r 'length // 0' 2>/dev/null || true)"
    if [[ -z "${has_dl}" || "${has_dl}" == "0" ]]; then
      pd="$(printf '%s' "${line}" | jq -r '.primary_deadline // empty' 2>/dev/null || true)"
      pd_label="$(printf '%s' "${line}" | jq -r '.primary_deadline_label // empty' 2>/dev/null || true)"
      if [[ -n "${pd}" ]]; then
        deadlines="$(jq -n --arg d "${pd}" --arg l "${pd_label}" '[{date:$d, label:$l}]' 2>/dev/null || true)"
      else
        deadlines="[]"
      fi
    fi

    idx=0
    while IFS= read -r d; do
      [[ -z "${d}" ]] && continue
      dd="$(printf '%s' "${d}" | jq -r '.date // empty' 2>/dev/null || true)"
      dl="$(printf '%s' "${d}" | jq -r '.label // empty' 2>/dev/null || true)"
      if core_is_blank "${dd}"; then
        idx=$((idx + 1)); continue
      fi
      if ! _public_valid_rfc3339 "${dd}"; then
        idx=$((idx + 1)); continue
      fi
      dl="$(core_trim "${dl}")"
      [[ -n "${dl}" ]] || dl="截止时间"
      out+="$(jq -n --arg id "school:${id}:${idx}" --arg name "${name}" --arg pd "${dd}" \
        --arg dl "${dl}" --arg org "${org}" \
        '{id:$id, name:$name, event_type:"competition", source_type:"school_notice",
          primary_deadline:$pd, deadline_label:$dl, organizer:$org,
          categories:["校内竞赛通知"], tags:[], level:"", location:""}' 2>/dev/null || true)"$'\n'
      idx=$((idx + 1))
    done < <(printf '%s' "${deadlines}" | jq -c '.[]' 2>/dev/null)
  done < <(printf '%s' "${body}" | jq -c '.items[]? // empty' 2>/dev/null)

  printf '%s' "${out}" | jq -s -c 'sort_by(.primary_deadline, .name)' 2>/dev/null || true
}

# 拉取活动 / 竞赛 DDL（协议 3.2）。主/镜像按 generated_at 择新，均失败用备用；再合并校内通知。
# 成功输出 {"source","items"}（items 已按 primary_deadline,name 升序，含已截止，视图层过滤）。
public_fetch_events() {
  local main="" mirror="" tmp

  # 主源。
  http_get "${PUBLIC_EVENTS_PRIMARY_URL}"
  if [[ "${HTTP_STATUS}" == 2* ]]; then
    if tmp="$(_public_parse_contest "${HTTP_BODY}")"; then
      main="${tmp}"
    fi
  fi

  # 镜像。
  http_get "${PUBLIC_EVENTS_MIRROR_URL}"
  if [[ "${HTTP_STATUS}" == 2* ]]; then
    if tmp="$(_public_parse_contest "${HTTP_BODY}")"; then
      mirror="${tmp}"
    fi
  fi

  local chosen_url="" items=""
  if [[ -n "${main}" && -n "${mirror}" ]]; then
    local main_at mirror_at main_epoch mirror_epoch
    main_at="$(printf '%s' "${main}" | jq -r '.generated_at // ""' 2>/dev/null || true)"
    mirror_at="$(printf '%s' "${mirror}" | jq -r '.generated_at // ""' 2>/dev/null || true)"
    main_epoch="$(date -d "${main_at}" +%s 2>/dev/null || echo 0)"
    mirror_epoch="$(date -d "${mirror_at}" +%s 2>/dev/null || echo 0)"
    if (( mirror_epoch > main_epoch )); then
      chosen_url="${PUBLIC_EVENTS_MIRROR_URL}"
      items="$(printf '%s' "${mirror}" | jq -c '.items // []' 2>/dev/null || true)"
    else
      chosen_url="${PUBLIC_EVENTS_PRIMARY_URL}"
      items="$(printf '%s' "${main}" | jq -c '.items // []' 2>/dev/null || true)"
    fi
  elif [[ -n "${main}" ]]; then
    chosen_url="${PUBLIC_EVENTS_PRIMARY_URL}"
    items="$(printf '%s' "${main}" | jq -c '.items // []' 2>/dev/null || true)"
  elif [[ -n "${mirror}" ]]; then
    chosen_url="${PUBLIC_EVENTS_MIRROR_URL}"
    items="$(printf '%s' "${mirror}" | jq -c '.items // []' 2>/dev/null || true)"
  else
    # 主/镜像均不可用 → 备用 API。
    http_get "${PUBLIC_EVENTS_BACKUP_URL}"
    if [[ "${HTTP_STATUS}" == 2* ]]; then
      if tmp="$(_public_parse_contest "${HTTP_BODY}")"; then
        chosen_url="${PUBLIC_EVENTS_BACKUP_URL}"
        items="$(printf '%s' "${tmp}" | jq -c '.items // []' 2>/dev/null || true)"
      fi
    fi
  fi

  # 校内通知。
  local school_items="" school_ok=0
  http_get "${PUBLIC_NOTICES_URL}"
  if [[ "${HTTP_STATUS}" == 2* ]]; then
    if tmp="$(_public_parse_notices "${HTTP_BODY}")"; then
      school_items="${tmp}"
      school_ok=1
    fi
  fi

  local source
  if [[ -n "${items}" ]]; then
    if [[ "${school_ok}" == "1" ]]; then
      source="${chosen_url} + ${PUBLIC_NOTICES_URL}"
      items="$(printf '%s' "${items}" | jq -c --argjson s "${school_items}" \
        '. + $s | sort_by(.primary_deadline, .name)' 2>/dev/null || true)"
    else
      source="${chosen_url}"
    fi
  elif [[ "${school_ok}" == "1" ]]; then
    source="${PUBLIC_NOTICES_URL}"
    items="${school_items}"
  else
    core_err "公开活动与校内竞赛通知均不可用。"
    return 1
  fi

  [[ -n "${items}" ]] || items="[]"
  core_clear_err
  # items 可能很大，须经 stdin 传入，避免超出 argv 上限。
  printf '%s' "${items}" | jq -c --arg s "${source}" '{source:$s, items:.}'
}

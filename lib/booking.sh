#!/usr/bin/env bash
# booking.sh —— 图书馆研修间预约（order.bupt.edu.cn/ic-web）。
# 协议见 docs/order-booking.md：CAS 七步登录 + 分类/房间/空闲时段/主题/成员 + 预约/取消/我的预约/违约。
# 会话状态存 lib/session.sh（token/accNo/账号/cookie jar 路径），凭据绝不打印、不进日志。

set -euo pipefail

if [[ -n "${_BUPTY_BOOKING_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_BOOKING_LOADED=1

BOOKING_BASE="https://order.bupt.edu.cn/ic-web"
BOOKING_ORIGIN="https://order.bupt.edu.cn"

# ---------------------------------------------------------------------------
# 纯工具
# ---------------------------------------------------------------------------

# URL 编码（用于 CAS finalAddress）。
_booking_urlencode() {
  jq -rn --arg v "$1" '$v | @uri' 2>/dev/null || printf '%s' "$1"
}

# HTML 实体解码（execution / JS 跳转 URL 可能含 &amp; 等）。
_booking_html_decode() {
  local s="${1:-}"
  s="${s//&quot;/\"}"
  s="${s//&#34;/\"}"
  s="${s//&#39;/\'}"
  s="${s//&#x27;/\'}"
  s="${s//&lt;/<}"
  s="${s//&gt;/>}"
  s="${s//&amp;/\&}"
  printf '%s' "${s}"
}

# "HH:MM" -> 当日分钟数。
_booking_hm_to_min() {
  local h m
  h="${1%%:*}"; m="${1##*:}"
  printf '%s' "$(( 10#${h} * 60 + 10#${m} ))"
}

# 当日分钟数 -> "HH:MM"。
_booking_min_to_hm() {
  printf '%02d:%02d' "$(( $1 / 60 ))" "$(( $1 % 60 ))"
}

# epoch 毫秒 -> 北京时间日期 YYYY-MM-DD。
_booking_epoch_ms_date() {
  local ms="$1" sec
  if [[ ! "${ms}" =~ ^[0-9]+$ ]]; then printf ''; return 0; fi
  sec=$(( ms / 1000 ))
  TZ=Asia/Shanghai date -d "@${sec}" '+%Y-%m-%d' 2>/dev/null || date -d "@${sec}" '+%Y-%m-%d'
}

# epoch 毫秒 -> 北京时间时刻 HH:MM。
_booking_epoch_ms_hm() {
  local ms="$1" sec
  if [[ ! "${ms}" =~ ^[0-9]+$ ]]; then printf ''; return 0; fi
  sec=$(( ms / 1000 ))
  TZ=Asia/Shanghai date -d "@${sec}" '+%H:%M' 2>/dev/null || date -d "@${sec}" '+%H:%M'
}

# epoch 毫秒 -> "YYYY-MM-DD HH:MM"。
_booking_epoch_ms_dt() {
  local ms="$1" sec
  if [[ ! "${ms}" =~ ^[0-9]+$ ]]; then printf ''; return 0; fi
  sec=$(( ms / 1000 ))
  TZ=Asia/Shanghai date -d "@${sec}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@${sec}" '+%Y-%m-%d %H:%M'
}

# ---------------------------------------------------------------------------
# 响应信封与错误
# ---------------------------------------------------------------------------

# 业务 code。
_booking_code() {
  printf '%s' "${HTTP_BODY:-}" | jq -r '.code // empty' 2>/dev/null || true
}

# 认证失效：HTTP 401 或 code==300（未登录）。
_booking_is_expired() {
  if [[ "${HTTP_STATUS}" == "401" ]]; then return 0; fi
  if [[ "$(_booking_code)" == "300" ]]; then return 0; fi
  return 1
}

# 人类可读错误（优先透传服务器 message）。
_booking_error_message() {
  local msg
  msg="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.message // empty' 2>/dev/null || true)"
  if core_is_blank "${msg}"; then
    printf '图书馆预约服务返回错误（HTTP %s）。' "${HTTP_STATUS}"
  else
    printf '%s' "${msg}"
  fi
}

# ---------------------------------------------------------------------------
# CAS 登录（七步，同 cookie jar 顺序执行）
# ---------------------------------------------------------------------------

# booking_login <account> <password>：完成登录并缓存 token/accNo。失败置 BUPTY_ERR 返回 1。
booking_login() {
  local account="$1" password="$2"
  booking_session_clear
  core_ensure_dirs
  local jar
  jar="$(mktemp "${BUPTY_CACHE_DIR}/.booking-cookie.XXXXXX")"

  # 1. 取登录跳转地址。
  local final_addr="${BOOKING_ORIGIN}/"
  local addr_url="${BOOKING_BASE}/auth/address?finalAddress=$(_booking_urlencode "${final_addr}")&manager=false&consoleType=16"
  http_get "${addr_url}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接图书馆预约服务，请确认网络能访问 order.bupt.edu.cn。"
    rm -f "${jar}"
    return 1
  fi
  local jump
  jump="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.data // empty' 2>/dev/null || true)"
  if core_is_blank "${jump}"; then
    core_err "获取登录跳转地址失败。"
    rm -f "${jar}"
    return 1
  fi

  # 2. 访问跳转地址，读 302 Location（CAS 登录页），并保存 UNI_AUTH_JSESSIONID 等会话 Cookie。
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -c "${jar}" -b "${jar}" "${jump}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接图书馆预约服务，请确认网络能访问 order.bupt.edu.cn。"
    rm -f "${jar}"
    return 1
  fi
  local location login_page
  location="$(http_header Location)"
  login_page="${location}"
  if core_is_blank "${login_page}"; then
    core_err "CAS 登录跳转失败（未返回登录页地址）。"
    rm -f "${jar}"
    return 1
  fi

  # 3. 拉取 CAS 登录页，解析 execution 与 doAuthId。
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -c "${jar}" -b "${jar}" "${login_page}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接统一认证服务，请确认网络能访问 auth.bupt.edu.cn。"
    rm -f "${jar}"
    return 1
  fi
  local execution doauth_id
  execution="$(printf '%s' "${HTTP_BODY:-}" \
    | grep -oE '<input[^>]*>' \
    | grep -E 'name="execution"' \
    | head -1 \
    | grep -oE 'value="[^"]*"' \
    | head -1 \
    | sed -E 's/^value="//; s/"$//' || true)"
  execution="$(_booking_html_decode "${execution}")"
  doauth_id="$(printf '%s' "${login_page}" | sed -E 's/.*[?&]service=([^&]*).*/\1/' | sed -E 's#.*%2[fF]do[aA]uth%2[fF]([^%&]+).*#\1#')"
  if core_is_blank "${execution}"; then
    core_err "CAS 登录页解析失败（未找到 execution 参数）。"
    rm -f "${jar}"
    return 1
  fi
  if [[ "${doauth_id}" == "${login_page}" || -z "${doauth_id}" || "${doauth_id}" == *"/"* || "${doauth_id}" == *"%"* || "${doauth_id}" == *"&"* || "${doauth_id}" == *"?"* ]]; then
    core_err "CAS 登录页解析失败（未找到 doAuth 标识）。"
    rm -f "${jar}"
    return 1
  fi

  # 4. 提交登录表单，读 Location 取 ticket。
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -c "${jar}" -b "${jar}" \
    --data-urlencode "username=${account}" \
    --data-urlencode "password=${password}" \
    --data-urlencode "type=username_password" \
    --data-urlencode "execution=${execution}" \
    --data-urlencode "_eventId=submit" \
    "${login_page}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接统一认证服务，请确认网络能访问 auth.bupt.edu.cn。"
    rm -f "${jar}"
    return 1
  fi
  location="$(http_header Location)"
  local ticket
  ticket="$(printf '%s' "${location}" | sed -E 's/.*[?&]ticket=([^&]*).*/\1/')"
  if core_is_blank "${ticket}" || [[ "${ticket}" == "${location}" ]]; then
    core_err "请检查账号密码，若官方页面要求验证码请先完成验证。"
    rm -f "${jar}"
    return 1
  fi

  # 5. 用 ticket 换 doAuth 页（HTML 内嵌 JS 跳转，需自己解析，不能 -L 跟随）。
  local doauth_url="${BOOKING_ORIGIN}/authcenter/doAuth/${doauth_id}"
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -c "${jar}" -b "${jar}" "${doauth_url}?ticket=${ticket}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接图书馆预约服务，请确认网络能访问 order.bupt.edu.cn。"
    rm -f "${jar}"
    return 1
  fi
  local token_url
  token_url="$(printf '%s' "${HTTP_BODY:-}" \
    | tr -d '\n' \
    | grep -oE "window\.location\.href[[:space:]]*=[[:space:]]*['\"][^'\"]*['\"]" \
    | head -1 \
    | sed -E "s/^[^'\"]*['\"]//; s/['\"]$//" || true)"
  token_url="$(_booking_html_decode "${token_url}")"
  if core_is_blank "${token_url}" || [[ "${token_url}" != *"/auth/token"* ]]; then
    core_err "CAS 登录跳转解析失败（未找到 token 跳转地址）。"
    rm -f "${jar}"
    return 1
  fi

  # 6. 访问 token 跳转地址，获得会话 Cookie ic-cookie。
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -c "${jar}" -b "${jar}" "${token_url}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接图书馆预约服务，请确认网络能访问 order.bupt.edu.cn。"
    rm -f "${jar}"
    return 1
  fi

  # 7. 用会话 Cookie 取 userInfo，缓存 token/accNo。
  http_get "${BOOKING_BASE}/auth/userInfo" -b "${jar}" -H "lan: 1"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接图书馆预约服务，请确认网络能访问 order.bupt.edu.cn。"
    rm -f "${jar}"
    return 1
  fi
  if [[ "$(_booking_code)" != "0" ]]; then
    core_err "$(_booking_error_message)"
    rm -f "${jar}"
    return 1
  fi
  local token acc_no
  token="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.data.token // empty' 2>/dev/null || true)"
  acc_no="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.data.accNo // empty' 2>/dev/null || true)"
  if core_is_blank "${token}" || core_is_blank "${acc_no}"; then
    core_err "图书馆预约登录成功但未返回 token/accNo。"
    rm -f "${jar}"
    return 1
  fi

  booking_session_set "${token}" "${acc_no}" "${account}" "${jar}"
  return 0
}

# 确保有当前账号的有效会话（复用或重新登录）。
booking_ensure_session() {
  local account="$1" password="$2"
  if booking_session_owned_by "${account}"; then
    return 0
  fi
  booking_login "${account}" "${password}"
}

# ---------------------------------------------------------------------------
# 统一鉴权请求
# ---------------------------------------------------------------------------

# 带 cookie jar + token/lan 头的请求。返回 0 成功 / 1 业务错误 / 2 登录失效。
_booking_api_call() {
  local method="$1" path="$2" query="${3:-}" json="${4:-}"
  local url="${BOOKING_BASE}${path}"
  if [[ -n "${query}" ]]; then url="${url}?${query}"; fi
  local token jar
  token="$(booking_session_get_token)"
  jar="${BUPTY_BOOKING_COOKIE_JAR:-}"
  local -a args=()
  if [[ -n "${jar}" ]]; then args+=(-b "${jar}"); fi
  args+=(-H "token: ${token}")
  args+=(-H "lan: 1")
  args+=(-H "Referer: ${BOOKING_ORIGIN}/")
  if [[ "${method}" == "GET" ]]; then
    http_get "${url}" "${args[@]}"
  else
    http_post_json "${url}" "${json}" "${args[@]}"
  fi
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接图书馆预约服务，请确认网络能访问 order.bupt.edu.cn。"
    return 1
  fi
  if _booking_is_expired; then
    booking_session_clear
    core_err "图书馆预约登录已失效，请重新登录。"
    return 2
  fi
  if [[ "$(_booking_code)" != "0" ]]; then
    core_err "$(_booking_error_message)"
    return 1
  fi
  return 0
}

# 带失效自动重登一次的请求（fetch/submit 内部使用）。
_booking_api_authed() {
  local method="$1" path="$2" query="${3:-}" json="${4:-}"
  local rc
  _booking_api_call "${method}" "${path}" "${query}" "${json}"
  rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${rc}" -eq 2 ]]; then
    if creds_load && booking_login "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then
      core_clear_err
      _booking_api_call "${method}" "${path}" "${query}" "${json}"
      return $?
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 纯解析函数（离线可单测）
# ---------------------------------------------------------------------------

# roomMenu 响应 -> 分类 JSON [{id,name}]（第二层节点 id 即 labIds，校区层级名拼接）。
_booking_parse_categories() {
  local body="$1"
  printf '%s' "${body}" | jq -c '
    [.data[]? as $campus
     | ($campus.name // $campus.campusName // "") as $cn
     | ($campus.children // $campus.childList // $campus.nodes // [])[]?
     | select((.id // null) != null)
     | { id: ((.id) | tostring),
         name: (($cn + (if ($cn != "") then "·" else "" end) + (.name // .labName // .menuName // "")) | gsub("[\t\r\n]"; " ")) }]
  ' 2>/dev/null || printf '[]'
}

# 空闲时段计算：openTimes 减 resvInfo 里落在目标日期的预约，按 timeInterval 对齐、
# 丢弃短于 minResvTime 的片段。输出 [{start:"HH:MM",end:"HH:MM"}]。
_booking_compute_free_slots() {
  local open_json="$1" resv_json="$2" interval="${3:-30}" minr="${4:-10}" date="$5"
  if [[ ! "${interval}" =~ ^[0-9]+$ ]]; then interval=30; fi
  if [[ ! "${minr}" =~ ^[0-9]+$ ]]; then minr=10; fi
  if (( interval < 1 )); then interval=1; fi

  # 开放区间（分钟）。
  local opens="" line os oe osm oem
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    os="$(printf '%s' "${line}" | jq -r '.openStartTime // empty' 2>/dev/null || true)"
    oe="$(printf '%s' "${line}" | jq -r '.openEndTime // empty' 2>/dev/null || true)"
    [[ -n "${os}" && -n "${oe}" ]] || continue
    osm="$(_booking_hm_to_min "${os}")"
    oem="$(_booking_hm_to_min "${oe}")"
    opens+="${osm} ${oem}"$'\n'
  done < <(printf '%s' "${open_json}" | jq -c '.[]?' 2>/dev/null)

  # 占用区间（仅目标日期，分钟）。
  local resvs="" s e sd shm
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    s="$(printf '%s' "${line}" | jq -r '.startTime // empty' 2>/dev/null || true)"
    e="$(printf '%s' "${line}" | jq -r '.endTime // empty' 2>/dev/null || true)"
    [[ -n "${s}" && -n "${e}" ]] || continue
    sd="$(_booking_epoch_ms_date "${s}")"
    [[ "${sd}" == "${date}" ]] || continue
    shm="$(_booking_epoch_ms_hm "${s}")"
    s="$(_booking_hm_to_min "${shm}")"
    e="$(_booking_hm_to_min "$(_booking_epoch_ms_hm "${e}")")"
    resvs+="${s} ${e}"$'\n'
  done < <(printf '%s' "${resv_json}" | jq -c '.[]?' 2>/dev/null)

  local out="" oline cur rline snap_s snap_e
  while IFS= read -r oline; do
    [[ -z "${oline}" ]] && continue
    osm="${oline%% *}"
    oem="${oline##* }"
    cur="${osm}"
    while IFS= read -r rline; do
      [[ -z "${rline}" ]] && continue
      s="${rline%% *}"
      e="${rline##* }"
      if (( s >= oem || e <= osm )); then continue; fi
      if (( s < osm )); then s="${osm}"; fi
      if (( e > oem )); then e="${oem}"; fi
      if (( s > cur )); then
        snap_s=$(( ( (cur + interval - 1) / interval ) * interval ))
        snap_e=$(( ( s / interval ) * interval ))
        if (( snap_e - snap_s >= minr )); then
          out+="$(jq -n --arg s "$(_booking_min_to_hm "${snap_s}")" --arg e "$(_booking_min_to_hm "${snap_e}")" '{start:$s, end:$e}')"$'\n'
        fi
      fi
      if (( e > cur )); then cur="${e}"; fi
    done < <(printf '%s' "${resvs}" | sort -n)
    if (( cur < oem )); then
      snap_s=$(( ( (cur + interval - 1) / interval ) * interval ))
      snap_e=$(( ( oem / interval ) * interval ))
      if (( snap_e - snap_s >= minr )); then
        out+="$(jq -n --arg s "$(_booking_min_to_hm "${snap_s}")" --arg e "$(_booking_min_to_hm "${snap_e}")" '{start:$s, end:$e}')"$'\n'
      fi
    fi
  done <<< "${opens}"
  printf '%s' "${out}" | jq -s -c '.' 2>/dev/null || printf '[]'
}

# reserve 响应 -> 房间 JSON 数组（含计算好的 free 空闲时段）。
_booking_parse_rooms() {
  local body="$1" date="$2"
  local out="" line devid devname roomname minu maxu interval minr maxr open resv free open_start open_end roomjson
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    devid="$(printf '%s' "${line}" | jq -r '.devId // empty' 2>/dev/null || true)"
    [[ -n "${devid}" && "${devid}" != "null" ]] || continue
    devname="$(printf '%s' "${line}" | jq -r '.devName // .roomName // ""' 2>/dev/null || true)"
    roomname="$(printf '%s' "${line}" | jq -r '.roomName // .devName // ""' 2>/dev/null || true)"
    minu="$(printf '%s' "${line}" | jq -r '.minUser // 1' 2>/dev/null || true)"
    maxu="$(printf '%s' "${line}" | jq -r '.maxUser // 1' 2>/dev/null || true)"
    interval="$(printf '%s' "${line}" | jq -r '.resvRule.timeInterval // 30' 2>/dev/null || true)"
    minr="$(printf '%s' "${line}" | jq -r '.resvRule.minResvTime // 10' 2>/dev/null || true)"
    maxr="$(printf '%s' "${line}" | jq -r '.resvRule.maxResvTime // 120' 2>/dev/null || true)"
    [[ "${interval}" =~ ^[0-9]+$ ]] || interval=30
    [[ "${minr}" =~ ^[0-9]+$ ]] || minr=10
    [[ "${maxr}" =~ ^[0-9]+$ ]] || maxr=120
    if (( interval < 1 )); then interval=1; fi
    if (( maxr < minr )); then maxr="${minr}"; fi
    open="$(printf '%s' "${line}" | jq -c '.openTimes // []' 2>/dev/null || true)"
    resv="$(printf '%s' "${line}" | jq -c '[.resvInfo[]? | select(.startTime != null and .endTime != null)]' 2>/dev/null || true)"
    free="$(_booking_compute_free_slots "${open}" "${resv}" "${interval}" "${minr}" "${date}")"
    open_start="$(printf '%s' "${line}" | jq -r '.openStart // "08:00"' 2>/dev/null || true)"
    open_end="$(printf '%s' "${line}" | jq -r '.openEnd // "22:00"' 2>/dev/null || true)"
    roomjson="$(jq -n \
      --arg id "${devid}" --arg dn "${devname}" --arg rn "${roomname}" \
      --arg os "${open_start}" --arg oe "${open_end}" \
      --argjson minu "${minu}" --argjson maxu "${maxu}" \
      --argjson interval "${interval}" --argjson minr "${minr}" --argjson maxr "${maxr}" \
      --argjson free "${free}" \
      '{devId:$id, devName:$dn, roomName:$rn, minUser:$minu, maxUser:$maxu,
        timeInterval:$interval, minResvTime:$minr, maxResvTime:$maxr,
        open_start:$os, open_end:$oe, free:$free}')"
    out+="${roomjson}"$'\n'
  done < <(printf '%s' "${body}" | jq -c '.data[]? // empty' 2>/dev/null)
  printf '%s' "${out}" | jq -s -c '.' 2>/dev/null || printf '[]'
}

# 预约状态位掩码 -> 中文标签（协议 2.2）。
_booking_status_label() {
  local s="${1:-0}"
  if (( s & 128 )); then printf '已结束/已取消'
  elif (( s & 64 )); then printf '进行中'
  elif (( s & 4 )); then printf '已签到'
  elif (( s & 8192 )); then printf '待同意'
  else printf '待履约'
  fi
}

# reserve/resvInfo 响应 -> 我的预约 JSON [{uuid,devName,begin,end,status_label}]。
_booking_parse_own() {
  local body="$1"
  local out="" line uuid devname st begin end label
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    uuid="$(printf '%s' "${line}" | jq -r '.uuid // empty' 2>/dev/null || true)"
    [[ -n "${uuid}" && "${uuid}" != "null" ]] || continue
    devname="$(printf '%s' "${line}" | jq -r '.resvDevInfoList[0].devName // empty' 2>/dev/null || true)"
    st="$(printf '%s' "${line}" | jq -r '.resvStatus // 0' 2>/dev/null || true)"
    begin="$(_booking_epoch_ms_dt "$(printf '%s' "${line}" | jq -r '.resvBeginTime // 0' 2>/dev/null || true)")"
    end="$(_booking_epoch_ms_dt "$(printf '%s' "${line}" | jq -r '.resvEndTime // 0' 2>/dev/null || true)")"
    label="$(_booking_status_label "${st}")"
    out+="$(jq -n --arg u "${uuid}" --arg d "${devname}" --arg b "${begin}" --arg e "${end}" --arg l "${label}" \
      '{uuid:$u, devName:$d, begin:$b, end:$e, status_label:$l}')"$'\n'
  done < <(printf '%s' "${body}" | jq -c '.data[]? // empty' 2>/dev/null)
  printf '%s' "${out}" | jq -s -c '.' 2>/dev/null || printf '[]'
}

# 构造预约 POST body（关键：appAccNo/resvMember 用 accNo，resvBeginTime/EndTime 补 :00 秒）。
_booking_build_submit_body() {
  local dev_id="$1" begin="$2" end="$3" test_name="$4" members="$5" kind="$6"
  local acc_no begin_s end_s members_json
  acc_no="$(booking_session_get_acc_no)"
  if core_is_blank "${acc_no}"; then acc_no="null"; fi
  begin_s="${begin}:00"
  end_s="${end}:00"
  members_json="$(printf '%s' "${members}" | jq -R -s -c 'split(",") | map(select(length > 0)) | map(tonumber? // .)' 2>/dev/null || printf '[]')"
  jq -n \
    --argjson acc "${acc_no}" --argjson kind "${kind}" \
    --arg b "${begin_s}" --arg e "${end_s}" --arg tn "${test_name}" \
    --argjson dev "${dev_id}" --argjson members "${members_json}" \
    '{sysKind: 1, appAccNo: $acc, memberKind: $kind,
      resvBeginTime: $b, resvEndTime: $e, testName: $tn,
      resvKind: 2, resvProperty: 0, appUrl: "",
      resvMember: $members, resvDev: [$dev], memo: "", captcha: "", addServices: []}'
}

# ---------------------------------------------------------------------------
# 拉取
# ---------------------------------------------------------------------------

# booking_fetch_categories -> 分类 JSON [{id,name}]。
booking_fetch_categories() {
  if ! creds_load; then core_err "请先在设置中登录。"; return 1; fi
  if ! booking_ensure_session "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then return 1; fi
  if ! _booking_api_authed "GET" "/roomMenu" "" ""; then return 1; fi
  _booking_parse_categories "${HTTP_BODY}"
}

# booking_fetch_rooms <labIds> <date(YYYY-MM-DD)> -> 房间 JSON（含 free）。
booking_fetch_rooms() {
  local lab_ids="$1" date="$2"
  if ! creds_load; then core_err "请先在设置中登录。"; return 1; fi
  if ! booking_ensure_session "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then return 1; fi
  local ymd="${date//-/}"
  local query="sysKind=1&labIds=${lab_ids}&resvDates=${ymd},${ymd}"
  if ! _booking_api_authed "GET" "/reserve" "${query}" ""; then return 1; fi
  _booking_parse_rooms "${HTTP_BODY}" "${date}"
}

# 拉取某分类今/明两天的房间与空闲时段，输出 {labId,today,tomorrow,rooms:[...]}。
# 供视图一次异步拉取即展示「今日/明日空闲时段数量」。
booking_fetch_rooms_combined() {
  local lab_ids="$1"
  local today tomorrow t_tmp m_tmp
  today="$(core_today)"
  tomorrow="$(TZ=Asia/Shanghai date -d "${today} +1 day" +%Y-%m-%d 2>/dev/null || date -d "${today} +1 day" +%Y-%m-%d)"
  t_tmp="$(mktemp)"
  if ! booking_fetch_rooms "${lab_ids}" "${today}" > "${t_tmp}"; then rm -f "${t_tmp}"; return 1; fi
  m_tmp="$(mktemp)"
  if ! booking_fetch_rooms "${lab_ids}" "${tomorrow}" > "${m_tmp}"; then rm -f "${t_tmp}" "${m_tmp}"; return 1; fi
  jq -n --arg lab "${lab_ids}" --arg t "${today}" --arg m "${tomorrow}" \
    --slurpfile rt "${t_tmp}" --slurpfile rm "${m_tmp}" \
    '{labId: $lab, today: $t, tomorrow: $m,
      rooms: [($rt[0][]) as $r
              | ($rm[0][] | select(.devId == $r.devId)) as $m
              | $r + {count_today: ($r.free | length),
                      free_tomorrow: $m.free,
                      count_tomorrow: ($m.free | length)}]}'
  local rc=$?
  rm -f "${t_tmp}" "${m_tmp}"
  return "${rc}"
}

# booking_fetch_themes <devId> -> 主题数组（codeName 字符串）。
booking_fetch_themes() {
  local dev_id="$1"
  if ! creds_load; then core_err "请先在设置中登录。"; return 1; fi
  if ! booking_ensure_session "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then return 1; fi
  if ! _booking_api_authed "GET" "/devCoding/theme/details" "devId=${dev_id}" ""; then return 1; fi
  printf '%s' "${HTTP_BODY:-}" | jq -c '[.data[]? | (.codeName // empty)] | map(select(. != ""))' 2>/dev/null || printf '[]'
}

# booking_resolve_member <学号> -> 该学号的 accNo（纯输出）。
booking_resolve_member() {
  local key="$1"
  if ! creds_load; then core_err "请先在设置中登录。"; return 1; fi
  if ! booking_ensure_session "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then return 1; fi
  if ! _booking_api_authed "GET" "/account/getMembers" "key=${key}&page=1&pageNum=10" ""; then return 1; fi
  local acc_no status
  acc_no="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.data[0].accNo // empty' 2>/dev/null || true)"
  status="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.data[0].status // .data[0].localstatus // empty' 2>/dev/null || true)"
  if core_is_blank "${acc_no}"; then
    core_err "未查到该学号对应的成员（${key}）。"
    return 1
  fi
  if [[ "${status}" == "2" ]]; then
    core_err "该成员已被停用，无法作为同行成员。"
    return 1
  fi
  printf '%s' "${acc_no}"
}

# booking_fetch_own -> 我的预约 JSON [{uuid,devName,begin,end,status_label}]。
booking_fetch_own() {
  if ! creds_load; then core_err "请先在设置中登录。"; return 1; fi
  if ! booking_ensure_session "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then return 1; fi
  local begin end
  begin="$(core_today)"
  end="$(TZ=Asia/Shanghai date -d "${begin} +30 days" +%Y-%m-%d 2>/dev/null || date -d "${begin} +30 days" +%Y-%m-%d)"
  local query="beginDate=${begin}&endDate=${end}&needStatus=6&page=1&pageNum=50&orderKey=gmt_create&orderModel=desc"
  if ! _booking_api_authed "GET" "/reserve/resvInfo" "${query}" ""; then return 1; fi
  _booking_parse_own "${HTTP_BODY}"
}

# booking_fetch_punish -> 是否被禁用（"true"/"false"，非空数组即禁用）。
booking_fetch_punish() {
  if ! creds_load; then core_err "请先在设置中登录。"; return 1; fi
  if ! booking_ensure_session "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then return 1; fi
  if ! _booking_api_authed "GET" "/reserve/punishInfo" "" ""; then return 1; fi
  local n
  n="$(printf '%s' "${HTTP_BODY:-}" | jq -r 'if (.data | type) == "array" then (.data | length | tostring) else "0" end' 2>/dev/null || true)"
  if [[ -z "${n}" || "${n}" == "0" || "${n}" == "null" ]]; then
    printf 'false'
  else
    printf 'true'
  fi
}

# ---------------------------------------------------------------------------
# 操作
# ---------------------------------------------------------------------------

# booking_submit <devId> <begin "YYYY-MM-DD HH:MM"> <end> <testName> <member_accnos_csv> <member_kind>
# 成功输出 {uuid,resvId,message}；失败置 BUPTY_ERR 返回 1（透传服务器 message）。
booking_submit() {
  local dev_id="$1" begin="$2" end="$3" test_name="$4" members="$5" kind="$6"
  if ! creds_load; then core_err "请先在设置中登录。"; return 1; fi
  if ! booking_ensure_session "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then return 1; fi
  local body
  body="$(_booking_build_submit_body "${dev_id}" "${begin}" "${end}" "${test_name}" "${members}" "${kind}")" \
    || { core_err "预约数据构造失败。"; return 1; }
  if ! _booking_api_authed "POST" "/reserve" "" "${body}"; then return 1; fi
  local uuid resv_id msg
  uuid="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.data.uuid // empty' 2>/dev/null || true)"
  resv_id="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.data.resvId // empty' 2>/dev/null || true)"
  msg="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.message // empty' 2>/dev/null || true)"
  jq -n --arg u "${uuid}" --arg r "${resv_id}" --arg m "${msg}" '{uuid:$u, resvId:$r, message:$m}'
}

# booking_cancel <uuid> -> 取消。失败置 BUPTY_ERR 返回 1。
booking_cancel() {
  local uuid="$1"
  if ! creds_load; then core_err "请先在设置中登录。"; return 1; fi
  if ! booking_ensure_session "${BUPTY_ACCOUNT}" "${BUPTY_PASSWORD}"; then return 1; fi
  local body
  body="$(jq -n --arg u "${uuid}" '{uuid: $u}')"
  _booking_api_authed "POST" "/reserve/delete" "" "${body}"
}

# ---------------------------------------------------------------------------
# 待抢约（pending_bookings）持久化：settings 数组键，每项一个 JSON 对象字符串。
# ---------------------------------------------------------------------------

# 读取待抢约列表（每行一个 JSON 对象）。
booking_pending_list() {
  settings_get_array pending_bookings
}

# 覆盖写入待抢约列表（换行分隔）。
booking_pending_save() {
  settings_set_array pending_bookings "$1"
}

# 追加一条待抢约。
booking_pending_add() {
  local item="$1" list
  list="$(booking_pending_list)"
  if [[ -n "${list}" ]]; then
    booking_pending_save "${list}"$'\n'"${item}"
  else
    booking_pending_save "${item}"
  fi
}

# 按索引（0 起）删除一条待抢约。
booking_pending_remove() {
  local idx="$1" line i=0 out="" first=1
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if (( i != idx )); then
      if (( first )); then out="${line}"; first=0; else out+=$'\n'"${line}"; fi
    fi
    i=$(( i + 1 ))
  done < <(booking_pending_list)
  booking_pending_save "${out}"
}

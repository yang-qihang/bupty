#!/usr/bin/env bash
# ucloud.sh —— 教学云 UCloud（作业 / 课程）认证链与数据拉取。
# 协议见 docs/protocols.md 第 2 节。认证链四步，全部 HTTPS，禁止重定向跟随。

set -euo pipefail

if [[ -n "${_BUPTY_UCLOUD_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_UCLOUD_LOADED=1

UCLOUD_ORIGIN="https://ucloud.bupt.edu.cn"
UCLOUD_API="https://apiucloud.bupt.edu.cn"
# 官方公开 OAuth client（解码为 portal:portal_secret），非用户凭据。
UCLOUD_BASIC_AUTH="Basic  cG9ydGFsOnBvcnRhbF9zZWNyZXQ="
UCLOUD_LOGIN_URL="https://auth.bupt.edu.cn/authserver/login?service=https%3A%2F%2Fucloud.bupt.edu.cn"
UCLOUD_TOKEN_URL="https://apiucloud.bupt.edu.cn/ykt-basics/oauth/token"

# ---------------------------------------------------------------------------
# 认证链
# ---------------------------------------------------------------------------

# HTML 实体解码（execution 值可能含 &amp; 等）。
# 注意：bash 的 ${var//pattern/repl} 里 & 是特殊字符（展开为匹配原文），须写作 \&。
_ucloud_html_decode() {
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

# 四步认证链：登录页取 Cookie+execution → 提交登录取 ticket → 换 access_token → 缓存。
ucloud_authenticate() {
  local account="$1" password="$2"
  ucloud_session_clear

  # 2.1 统一认证登录页：取 Cookie 与 execution。
  http_get "${UCLOUD_LOGIN_URL}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接统一认证服务，请确认网络能访问 auth.bupt.edu.cn。"
    return 1
  fi
  local cookies execution
  cookies="$(http_set_cookies)"
  execution="$(printf '%s' "${HTTP_BODY:-}" \
    | grep -oE '<input[^>]*>' \
    | grep -E 'name="execution"' \
    | head -1 \
    | grep -oE 'value="[^"]*"' \
    | head -1 \
    | sed -E 's/^value="//; s/"$//' || true)"
  execution="$(_ucloud_html_decode "${execution}")"
  if core_is_blank "${execution}"; then
    core_err "统一认证登录页解析失败（未找到 execution 参数）。"
    return 1
  fi

  # 2.2 提交登录，读取 Location 取 ticket。
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Cookie: ${cookies}" \
    -H "Referer: ${UCLOUD_LOGIN_URL}" \
    --data-urlencode "username=${account}" \
    --data-urlencode "password=${password}" \
    --data-urlencode "type=username_password" \
    --data-urlencode "execution=${execution}" \
    --data-urlencode "_eventId=submit" \
    "${UCLOUD_LOGIN_URL}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接统一认证服务，请确认网络能访问 auth.bupt.edu.cn。"
    return 1
  fi
  local location ticket host
  location="$(http_header Location)"
  host="$(printf '%s' "${location}" | sed -E 's#^(https?)://([^/?#]*).*#\1://\2#')"
  if [[ "${host}" != "https://ucloud.bupt.edu.cn" ]]; then
    core_err "请检查教学云账号密码，若官方页面要求验证码请先完成验证。"
    return 1
  fi
  ticket="$(printf '%s' "${location}" | sed -E 's/.*[?&]ticket=([^&]*).*/\1/')"
  if core_is_blank "${ticket}" || [[ "${ticket}" == "${location}" ]]; then
    core_err "请检查教学云账号密码，若官方页面要求验证码请先完成验证。"
    return 1
  fi

  # 2.3 用 ticket 换 access_token。
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Authorization: ${UCLOUD_BASIC_AUTH}" \
    -H "Tenant-Id: 000000" \
    -H "Accept: application/json, text/plain, */*" \
    -H "Referer: ${UCLOUD_ORIGIN}/" \
    --data-urlencode "ticket=${ticket}" \
    --data-urlencode "grant_type=third" \
    "${UCLOUD_TOKEN_URL}"
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接教学云服务，请确认网络能访问 apiucloud.bupt.edu.cn。"
    return 1
  fi
  local access_token user_id
  if [[ "${HTTP_STATUS}" != "2"* ]]; then
    local token_err
    token_err="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.msg // .message // empty' 2>/dev/null || true)"
    if core_is_blank "${token_err}"; then
      core_err "教学云令牌接口返回 HTTP ${HTTP_STATUS}。"
    else
      core_err "教学云令牌接口错误（HTTP ${HTTP_STATUS}）：${token_err}"
    fi
    return 1
  fi
  access_token="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.access_token // empty' 2>/dev/null || true)"
  user_id="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.userId // .user_id // empty' 2>/dev/null || true)"
  if core_is_blank "${access_token}"; then
    core_err "教学云服务登录成功但未返回 access_token。"
    return 1
  fi
  if core_is_blank "${user_id}"; then
    core_err "教学云服务登录成功但未返回用户标识。"
    return 1
  fi

  # 2.4 缓存 token / userId 到会话（仅内存，不落盘）。
  ucloud_session_set "${access_token}" "${user_id}" "${account}"
  return 0
}

# 会话复用：有则直接输出 token，无则完整认证。输出 token 或返回非 0。
ucloud_ensure_token() {
  local account="$1" password="$2"
  if ucloud_session_owned_by "${account}"; then
    printf '%s' "$(ucloud_session_get)"
    return 0
  fi
  if ucloud_authenticate "${account}" "${password}"; then
    printf '%s' "$(ucloud_session_get)"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# API 请求
# ---------------------------------------------------------------------------

# 业务成功：code 缺失或 ==200（数字/字符串）。
_ucloud_code_success() {
  local code
  code="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.code // empty' 2>/dev/null || true)"
  [[ -z "${code}" || "${code}" == "200" ]]
}

# 认证失效：HTTP 401，或 code==401，或 msg 含失效关键字（大小写不敏感）。
_ucloud_is_expired() {
  [[ "${HTTP_STATUS}" == "401" ]] && return 0
  local code msg
  code="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.code // empty' 2>/dev/null || true)"
  [[ "${code}" == "401" ]] && return 0
  msg="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.msg // .message // empty' 2>/dev/null || true)"
  printf '%s' "${msg}" | grep -qiE 'token expired|invalid token|token失效|token过期|登录已过期|登录超时|请先登录|未登录|登录失效' && return 0
  return 1
}

# 从响应取人类可读错误。
_ucloud_error_message() {
  local msg
  msg="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.msg // .message // empty' 2>/dev/null || true)"
  if core_is_blank "${msg}"; then
    printf '教学云服务返回错误（HTTP %s）。' "${HTTP_STATUS}"
  else
    printf '%s' "${msg}"
  fi
}

# 底层 API 调用（协议 2.4 请求头）。返回 0 成功 / 1 业务错误 / 2 登录失效。
_ucloud_api_call() {
  local method="$1" path="$2" query="${3:-}" json="${4:-}"
  local url="${UCLOUD_API}${path}"
  if [[ -n "${query}" ]]; then url="${url}?${query}"; fi
  local token
  token="$(ucloud_session_get)"
  local -a args=()
  args+=(-H "Accept: application/json, text/plain, */*")
  args+=(-H "Authorization: ${UCLOUD_BASIC_AUTH}")
  args+=(-H "Tenant-Id: 000000")
  args+=(-H "Referer: ${UCLOUD_ORIGIN}/")
  if [[ -n "${token}" ]]; then args+=(-H "Blade-Auth: ${token}"); fi
  if [[ "${method}" == "GET" ]]; then
    http_get "${url}" "${args[@]}"
  else
    http_post_json "${url}" "${json}" "${args[@]}"
  fi
  if [[ "${HTTP_STATUS}" == "000" ]]; then
    core_err "无法连接教学云服务，请确认网络能访问 apiucloud.bupt.edu.cn。"
    return 1
  fi
  if _ucloud_is_expired; then
    ucloud_session_clear
    core_err "教学云登录已失效，请重新登录。"
    return 2
  fi
  if [[ "${HTTP_STATUS}" != "2"* ]]; then
    core_err "$(_ucloud_error_message)"
    return 1
  fi
  if ! _ucloud_code_success; then
    core_err "$(_ucloud_error_message)"
    return 1
  fi
  return 0
}

# 带失效自动重登一次的 API 调用（fetch 内部使用）。
_ucloud_api_authed() {
  local method="$1" path="$2" query="${3:-}" json="${4:-}"
  local rc
  _ucloud_api_call "${method}" "${path}" "${query}" "${json}"
  rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${rc}" -eq 2 ]]; then
    if ucloud_authenticate "${BUPTY_ACCOUNT}" "$(creds_assignment_password)"; then
      core_clear_err
      _ucloud_api_call "${method}" "${path}" "${query}" "${json}"
      return $?
    fi
  fi
  return 1
}

# GET API：ucloud_api_get <path> <query>（业务成功返回 0，失败置 BUPTY_ERR）。
ucloud_api_get() {
  local path="$1" query="${2:-}"
  _ucloud_api_call "GET" "${path}" "${query}" ""
}

# POST JSON API：ucloud_api_post_json <path> <json>。
ucloud_api_post_json() {
  local path="$1" json="$2"
  _ucloud_api_call "POST" "${path}" "" "${json}"
}

# ---------------------------------------------------------------------------
# 数据拉取
# ---------------------------------------------------------------------------

# 拉课程列表（协议 2.5），输出 JSON 数组 [{id, name, teachers}]。
ucloud_fetch_courses() {
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  if ! ucloud_ensure_token "${BUPTY_ACCOUNT}" "$(creds_assignment_password)" >/dev/null; then
    return 1
  fi
  local path="/ykt-site/site/list/student/current"
  local query="size=9999&current=1&userId=${BUPTY_UCLOUD_USER_ID}&siteRoleCode=2"
  if ! _ucloud_api_authed "GET" "${path}" "${query}" ""; then
    return 1
  fi
  local courses
  courses="$(printf '%s' "${HTTP_BODY:-}" | jq -c '
    [.data.records[]?
      | {
          id: ((.id // .siteId // .courseId // "") | tostring),
          name: (.siteName // .courseName // .siteTitle // .name // "未命名课程"),
          teachers: ([.teachers[]?.name // empty])
        }]
  ' 2>/dev/null || true)"
  if [[ -z "${courses}" ]]; then courses="[]"; fi
  printf '%s' "${courses}"
}

# 作业截止时间归一为 YYYY-MM-DD HH:MM:SS（RFC3339 转北京时间）。
_ucloud_normalize_deadline() {
  local raw="${1:-}"
  [[ -z "${raw}" ]] && { printf ''; return 0; }
  if [[ "${raw}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    printf '%s' "${raw}"
    return 0
  fi
  if [[ "${raw}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}$ ]]; then
    printf '%s:00' "${raw}"
    return 0
  fi
  local t
  t="$(TZ=Asia/Shanghai date -d "${raw}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || t=""
  if [[ -n "${t}" ]]; then
    printf '%s' "${t}"
    return 0
  fi
  printf '%s' "${raw}"
}

# 作业状态映射（协议 2.8）：99→未提交、0→已提交、1→已批改、2→已驳回，其余原样。
_ucloud_map_status() {
  case "${1:-}" in
    99) printf '未提交' ;;
    0) printf '已提交' ;;
    1) printf '已批改' ;;
    2) printf '已驳回' ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

# 拉全部作业（2.6 每门课 + 2.7 首页 undone 兜底合并），按 (deadline, course_name, title, id) 升序输出。
ucloud_fetch_assignments() {
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  if ! ucloud_ensure_token "${BUPTY_ACCOUNT}" "$(creds_assignment_password)" >/dev/null; then
    return 1
  fi

  local courses courses_tmp
  courses_tmp="$(mktemp)"
  if ! ucloud_fetch_courses > "${courses_tmp}"; then
    rm -f "${courses_tmp}"
    return 1
  fi
  courses="$(cat "${courses_tmp}")"
  rm -f "${courses_tmp}"

  local tmp
  tmp="$(mktemp)"
  local course_json cid cname body
  while IFS= read -r course_json; do
    [[ -z "${course_json}" ]] && continue
    cid="$(printf '%s' "${course_json}" | jq -r '.id // empty' 2>/dev/null || true)"
    cname="$(printf '%s' "${course_json}" | jq -r '.name // empty' 2>/dev/null || true)"
    [[ -z "${cname}" ]] && cname="未命名课程"
    body="$(jq -n --arg sid "${cid}" --arg uid "${BUPTY_UCLOUD_USER_ID}" \
      '{siteId:$sid, userId:$uid, keyword:"", chapterId:"", nodeId:"", current:1, size:9999, studentAssignmentStatus:"", status:"", sortColumn:"", sortType:""}')"
    if _ucloud_api_authed "POST" "/ykt-site/work/student/list" "" "${body}"; then
      printf '%s' "${HTTP_BODY:-}" | jq -c --arg cid "${cid}" --arg cname "${cname}" '
        .data.records[]?
        | select((has("type")|not) or ((.type|tostring)=="3") or ((.type|tostring)=="5"))
        | {
            id: ((.id // .assignmentId // .activityId // "") | tostring),
            title: (.assignmentTitle // .activityName // .title // "未命名作业"),
            course_name: (if ((.siteName // .courseName // .siteTitle // "") == "") then $cname else (.siteName // .courseName // .siteTitle) end),
            course_id: ((.siteId // .courseId // $cid) | tostring),
            deadline_raw: (.assignmentEndTime // .endTime // ""),
            status_raw: ((.assignmentStatus // "") | tostring),
            type: (.type // null)
          }
        | select(.id != "")
      ' 2>/dev/null >> "${tmp}" || true
    fi
  done < <(printf '%s' "${courses}" | jq -c '.[]' 2>/dev/null)

  # 2.7 首页未完成兜底。
  if _ucloud_api_authed "GET" "/ykt-site/site/student/undone" "userId=${BUPTY_UCLOUD_USER_ID}" ""; then
    printf '%s' "${HTTP_BODY:-}" | jq -c '
      .data.undoneList[]?
      | select((has("type")|not) or ((.type|tostring)=="3") or ((.type|tostring)=="5"))
      | {
          id: ((.activityId // .id // "") | tostring),
          title: (.activityName // .title // "未命名作业"),
          course_name: "",
          course_id: "",
          deadline_raw: (.endTime // ""),
          status_raw: "99",
          type: (.type // null)
        }
      | select(.id != "")
    ' 2>/dev/null >> "${tmp}" || true
  fi

  # 归一 deadline、映射状态，得到规范化 NDJSON。
  local line out="" deadline status
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    deadline="$(_ucloud_normalize_deadline "$(printf '%s' "${line}" | jq -r '.deadline_raw // empty' 2>/dev/null || true)")"
    status="$(_ucloud_map_status "$(printf '%s' "${line}" | jq -r '.status_raw // empty' 2>/dev/null || true)")"
    out+="$(printf '%s' "${line}" | jq -c --arg d "${deadline}" --arg s "${status}" \
      'del(.deadline_raw, .status_raw) | .deadline = $d | .status = $s | if .type == null then del(.type) else . end' 2>/dev/null || true)"$'\n'
  done < "${tmp}"
  rm -f "${tmp}"

  # 按 (id, deadline) 去重合并（课程作业优先保留课程名），再升序排序。
  printf '%s' "${out}" | jq -s -c '
    group_by([.id, .deadline])
    | map(
        (reduce .[] as $r ({};
          if (($r.course_name // "") != "") and ((.course_name // "") == "") then .course_name = $r.course_name else . end
          | if (($r.course_id // "") != "") and ((.course_id // "") == "") then .course_id = $r.course_id else . end
          | if (($r.title // "") != "") and ((.title // "") == "") then .title = $r.title else . end
          | if (($r.status // "") != "") and ((.status // "") == "") then .status = $r.status else . end
          | .id = $r.id
          | .deadline = $r.deadline
          | if ($r.type != null) and (.type == null) then .type = $r.type else . end
        ))
        | .course_name = (.course_name // "")
        | .course_id = (.course_id // "")
        | .title = (.title // "")
        | .status = (.status // "")
      )
    | sort_by(.deadline, .course_name, .title, .id)
  '
}

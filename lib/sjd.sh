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

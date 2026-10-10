#!/usr/bin/env bash
# http.sh —— curl 封装。统一超时、UA、响应大小上限、状态/响应体/响应头捕获。
# 全部 HTTPS；curl 默认不跟随重定向（需要时手动读 Location 并校验 host）。

if [[ -n "${_BUPTY_HTTP_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_HTTP_LOADED=1

BUPTY_USER_AGENT="bupty/${BUPTY_VERSION:-0.1.0} (+https://github.com/Nemoyuzx/where_to_study)"
BUPTY_HTTP_TIMEOUT="${BUPTY_HTTP_TIMEOUT:-20}"

# 输出全局变量：
#   HTTP_STATUS   三位 HTTP 状态码；网络失败为 "000"。
#   HTTP_BODY     响应体。
#   HTTP_HEADERS  响应头原文。
HTTP_STATUS=""
HTTP_BODY=""
HTTP_HEADERS=""

# 核心请求：参数透传给 curl。用法：http_request [curl 参数...]
http_request() {
  local bodyfile hdrfile rc
  bodyfile="$(mktemp)"
  hdrfile="$(mktemp)"
  HTTP_STATUS="$(curl -sS --compressed -D "${hdrfile}" -o "${bodyfile}" \
    -w '%{http_code}' "$@" 2>/dev/null)" || rc=$?
  HTTP_STATUS="${HTTP_STATUS:-000}"
  # 网络错误时 curl 输出 "000"，但有时代码可能为空，统一兜底。
  if [[ -z "${HTTP_STATUS}" ]]; then
    HTTP_STATUS="000"
  fi
  HTTP_BODY="$(cat "${bodyfile}" 2>/dev/null || true)"
  HTTP_HEADERS="$(cat "${hdrfile}" 2>/dev/null || true)"
  rm -f "${bodyfile}" "${hdrfile}"
  [[ "${HTTP_STATUS}" != "000" ]]
}

# GET
http_get() {
  local url="$1"
  shift
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -H "Accept: application/json, text/plain, */*" \
    "$@" "${url}"
}

# POST form（data 为 urlencoded 串，如 "a=1&b=2"）
http_post_form() {
  local url="$1" data="$2"
  shift 2
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "${data}" "$@" "${url}"
}

# POST JSON
http_post_json() {
  local url="$1" json="$2"
  shift 2
  http_request --max-time "${BUPTY_HTTP_TIMEOUT}" \
    -H "User-Agent: ${BUPTY_USER_AGENT}" \
    -H "Content-Type: application/json" \
    --data "${json}" "$@" "${url}"
}

# 提取单个响应头值（大小写不敏感，去 \r）。
http_header() {
  local name="$1"
  printf '%s\n' "${HTTP_HEADERS:-}" \
    | awk -v n="${name}" -F': ' 'tolower($1)==tolower(n){sub(/\r$/,"");print substr($0,index($0,": ")+2)}' \
    | head -1
}

# 收集全部 Set-Cookie（只取 name=value 段，忽略路径/过期等），以 "; " 连接。
http_set_cookies() {
  local cookies="" line
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    local name="${line%%;*}"
    if [[ -n "${name}" ]]; then
      if [[ -n "${cookies}" ]]; then cookies+="; "; fi
      cookies+="${name}"
    fi
  done < <(printf '%s\n' "${HTTP_HEADERS:-}" \
    | awk -F': ' 'tolower($1)=="set-cookie"{sub(/^[^:]*: /,"");print}')
  printf '%s' "${cookies}"
}

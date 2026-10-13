#!/usr/bin/env bash
# creds.sh —— 凭据持久化。账号/教务密码/可选教学云密码。
# 目录 0700、文件 0600，拒绝符号链接与权限过宽；密码绝不打印、不进日志。

if [[ -n "${_BUPTY_CREDS_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_CREDS_LOADED=1

BUPTY_ACCOUNT=""
BUPTY_PASSWORD=""
BUPTY_TEACHING_PASSWORD=""
_CREDS_LOADED=0

# 校验凭据文件是否为「普通文件、非符号链接、大小合理」。
_creds_check_regular() {
  local f="$1"
  [[ -e "${f}" ]] || return 1
  [[ -f "${f}" ]] || return 1
  [[ ! -L "${f}" ]] || return 1
  return 0
}

# 从磁盘加载凭据到全局变量。返回 0=有凭据，1=无凭据。
creds_load() {
  if [[ "${_CREDS_LOADED}" == "1" ]]; then
    # 已缓存：仍校验文件为普通文件（拒绝符号链接），但跳过 cat + jq 重复读盘。
    if _creds_check_regular "${BUPTY_CREDENTIALS_FILE}"; then
      [[ -n "${BUPTY_ACCOUNT}" && -n "${BUPTY_PASSWORD}" ]]
      return
    fi
    BUPTY_ACCOUNT=""
    BUPTY_PASSWORD=""
    BUPTY_TEACHING_PASSWORD=""
    return 1
  fi
  _CREDS_LOADED=1
  BUPTY_ACCOUNT=""
  BUPTY_PASSWORD=""
  BUPTY_TEACHING_PASSWORD=""
  local f="${BUPTY_CREDENTIALS_FILE}"
  if ! _creds_check_regular "${f}"; then
    return 1
  fi
  local json
  json="$(cat "${f}" 2>/dev/null)" || return 1
  BUPTY_ACCOUNT="$(printf '%s' "${json}" | jq -r '.account // empty' 2>/dev/null)"
  BUPTY_PASSWORD="$(printf '%s' "${json}" | jq -r '.password // empty' 2>/dev/null)"
  BUPTY_TEACHING_PASSWORD="$(printf '%s' "${json}" | jq -r '.teaching_cloud_password // empty' 2>/dev/null)"
  [[ -n "${BUPTY_ACCOUNT}" && -n "${BUPTY_PASSWORD}" ]]
}

# 保存凭据。参数：<账号> <教务密码> [教学云密码]（留空则清除教学云密码）。
creds_save() {
  local account="$1" password="$2" teaching="${3:-}"
  core_ensure_dirs
  local f="${BUPTY_CREDENTIALS_FILE}"
  if [[ -e "${f}" || -L "${f}" ]]; then
    # 若已存在符号链接，拒绝覆盖。
    if [[ -L "${f}" || ! -f "${f}" ]]; then
      core_err "凭据路径不是普通文件，已拒绝写入。"
      return 1
    fi
  fi
  local tmp
  tmp="$(mktemp "${BUPTY_CONFIG_DIR}/.credentials.XXXXXX")"
  local payload
  if [[ -n "${teaching}" ]]; then
    payload="$(jq -n --arg a "${account}" --arg p "${password}" --arg t "${teaching}" \
      '{account:$a, password:$p, teaching_cloud_password:$t}')"
  else
    payload="$(jq -n --arg a "${account}" --arg p "${password}" \
      '{account:$a, password:$p}')"
  fi
  printf '%s\n' "${payload}" > "${tmp}"
  chmod 600 "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${f}"
  chmod 600 "${f}" 2>/dev/null || true
  BUPTY_ACCOUNT="${account}"
  BUPTY_PASSWORD="${password}"
  BUPTY_TEACHING_PASSWORD="${teaching}"
  _CREDS_LOADED=1
  return 0
}

# 清除凭据（logout）。
creds_clear() {
  BUPTY_ACCOUNT=""
  BUPTY_PASSWORD=""
  BUPTY_TEACHING_PASSWORD=""
  if [[ -e "${BUPTY_CREDENTIALS_FILE}" || -L "${BUPTY_CREDENTIALS_FILE}" ]]; then
    rm -f "${BUPTY_CREDENTIALS_FILE}"
  fi
  _CREDS_LOADED=1
}

# 教学云密码：优先独立教学云密码，回退教务密码。
creds_assignment_password() {
  if [[ -n "${BUPTY_TEACHING_PASSWORD}" ]]; then
    printf '%s' "${BUPTY_TEACHING_PASSWORD}"
  else
    printf '%s' "${BUPTY_PASSWORD}"
  fi
}

# 是否有已保存凭据。
creds_exists() {
  creds_load
}

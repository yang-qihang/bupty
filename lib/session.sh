#!/usr/bin/env bash
# session.sh —— 会话状态管理（仅内存，不落盘）。SJD 与 UCloud 令牌缓存。
# 过期时由对应 fetch 函数失效并重登一次；本文件只负责持有状态。

if [[ -n "${_BUPTY_SESSION_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_SESSION_LOADED=1

# SJD（教务）
BUPTY_SJD_TOKEN=""
BUPTY_SJD_ACCOUNT=""

# UCloud（教学云）
BUPTY_UCLOUD_TOKEN=""
BUPTY_UCLOUD_USER_ID=""
BUPTY_UCLOUD_ACCOUNT=""

# 图书馆研讨间预约（order.bupt.edu.cn，仅内存 + 临时 cookie jar）。
BUPTY_BOOKING_TOKEN=""
BUPTY_BOOKING_ACC_NO=""
BUPTY_BOOKING_ACCOUNT=""
BUPTY_BOOKING_COOKIE_JAR=""

# SJD 令牌：输出当前令牌或空。
sjd_session_get() {
  printf '%s' "${BUPTY_SJD_TOKEN}"
}

# SJD 令牌是否属于某账号。
sjd_session_owned_by() {
  local account="$1"
  [[ -n "${BUPTY_SJD_TOKEN}" && "${BUPTY_SJD_ACCOUNT}" == "${account}" ]]
}

sjd_session_set() {
  BUPTY_SJD_TOKEN="$1"
  BUPTY_SJD_ACCOUNT="$2"
}

sjd_session_clear() {
  BUPTY_SJD_TOKEN=""
  BUPTY_SJD_ACCOUNT=""
}

# UCloud 令牌。
ucloud_session_get() {
  printf '%s' "${BUPTY_UCLOUD_TOKEN}"
}

ucloud_session_owned_by() {
  local account="$1"
  [[ -n "${BUPTY_UCLOUD_TOKEN}" && "${BUPTY_UCLOUD_ACCOUNT}" == "${account}" ]]
}

ucloud_session_set() {
  BUPTY_UCLOUD_TOKEN="$1"
  BUPTY_UCLOUD_USER_ID="$2"
  BUPTY_UCLOUD_ACCOUNT="$3"
}

ucloud_session_clear() {
  BUPTY_UCLOUD_TOKEN=""
  BUPTY_UCLOUD_USER_ID=""
  BUPTY_UCLOUD_ACCOUNT=""
}

# 图书馆研讨间预约会话（token / accNo / 账号 / cookie jar 路径）。
booking_session_get_token() {
  printf '%s' "${BUPTY_BOOKING_TOKEN}"
}

booking_session_get_acc_no() {
  printf '%s' "${BUPTY_BOOKING_ACC_NO}"
}

booking_session_owned_by() {
  local account="$1"
  [[ -n "${BUPTY_BOOKING_TOKEN}" && "${BUPTY_BOOKING_ACCOUNT}" == "${account}" ]]
}

booking_session_set() {
  BUPTY_BOOKING_TOKEN="$1"
  BUPTY_BOOKING_ACC_NO="$2"
  BUPTY_BOOKING_ACCOUNT="$3"
  BUPTY_BOOKING_COOKIE_JAR="$4"
}

booking_session_clear() {
  BUPTY_BOOKING_TOKEN=""
  BUPTY_BOOKING_ACC_NO=""
  BUPTY_BOOKING_ACCOUNT=""
  if [[ -n "${BUPTY_BOOKING_COOKIE_JAR:-}" ]]; then
    rm -f "${BUPTY_BOOKING_COOKIE_JAR}" 2>/dev/null || true
  fi
  BUPTY_BOOKING_COOKIE_JAR=""
}

# 登出时清空全部会话。
session_clear_all() {
  sjd_session_clear
  ucloud_session_clear
  booking_session_clear
}

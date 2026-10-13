#!/usr/bin/env bash
# core.sh —— 常量、路径、日志、错误处理、ANSI 颜色基础工具。
# 无网络依赖，被其它所有 lib 文件 source。

set -euo pipefail

# 已 source 保护：同一进程只加载一次。
if [[ -n "${_BUPTY_CORE_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_CORE_LOADED=1

BUPTY_VERSION="0.1.0"
BUPTY_NAME="bupty"

# 全局错误信息（人类可读），供视图状态栏展示。
BUPTY_ERR=""

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

# 安装目录（本仓库根，由 bin/bupty 设置后各文件可引用）。
BUPTY_HOME="${BUPTY_HOME:-}"

# 配置根目录：尊重 XDG_CONFIG_HOME，默认 ~/.config
_bupty_config_root() {
  if [[ -n "${XDG_CONFIG_HOME:-}" && -d "${XDG_CONFIG_HOME}" ]]; then
    printf '%s' "${XDG_CONFIG_HOME}"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s/.config' "${HOME}"
  else
    printf '%s' "/tmp"
  fi
}

BUPTY_CONFIG_DIR="${BUPTY_CONFIG_DIR:-$(_bupty_config_root)/${BUPTY_NAME}}"
BUPTY_CACHE_DIR="${BUPTY_CONFIG_DIR}/cache"
BUPTY_CREDENTIALS_FILE="${BUPTY_CONFIG_DIR}/credentials.json"
BUPTY_SETTINGS_FILE="${BUPTY_CONFIG_DIR}/settings.json"
BUPTY_FAVORITES_FILE="${BUPTY_CONFIG_DIR}/favorite-events.json"
# 后台通知去重状态：已通知作业 id -> 截止日期（YYYY-MM-DD）。
BUPTY_NOTIFIED_FILE="${BUPTY_CONFIG_DIR}/notified.json"

# 确保配置目录存在（凭据目录 0700）。
core_ensure_dirs() {
  if [[ ! -d "${BUPTY_CONFIG_DIR}" ]]; then
    mkdir -p "${BUPTY_CONFIG_DIR}"
    chmod 700 "${BUPTY_CONFIG_DIR}" 2>/dev/null || true
  fi
  mkdir -p "${BUPTY_CACHE_DIR}"
}

# ---------------------------------------------------------------------------
# 错误 / 日志
# ---------------------------------------------------------------------------

# 设置错误信息（不打印，供 UI 展示）。
core_err() {
  BUPTY_ERR="$*"
}

# 清空错误信息。
core_clear_err() {
  BUPTY_ERR=""
}

# 调试日志（仅 BUPTY_DEBUG=1 时输出到 stderr）。
core_log() {
  if [[ "${BUPTY_DEBUG:-0}" == "1" ]]; then
    printf '[bupty] %s\n' "$*" >&2
  fi
}

# ---------------------------------------------------------------------------
# ANSI 颜色基础
# ---------------------------------------------------------------------------

# 终端是否支持颜色（写入文件/管道时关闭，避免污染快照）。
_bupty_tty() { [[ -t 1 ]]; }

# SGR 序列。用法：core_sgr <fg> [bg|attr...]
# 首参为 256 色前景索引；其余参数中数字为背景索引，关键字为属性（bold/dim/italic/underline）。
core_sgr() {
  local fg="${1:-}"
  shift
  local bg="" arg codes=()
  for arg in "$@"; do
    case "${arg}" in
      bold) codes+=(1) ;;
      dim) codes+=(2) ;;
      italic) codes+=(3) ;;
      underline) codes+=(4) ;;
      [0-9]*) bg="${arg}" ;;
    esac
  done
  [[ -n "${fg}" ]] && codes+=(38 5 "${fg}")
  [[ -n "${bg}" ]] && codes+=(48 5 "${bg}")
  if [[ ${#codes[@]} -eq 0 ]]; then
    printf '\033[0m'
  else
    printf '\033[%sm' "$(printf '%s;' "${codes[@]}" | sed 's/;$//')"
  fi
}

# 便捷常量。
core_c_reset() { printf '\033[0m'; }
core_c_bold() { printf '\033[1m'; }
core_c_dim() { printf '\033[2m'; }

# ---------------------------------------------------------------------------
# 文本工具
# ---------------------------------------------------------------------------

# 去除字符串首尾空白。
core_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# 字符串是否为空（含纯空白）。
core_is_blank() {
  [[ -z "${1:-}" || -z "$(core_trim "${1:-}")" ]]
}

# 计算显示宽度：码点 > 255（CJK/全角等）计 2 列，其余（ASCII/Latin-1）计 1 列。
# 用 printf -v（内建，无 fork/子 shell）取码点。
_core_width() {
  local s="${1:-}" w=0 i ch cp
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    printf -v cp '%d' "'${ch}"
    if (( cp > 255 )); then w=$((w + 2)); else w=$((w + 1)); fi
  done
  _CORE_W=$w
}

# 截断显示宽度（中文按 2 列计）。参数：<文本> <最大宽度>
core_pad() {
  local s="${1:-}" width="${2:-0}"
  (( width < 0 )) && width=0
  _core_width "${s}"
  printf '%*s' "$((width > _CORE_W ? width - _CORE_W : 0))" ''
}

# 按显示宽度截断文本并补空格到指定宽度（中文按 2 列）。
# 单趟扫描截断，避免超宽行逐字符回退造成的 O(n²) 卡顿。
# 无 fork 计算内核：结果写入全局 _CORE_FIT_OUT（已含补齐空格），供渲染热循环直接取用。
_core_fit_compute() {
  local s="${1:-}" width="${2:-0}"
  (( width < 0 )) && width=0
  local out="" w=0 i ch cp cw pad
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    printf -v cp '%d' "'${ch}"
    if (( cp > 255 )); then cw=2; else cw=1; fi
    if (( w + cw > width )); then break; fi
    out+="${ch}"
    w=$((w + cw))
  done
  pad=$(( width - w ))
  (( pad < 0 )) && pad=0
  printf -v _CORE_FIT_OUT '%s%*s' "${out}" "${pad}" ''
}

core_fit() {
  _core_fit_compute "${1:-}" "${2:-0}"
  printf '%s' "${_CORE_FIT_OUT}"
}

# 判断是否为 UTF-8 终端（决定是否用 Unicode 盒子字符）。
core_utf8() {
  case "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" in
    *UTF-8* | *UTF8* | *utf-8* | *utf8*) return 0 ;;
  esac
  [[ "${BUPTY_FORCE_UTF8:-0}" == "1" ]]
}

# ---------------------------------------------------------------------------
# 时间 / 日期
# ---------------------------------------------------------------------------

# 北京时间今天（YYYY-MM-DD）。依赖系统时区，若不可用用 date -d TZ 兜底。
core_today() {
  TZ=Asia/Shanghai date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d
}

# 北京时间当前 HH:MM。
core_now_hm() {
  TZ=Asia/Shanghai date +%H:%M 2>/dev/null || date +%H:%M
}

# 北京时间当前 RFC3339（秒精度）。
core_now_rfc3339() {
  TZ=Asia/Shanghai date +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%:z
}

# 星期几（1=周一..7=周日）。
core_weekday() {
  local d="${1:-$(core_today)}"
  local w
  w=$(TZ=Asia/Shanghai date -d "${d}" +%u 2>/dev/null || date -d "${d}" +%u)
  printf '%s' "${w}"
}

# 距今天数（正=未来）。日期 a - 日期 b。
core_days_between() {
  local a="${1}" b="${2}"
  local ea eb
  ea=$(date -d "${a}" +%s 2>/dev/null || echo 0)
  eb=$(date -d "${b}" +%s 2>/dev/null || echo 0)
  printf '%s' "$(( (ea - eb) / 86400 ))"
}

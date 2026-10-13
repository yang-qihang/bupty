#!/usr/bin/env bash
# settings.sh —— 持久化设置（settings.json）与 XDG 开机自启动（.desktop）。
# 用 jq 读写、临时文件 + mv 原子替换；损坏的 JSON 安全回退默认值。

if [[ -n "${_BUPTY_SETTINGS_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_SETTINGS_LOADED=1

# 内存中的设置 JSON（settings_load 填充，settings_save 落盘）。
BUPTY_SETTINGS_JSON=""

# XDG autostart 目录（尊重 XDG_CONFIG_HOME，默认 ~/.config/autostart）。
_autostart_dir() {
  printf '%s/autostart' "$(_bupty_config_root)"
}
BUPTY_AUTOSTART_FILE="$(_autostart_dir)/bupty.desktop"

# 默认设置。
_settings_default_json() {
  jq -n '{autostart_enabled:false, notify_enabled:false, notify_interval:60, theme:"dark"}'
}

# 从磁盘加载设置到 BUPTY_SETTINGS_JSON。0=有效文件；1=缺失/损坏（回退默认值）。
settings_load() {
  local f="${BUPTY_SETTINGS_FILE}"
  if [[ -f "${f}" && ! -L "${f}" ]]; then
    local j
    j="$(cat "${f}" 2>/dev/null)" || { BUPTY_SETTINGS_JSON="$(_settings_default_json)"; return 1; }
    BUPTY_SETTINGS_JSON="$(printf '%s' "${j}" | jq -c '
      {
        autostart_enabled: (((.autostart_enabled // false) == true)),
        notify_enabled: (((.notify_enabled // false) == true)),
        notify_interval: (((.notify_interval // 60) | tonumber? // 60)),
        theme: (if (.theme | type) == "string" then .theme else "dark" end)
      }' 2>/dev/null)" || { BUPTY_SETTINGS_JSON="$(_settings_default_json)"; return 1; }
    return 0
  fi
  BUPTY_SETTINGS_JSON="$(_settings_default_json)"
  return 1
}

# 原子写入当前设置（临时文件 + mv）。
settings_save() {
  core_ensure_dirs
  local f="${BUPTY_SETTINGS_FILE}"
  if [[ -e "${f}" || -L "${f}" ]]; then
    # 拒绝覆盖符号链接 / 非普通文件。
    if [[ -L "${f}" || ! -f "${f}" ]]; then
      core_err "设置路径不是普通文件，已拒绝写入。"
      return 1
    fi
  fi
  local tmp
  tmp="$(mktemp "${BUPTY_CONFIG_DIR}/.settings.XXXXXX")"
  printf '%s\n' "${BUPTY_SETTINGS_JSON}" > "${tmp}"
  mv -f "${tmp}" "${f}"
  return 0
}

# 读取单个键，输出字符串（布尔键输出 "true"/"false"，数字键输出数字）。
settings_get() {
  local key="$1"
  settings_load || true
  printf '%s' "${BUPTY_SETTINGS_JSON}" | jq -r --arg k "${key}" '.[$k] | tostring' 2>/dev/null
}

# 设置单个键并落盘。布尔键接受 "true"/"false"；notify_interval 接受数字串。
settings_set() {
  local key="$1" value="$2"
  settings_load || true
  case "${key}" in
    autostart_enabled|notify_enabled)
      BUPTY_SETTINGS_JSON="$(printf '%s' "${BUPTY_SETTINGS_JSON}" | jq -c --arg k "${key}" --arg v "${value}" \
        '.[$k] = ($v == "true")' 2>/dev/null)" || return 1
      ;;
    notify_interval)
      BUPTY_SETTINGS_JSON="$(printf '%s' "${BUPTY_SETTINGS_JSON}" | jq -c --arg k "${key}" --arg v "${value}" \
        '.[$k] = ([1, (($v | tonumber?) // 60)] | max)' 2>/dev/null)" || return 1
      ;;
    theme)
      # 主题是枚举：合法名以 ui.sh 的 ui_theme_valid 为准（ui.sh 未加载时退回
      # 结构校验，保证 settings.sh 可独立使用）。非法名一律拒绝写入，
      # 避免 settings.json 里出现切不过去的主题名。
      if declare -F ui_theme_valid >/dev/null 2>&1; then
        ui_theme_valid "${value}" || return 1
      else
        [[ "${value}" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
      fi
      BUPTY_SETTINGS_JSON="$(printf '%s' "${BUPTY_SETTINGS_JSON}" | jq -c --arg k "${key}" --arg v "${value}" \
        '.[$k] = $v' 2>/dev/null)" || return 1
      ;;
    *)
      return 1
      ;;
  esac
  settings_save
}

# ---------------------------------------------------------------------------
# XDG 开机自启动（KDE / GNOME / XFCE 等主流桌面通用）
# ---------------------------------------------------------------------------

# 入口可执行文件路径：优先 ~/.local/bin/bupty（若存在），否则仓库 bin/bupty。
_bupty_exec_path() {
  if [[ -n "${HOME:-}" && -e "${HOME}/.local/bin/bupty" ]]; then
    printf '%s/.local/bin/bupty' "${HOME}"
  else
    printf '%s/bin/bupty' "${BUPTY_HOME}"
  fi
}

# 启用自启动：写 .desktop 并置位 autostart_enabled（原子写、拒绝符号链接）。
autostart_enable() {
  local dir f
  dir="$(_autostart_dir)"
  f="${BUPTY_AUTOSTART_FILE}"
  mkdir -p "${dir}" 2>/dev/null || { core_err "无法创建自启动目录。"; return 1; }
  if [[ -L "${f}" ]]; then
    core_err "自启动文件是符号链接，已拒绝写入。"
    return 1
  fi
  local exec_path tmp
  exec_path="$(_bupty_exec_path)"
  tmp="$(mktemp "${dir}/.bupty.desktop.XXXXXX")"
  {
    printf '[Desktop Entry]\n'
    printf 'Type=Application\n'
    printf 'Name=bupty\n'
    printf 'Comment=北邮一站式信息查询\n'
    printf 'Exec="%s" --background\n' "${exec_path}"
    printf 'Hidden=false\n'
    printf 'X-GNOME-Autostart-enabled=true\n'
    printf 'Terminal=false\n'
  } > "${tmp}" || { rm -f "${tmp}"; core_err "无法写入自启动文件。"; return 1; }
  mv -f "${tmp}" "${f}" || { rm -f "${tmp}"; core_err "无法提交自启动文件。"; return 1; }
  settings_set autostart_enabled true
}

# 禁用自启动：删除 .desktop 并清除 autostart_enabled。
autostart_disable() {
  rm -f "${BUPTY_AUTOSTART_FILE}"
  settings_set autostart_enabled false
}

# 当前是否已启用自启动（以设置标志为准）。
autostart_is_enabled() {
  [[ "$(settings_get autostart_enabled)" == "true" ]]
}

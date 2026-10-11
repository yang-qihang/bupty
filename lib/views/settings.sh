#!/usr/bin/env bash
# views/settings.sh —— 设置页：账号 / 密码 / 教学云密码 的编辑与登录、登出。

# 编辑缓冲区（与已保存凭据分离）。
SETTINGS_ACCOUNT=""
SETTINGS_PASSWORD=""
SETTINGS_TEACHING=""

SETTINGS_ITEMS=(
  "account|账号"
  "password|教务密码"
  "teaching|教学云密码（可选）"
  "autostart|开机自启动"
  "notify|紧急 DDL 通知"
  "interval|通知检查频率"
  "login|登录"
  "logout|登出"
)
SETTINGS_SEL=0

# 进入设置页时用已保存凭据填充编辑缓冲区。
settings_init() {
  if creds_load; then
    SETTINGS_ACCOUNT="${BUPTY_ACCOUNT}"
    SETTINGS_PASSWORD="${BUPTY_PASSWORD}"
    SETTINGS_TEACHING="${BUPTY_TEACHING_PASSWORD}"
  else
    SETTINGS_ACCOUNT="${BUPTY_ACCOUNT:-}"
    SETTINGS_PASSWORD=""
    SETTINGS_TEACHING=""
  fi
}

# 字段展示（密码打码）。
_settings_field_value() {
  case "$1" in
    account) printf '%s' "${SETTINGS_ACCOUNT}" ;;
    password) if [[ -n "${SETTINGS_PASSWORD}" ]]; then printf '已填写（隐藏）'; else printf '（未设置）'; fi ;;
    teaching) if [[ -n "${SETTINGS_TEACHING}" ]]; then printf '已填写（隐藏）'; else printf '（未设置，默认用教务密码）'; fi ;;
    autostart) if [[ "$(settings_get autostart_enabled)" == "true" ]]; then printf '开'; else printf '关'; fi ;;
    notify)
      if [[ "$(settings_get autostart_enabled)" != "true" ]]; then
        printf '（需先开启自启动）'
      elif [[ "$(settings_get notify_enabled)" == "true" ]]; then
        printf '开'
      else
        printf '关'
      fi
      ;;
    interval)
      if [[ "$(settings_get autostart_enabled)" != "true" ]]; then
        printf '（需先开启自启动）'
      else
        _settings_interval_label
      fi
      ;;
  esac
}

# 通知检查频率文案。
_settings_interval_label() {
  case "$(settings_get notify_interval)" in
    30) printf '30分钟' ;;
    60) printf '1小时' ;;
    180) printf '3小时' ;;
    *) printf '1小时' ;;
  esac
}

render_settings() {
  local i line key label val
  local items=("${SETTINGS_ITEMS[@]}")
  printf '\n'
  printf ' %s\n' "$(ui_paint title '账号设置')"
  printf '\n'
  for i in "${!items[@]}"; do
    IFS='|' read -r key label <<< "${items[$i]}"
    case "${key}" in
      login) val="▶ 使用当前账号密码登录" ;;
      logout) val="清除本地保存的凭据" ;;
      *) val="$(_settings_field_value "${key}")" ;;
    esac
    local text="${label}：${val}"
    if [[ "${i}" -eq "${SETTINGS_SEL}" ]]; then
      printf ' %s\n' "$(ui_paint hl "› $(core_fit "${text}" "$((UI_COLS - 4))")")"
    else
      printf '   %s  %s\n' "$(ui_paint accent "${label}")" "$(ui_paint text "$(core_fit "${val}" "$((UI_COLS - 24))")")"
    fi
  done
}

handle_settings_key() {
  local key="$1"
  local items=("${SETTINGS_ITEMS[@]}")
  local field
  IFS='|' read -r field _ <<< "${items[$SETTINGS_SEL]}"

  case "${key}" in
    UP) (( SETTINGS_SEL > 0 )) && (( SETTINGS_SEL -= 1 )) ;;
    DOWN) (( SETTINGS_SEL < ${#items[@]} - 1 )) && (( SETTINGS_SEL += 1 )) ;;
    ENTER)
      case "${field}" in
        account)
          ui_input "账号： " "${SETTINGS_ACCOUNT}" 0 32 || return 0
          SETTINGS_ACCOUNT="${UI_INPUT_RESULT}"
          ;;
        password)
          ui_input "教务密码： " "${SETTINGS_PASSWORD}" 1 128 || return 0
          SETTINGS_PASSWORD="${UI_INPUT_RESULT}"
          ;;
        teaching)
          ui_input "教学云密码（留空=用教务密码）： " "${SETTINGS_TEACHING}" 1 128 || return 0
          SETTINGS_TEACHING="${UI_INPUT_RESULT}"
          ;;
        autostart)
          if [[ "$(settings_get autostart_enabled)" == "true" ]]; then
            autostart_disable
            tui_set_status "已关闭开机自启动。"
          elif autostart_enable; then
            tui_set_status "已开启开机自启动。"
          else
            tui_set_status "${BUPTY_ERR:-开机自启动开启失败。}"
          fi
          ;;
        notify)
          if [[ "$(settings_get autostart_enabled)" != "true" ]]; then
            tui_set_status "需先开启自启动。"
          elif [[ "$(settings_get notify_enabled)" == "true" ]]; then
            settings_set notify_enabled false
            tui_set_status "已关闭紧急 DDL 通知。"
          else
            settings_set notify_enabled true
            tui_set_status "已开启紧急 DDL 通知。"
          fi
          ;;
        interval)
          if [[ "$(settings_get autostart_enabled)" != "true" ]]; then
            tui_set_status "需先开启自启动。"
          else
            case "$(settings_get notify_interval)" in
              30) settings_set notify_interval 60 ;;
              60) settings_set notify_interval 180 ;;
              180) settings_set notify_interval 30 ;;
              *) settings_set notify_interval 60 ;;
            esac
            tui_set_status "通知检查频率已更新。"
          fi
          ;;
        login)
          settings_login
          ;;
        logout)
          creds_clear
          session_clear_all
          SETTINGS_PASSWORD=""
          SETTINGS_TEACHING=""
          tui_set_status "已清除本地凭据。"
          ;;
      esac
      ;;
  esac
}

settings_login() {
  if core_is_blank "${SETTINGS_ACCOUNT}"; then
    core_err "请先填写学号。"
    return 1
  fi
  local pwd="${SETTINGS_PASSWORD}"
  # 密码留空则沿用已保存密码。
  if [[ -z "${pwd}" ]]; then
    creds_load || true
    pwd="${BUPTY_PASSWORD}"
  fi
  if core_is_blank "${pwd}"; then
    core_err "请填写教务密码。"
    return 1
  fi
  tui_set_status "正在登录教务…"
  tui_render
  if ! sjd_login "${SETTINGS_ACCOUNT}" "${pwd}"; then
    # BUPTY_ERR 已由 sjd_login 设置
    return 1
  fi
  creds_save "${SETTINGS_ACCOUNT}" "${pwd}" "${SETTINGS_TEACHING}"
  tui_set_status "登录成功，凭据已保存。"
  return 0
}

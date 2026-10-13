#!/usr/bin/env bash
# views/settings.sh —— 设置页：账号 / 密码 / 教学云密码 的编辑与登录、登出，
# 以及配色方案（枚举）与自启动 / 通知等开关。

# 编辑缓冲区（与已保存凭据分离）。
SETTINGS_ACCOUNT=""
SETTINGS_PASSWORD=""
SETTINGS_TEACHING=""

SETTINGS_ITEMS=(
  "account|账号"
  "password|教务密码"
  "teaching|教学云密码（可选）"
  "theme|配色方案|enum"
  "autostart|开机自启动"
  "notify|紧急 DDL 通知"
  "interval|通知检查频率"
  "login|登录"
  "logout|登出"
)
SETTINGS_SEL=0
# 条目列表的滑动窗口起点（终端太矮时只渲染其中一段，见 render_settings）。
SETTINGS_OFFSET=0

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
    theme) ui_theme_label "$(_settings_theme_current)" ;;
  esac
}

# 当前保存的配色方案名（缺失/非法时退回默认主题），保证展示与循环起点一致。
_settings_theme_current() {
  local v=""
  v="$(settings_get theme 2>/dev/null)" || v=""
  if [[ -z "${v}" || "${v}" == "null" ]] || ! ui_theme_valid "${v}"; then
    printf '%s' "${UI_THEME_DEFAULT}"
  else
    printf '%s' "${v}"
  fi
}

# 循环切换配色方案（dir=next|prev），持久化后立即生效，无需重启。
_settings_cycle_theme() {
  local dir="${1:-next}" cur next
  cur="$(_settings_theme_current)"
  if [[ "${dir}" == "prev" ]]; then
    next="$(ui_theme_prev "${cur}")"
  else
    next="$(ui_theme_next "${cur}")"
  fi
  if settings_set theme "${next}"; then
    ui_theme_init "${next}"
    tui_set_status "已切换配色方案：$(ui_theme_label "${next}")。"
  else
    tui_set_status "配色方案切换失败。"
  fi
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
  local i key label val
  local items=("${SETTINGS_ITEMS[@]}")
  local total="${#items[@]}"

  # ---- 行预算 ----
  # 正文可用高度 = UI_ROWS - 5（帧顶/帧底等 5 行固定 chrome，见 docs/ARCHITECTURE.md）。
  # 本页顶部另有 3 行结构行（空行 / 标题 / 空行）。终端压得很矮时逐级砍掉结构行，
  # 把高度让给条目本身——宁可没有标题，也不要多渲染一行把帧顶穿。
  local body=$((UI_ROWS - 5))
  if (( body < 0 )); then body=0; fi
  local head=3
  if (( body < head + 1 )); then head=1; fi
  if (( body < head + 1 )); then head=0; fi
  local visible=$((body - head))

  # 选中项必须落在窗口内。窗口滑动的口径与 public.sh 一致：先保证选中项可见，
  # 再把起点钳回「总长 - 可见数」以内。assignments.sh 的窗口只做收尾钳制、没有这一步
  # 回钳，两处并不完全一样——早先这里写成「与 assignments / public 相同」并不准确。
  local offset="${SETTINGS_OFFSET:-0}"
  if (( SETTINGS_SEL < offset )); then offset=${SETTINGS_SEL}; fi
  if (( SETTINGS_SEL >= offset + visible )); then offset=$((SETTINGS_SEL - visible + 1)); fi
  if (( offset > total - visible )); then offset=$((total - visible)); fi
  if (( offset < 0 )); then offset=0; fi
  SETTINGS_OFFSET=${offset}

  # 标题行同样受宽度预算约束：极窄终端上「账号设置」自己就有 8 列，不截断就顶破右边界。
  # 只在真的放不下时才 core_fit——它会补齐空格，宽终端下无脑套用会多出尾随空格，
  # 破坏与改动前逐字节一致的渲染。前导空格保持不上色（title 只有前景色，上色与否不可见）。
  local ttext='账号设置'
  if (( head >= 1 )); then
    _core_width "${ttext}"
    if (( _CORE_W > UI_COLS - 1 )); then
      local tbudget=$(( UI_COLS - 1 ))
      if (( tbudget < 0 )); then tbudget=0; fi
      ttext="$(core_fit "${ttext}" "${tbudget}")"
    fi
  fi
  if (( head >= 3 )); then
    printf '\n'
    if (( UI_COLS >= 1 )); then printf ' %s\n' "$(ui_paint title "${ttext}")"; fi
    printf '\n'
  elif (( head == 1 )); then
    if (( UI_COLS >= 1 )); then printf ' %s\n' "$(ui_paint title "${ttext}")"; fi
  fi

  # ---- 列预算 ----
  # 未选中行形如「   label  val」：缩进 + 标签 + 间隔 + 值，四段共用 UI_COLS 这一个预算。
  # 极窄终端下先把固定的缩进/间隔让出去（否则硬编码的 3+2 列自身就把整行顶出右边界），
  # 再把剩下的列分给标签与值。值的额度沿用 UI_COLS - 24，从而宽终端下与改动前逐字节一致。
  local pre_indent=3 pre_gap=2
  if (( pre_indent + pre_gap > UI_COLS )); then
    pre_indent=$(( UI_COLS < 3 ? UI_COLS : 3 ))
    pre_gap=$(( UI_COLS - pre_indent ))
    if (( pre_gap < 0 )); then pre_gap=0; fi
  fi
  local avail=$((UI_COLS - pre_indent - pre_gap))
  if (( avail < 0 )); then avail=0; fi
  local val_budget=$((UI_COLS - 24))
  if (( val_budget > avail - 1 )); then val_budget=$((avail - 1)); fi
  if (( val_budget < 0 )); then val_budget=0; fi
  local label_budget=$((avail - val_budget))

  local end=$((offset + visible))
  if (( end > total )); then end=${total}; fi
  for ((i = offset; i < end; i++)); do
    # 元素格式：key|标签[|类型]（类型目前只有 enum，用于配色方案）。
    IFS='|' read -r key label _ <<< "${items[$i]}"
    case "${key}" in
      login) val="▶ 使用当前账号密码登录" ;;
      logout) val="清除本地保存的凭据" ;;
      *) val="$(_settings_field_value "${key}")" ;;
    esac
    if [[ "${i}" -eq "${SETTINGS_SEL}" ]]; then
      local text="${label}：${val}"
      if (( UI_COLS >= 4 )); then
        printf ' %s\n' "$(ui_paint hl "› $(core_fit "${text}" "$((UI_COLS - 4))")")"
      elif (( UI_COLS >= 1 )); then
        # 连「 › 」都放不下：丢掉标记，只留截断后的正文，保证行宽 <= UI_COLS。
        printf '%s\n' "$(ui_paint hl "$(core_fit "${text}" "${UI_COLS}")")"
      fi
    else
      # 只在标签真的超预算时才截断：core_fit 会补齐空格，无脑套用会把宽终端下
      # 原本紧挨着的「标签  值」撑开，破坏与改动前一致的观感。
      _core_width "${label}"
      if (( _CORE_W > label_budget )); then
        label="$(core_fit "${label}" "${label_budget}")"
      fi
      printf '%*s%s%*s%s\n' \
        "${pre_indent}" '' \
        "$(ui_paint accent "${label}")" \
        "${pre_gap}" '' \
        "$(ui_paint text "$(core_fit "${val}" "${val_budget}")")"
    fi
  done
}

handle_settings_key() {
  local key="$1"
  local items=("${SETTINGS_ITEMS[@]}")
  local field type
  IFS='|' read -r field _ type <<< "${items[$SETTINGS_SEL]}"

  case "${key}" in
    UP) (( SETTINGS_SEL > 0 )) && (( SETTINGS_SEL -= 1 )) ;;
    DOWN) (( SETTINGS_SEL < ${#items[@]} - 1 )) && (( SETTINGS_SEL += 1 )) ;;
    LEFT|RIGHT)
      # 枚举项（配色方案）：方向键也能来回切换；其余项无左右语义。
      if [[ "${type}" == "enum" ]]; then
        if [[ "${key}" == "RIGHT" ]]; then
          _settings_cycle_theme next
        else
          _settings_cycle_theme prev
        fi
      fi
      ;;
    ENTER)
      case "${field}" in
        theme)
          _settings_cycle_theme next
          ;;
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

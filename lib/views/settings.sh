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

# ---- 主题选择器状态（列表 + 实时预览，见 render_settings / handle_settings_key） ----
# 选择器是否打开：0=关闭（正常设置页），1=打开（render_settings 整屏接管为 10 项主题列表）。
SETTINGS_PICKER=0
# 选择器打开时光标在 UI_THEME_NAMES 里的下标（↑↓ 移动后即实时预览的候选下标）。
SETTINGS_PICKER_SEL=0
# 打开选择器那一刻的已应用主题名（Esc 还原用，不落盘）。
SETTINGS_PICKER_ORIG=""
# 选择器列表的滑动窗口起点（与 SETTINGS_OFFSET 同口径，终端太矮时只渲染放得下的一段）。
SETTINGS_PICKER_OFFSET=0

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

# 打开主题选择器：光标定位到当前**已应用**主题，并记录进入时的主题名用于 Esc 还原。
# 注意这里用 UI_THEME（当前应用的主题）而不是 _settings_theme_current（已保存主题）：
# 两者在刚进入设置页时一致；若此前用户在别的路径切过主题（←→ 快路径），
# 选择器应从「当前看到的样子」继续，而不是从落盘值跳回去。
_settings_picker_open() {
  SETTINGS_PICKER_SEL="$(ui_theme_index "${UI_THEME}")"
  # ui_theme_index 对未知名返回 -1；UI_THEME 由 ui_theme_apply 写入、恒合法，兜底钳到 0。
  if (( SETTINGS_PICKER_SEL < 0 )); then SETTINGS_PICKER_SEL=0; fi
  SETTINGS_PICKER_ORIG="${UI_THEME}"
  # 每次打开从窗口起点 0 开始，避免沿用上次滚动残留的偏移。
  SETTINGS_PICKER_OFFSET=0
  SETTINGS_PICKER=1
}

# 确认保存选择器当前光标项并关闭选择器。
# 实时预览已在 UP/DOWN 时把 UI_THEME 切到候选，这里无需再 ui_theme_init；Enter 只负责落盘。
_settings_picker_confirm() {
  local name="${UI_THEME_NAMES[$SETTINGS_PICKER_SEL]}"
  if settings_set theme "${name}"; then
    tui_set_status "已保存配色方案：$(ui_theme_label "${name}")。"
  else
    # 实时预览已把内存里的 UI_THEME 切到候选；落盘失败的话，本次会话是候选色、
    # 磁盘上还是旧值，下次启动会对不上。回滚到选择器打开前的主题（SETTINGS_PICKER_ORIG），
    # 让「看到的」重新等于「存盘的」，并让状态栏说明是回滚，而不是留一个会漂移的状态。
    ui_theme_init "${SETTINGS_PICKER_ORIG}"
    tui_set_status "配色方案保存失败，已还原为 $(ui_theme_label "${SETTINGS_PICKER_ORIG}")。"
  fi
  SETTINGS_PICKER=0
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

# 主题选择器的渲染。render_settings 在选择态下整屏接管到这里，不再渲染设置条目。
# 结构与主列表同源：正文高度预算、3 行结构行逐级让位、选中项滑动窗口钳制全部照搬，
# 只是条目换成 UI_THEME_NAMES / UI_THEME_LABELS，选中行用「›」标记、未选中行用两空格对齐。
_render_settings_picker() {
  local i label
  local total="${#UI_THEME_NAMES[@]}"

  # ---- 行预算 ----
  # 正文可用高度 = UI_ROWS - 5（帧顶/帧底等 5 行固定 chrome，见 docs/ARCHITECTURE.md）。
  # 顶部另有 3 行结构行（空行 / 标题 / 空行），终端压得很矮时逐级砍掉让位给列表。
  local body=$((UI_ROWS - 5))
  if (( body < 0 )); then body=0; fi
  local head=3
  if (( body < head + 1 )); then head=1; fi
  if (( body < head + 1 )); then head=0; fi
  local visible=$((body - head))

  # 选中项必须落在窗口内。窗口滑动口径与主列表 SETTINGS_OFFSET 完全一致：
  # 先保证选中项可见，再把起点钳回「总长 - 可见数」以内。
  local offset="${SETTINGS_PICKER_OFFSET:-0}"
  if (( SETTINGS_PICKER_SEL < offset )); then offset=${SETTINGS_PICKER_SEL}; fi
  if (( SETTINGS_PICKER_SEL >= offset + visible )); then offset=$((SETTINGS_PICKER_SEL - visible + 1)); fi
  if (( offset > total - visible )); then offset=$((total - visible)); fi
  if (( offset < 0 )); then offset=0; fi
  SETTINGS_PICKER_OFFSET=${offset}

  # 标题行同样受宽度预算约束：极窄终端下「选择配色方案」自己就有 12 列，
  # 不截断就顶破右边界。只在真的放不下时才 core_fit，避免多出尾随空格。
  local ttext='选择配色方案'
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
  # 选中行形如「 › label」、未选中行「   label」，两者前缀都是 3 列（1 前导空格 + 2 标记列）。
  # 「›」（U+203A）在本引擎里恒按 1 列算（core.sh 对它特判为窄），所以 2 标记列恒成立。
  # 极窄终端下先让出这 3 列，剩余全给标签；连 3 列都放不下时丢掉标记，只留标签本身。
  local end=$((offset + visible))
  if (( end > total )); then end=${total}; fi
  for ((i = offset; i < end; i++)); do
    label="${UI_THEME_LABELS[$i]}"
    if (( i == SETTINGS_PICKER_SEL )); then
      if (( UI_COLS >= 4 )); then
        # 选中行：整行背景高亮（沿用主列表选中行的 UI_HL_FG 口径），core_fit 补齐到满列。
        printf ' %s\n' "$(ui_paint hl "› $(core_fit "${label}" "$((UI_COLS - 4))")")"
      elif (( UI_COLS >= 1 )); then
        # 连「 › 」都放不下：丢掉标记，只留截断后的标签，保证行宽 <= UI_COLS。
        printf '%s\n' "$(ui_paint hl "$(core_fit "${label}" "${UI_COLS}")")"
      fi
    else
      if (( UI_COLS >= 4 )); then
        # 未选中行：两空格对齐。只用 core_clip（超预算才截断），不补尾随空格。
        printf ' %s\n' "$(ui_paint accent "  $(core_clip "${label}" "$((UI_COLS - 4))")")"
      elif (( UI_COLS >= 1 )); then
        printf '%s\n' "$(ui_paint accent "$(core_clip "${label}" "${UI_COLS}")")"
      fi
    fi
  done
}

render_settings() {
  # 选择器打开时整屏接管为 10 项主题列表，不再渲染设置条目。
  if (( ${SETTINGS_PICKER:-0} )); then
    _render_settings_picker
    return 0
  fi

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

  # ---- 选择器打开时的按键分流 ----
  # 选择态下只认 UP/DOWN/ENTER，其余键一律忽略（不落到下面设置页的处理逻辑上）。
  # Esc 不在这里处理：tui_main 的全局 case 里 ESC 先于本函数命中，改走 handle_settings_escape。
  # 已知取舍（如实记录，不假装不存在）：q 与 Tab 也是 tui_main 的全局键，同样先于本函数
  # 被吃掉——选择器打开时按 q 仍会退出程序、按 Tab 仍会切页，与全站「q 总是退出」一致，
  # 本轮接受；要拦就得改 tui.sh 的全局 case，会破坏并行解耦，故不做。
  if (( ${SETTINGS_PICKER:-0} )); then
    case "${key}" in
      UP)
        # 到顶不循环（与主列表 UP/DOWN 的边界口径一致；循环留给 ←→ 快路径）。
        if (( SETTINGS_PICKER_SEL > 0 )); then
          (( SETTINGS_PICKER_SEL -= 1 ))
          ui_theme_init "${UI_THEME_NAMES[$SETTINGS_PICKER_SEL]}"
        fi
        ;;
      DOWN)
        if (( SETTINGS_PICKER_SEL < ${#UI_THEME_NAMES[@]} - 1 )); then
          (( SETTINGS_PICKER_SEL += 1 ))
          # 实时预览：只改内存里的主题角色（所见即所得），不落盘。
          ui_theme_init "${UI_THEME_NAMES[$SETTINGS_PICKER_SEL]}"
        fi
        ;;
      ENTER)
        _settings_picker_confirm
        ;;
      *) ;;
    esac
    return 0
  fi

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
          _settings_picker_open
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

# Esc 接管：tui_main 的全局 case 里 ESC|BACKSPACE 先于页面的 handle_settings_key 命中，
# 所以 Esc 平时到不了设置页。tui.sh 提供通用钩子——它会先调用 handle_<view>_escape，
# 返回 0 = 这次 Esc 被页面消费（不返回上一页）；未定义或返回非 0 = 维持默认「返回上一页」。
# 本函数**总是被定义**（不能只在选择器开着时才存在），行为才确定：
#   选择器开着：还原成进入时的主题（不落盘）、关掉选择器、返回 0（消费掉这次 Esc）。
#   否则：返回 1，交回默认的「返回上一页」。
# set -euo pipefail 下，调用方用 `if ... && handle_settings_escape; then` 接住，
# 这里的非 0 返回处于 if 条件里，不会触发退出，是安全的。
handle_settings_escape() {
  if (( ${SETTINGS_PICKER:-0} )); then
    ui_theme_init "${SETTINGS_PICKER_ORIG}"
    SETTINGS_PICKER=0
    # 还原主题、关掉选择器后必须给状态栏一句话：画面瞬间变回原配色但状态栏不吭声，
    # 用户会以为卡了或没按上。Enter 保存路径有提示，Esc 撤销路径也要有，二者对称。
    tui_set_status "已取消，配色未更改。"
    return 0
  fi
  return 1
}

# 页脚快捷键提示的页面覆盖点（tui.sh 的 footer_hint_<view> 钩子）。
# 选择器打开时这行的键位语义变了：Enter 不再是「进入」而是「保存」，Esc 不再是「返回」
# 而是「撤销」——沿用设置页默认串的话，用户就会像验收时那样「看不到自己可以 Enter 切换」。
# 因此打开态输出与选择器真实键位一致的短提示；关闭态输出空串，页脚自动落回默认串，
# 不在本文件里重复默认串（否则默认串将来一改，这里不跟着改就会漂移）。
# 提示串比默认串短：窄终端下 core_fit 才不会把「q 退出」截成「q 退」这种半截字。
footer_hint_settings() {
  if (( ${SETTINGS_PICKER:-0} )); then
    printf '%s' '↑↓ 选择 · Enter 保存 · Esc 撤销 · q 退出'
  fi
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

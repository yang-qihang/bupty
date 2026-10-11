#!/usr/bin/env bash
# ui.sh —— TUI 渲染原语：主题配色、终端模式、清屏、盒子、按键读取、文本输入。

if [[ -n "${_BUPTY_UI_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_UI_LOADED=1

# ---------------------------------------------------------------------------
# 主题
# ---------------------------------------------------------------------------

# 主题角色 SGR 前缀变量：UI_ACCENT / UI_TEXT / UI_MUTED / UI_BORDER /
# UI_HL(选中背景) / UI_HL_FG(选中前景) / UI_SUCCESS / UI_WARNING / UI_DANGER / UI_TITLE
UI_ACCENT=""; UI_TEXT=""; UI_MUTED=""; UI_BORDER=""; UI_HL=""; UI_HL_FG=""
UI_SUCCESS=""; UI_WARNING=""; UI_DANGER=""; UI_TITLE=""
UI_RESET="$(core_c_reset)"

_ui_is_dark() {
  [[ "${BUPTY_THEME:-dark}" != "light" ]]
}

ui_theme_init() {
  if _ui_is_dark; then
    UI_ACCENT="$(core_sgr 39)"
    UI_TEXT="$(core_sgr 252)"
    UI_MUTED="$(core_sgr 244)"
    UI_BORDER="$(core_sgr 239)"
    UI_HL="$(core_sgr 0 24 bold)"
    UI_HL_FG="$(core_sgr 15 24 bold)"
    UI_SUCCESS="$(core_sgr 114)"
    UI_WARNING="$(core_sgr 215)"
    UI_DANGER="$(core_sgr 203)"
    UI_TITLE="$(core_sgr 39 bold)"
  else
    UI_ACCENT="$(core_sgr 26)"
    UI_TEXT="$(core_sgr 235)"
    UI_MUTED="$(core_sgr 242)"
    UI_BORDER="$(core_sgr 250)"
    UI_HL="$(core_sgr 0 33 bold)"
    UI_HL_FG="$(core_sgr 17 33 bold)"
    UI_SUCCESS="$(core_sgr 28)"
    UI_WARNING="$(core_sgr 208)"
    UI_DANGER="$(core_sgr 160)"
    UI_TITLE="$(core_sgr 26 bold)"
  fi
}

# 用指定角色着色文本。
ui_paint() {
  local role="$1" text="$2"
  local prefix=""
  case "${role}" in
    accent) prefix="${UI_ACCENT}" ;;
    text) prefix="${UI_TEXT}" ;;
    muted) prefix="${UI_MUTED}" ;;
    border) prefix="${UI_BORDER}" ;;
    hl) prefix="${UI_HL_FG}" ;;
    success) prefix="${UI_SUCCESS}" ;;
    warning) prefix="${UI_WARNING}" ;;
    danger) prefix="${UI_DANGER}" ;;
    title) prefix="${UI_TITLE}" ;;
    reset) prefix="${UI_RESET}" ;;
  esac
  printf '%s%s%s' "${prefix}" "${text}" "${UI_RESET}"
}

ui_bold() { printf '\033[1m%s\033[0m' "$1"; }
ui_dim() { printf '\033[2m%s\033[0m' "$1"; }

# ---------------------------------------------------------------------------
# 终端尺寸 / 模式
# ---------------------------------------------------------------------------

UI_ROWS=24
UI_COLS=80
_UI_SAVED_TTY=""

ui_size() {
  local sz=""
  sz="$(stty size 2>/dev/null)" || sz=""
  if [[ -n "${sz}" && "${sz}" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
    UI_ROWS="${sz%% *}"
    UI_COLS="${sz##* }"
  fi
}

ui_clear() {
  printf '\033[2J\033[H'
}

# 上移一行并清除（仅 TTY，避免污染管道/快照输出）。
ui_erase_prev_line() {
  if [[ -t 1 ]]; then
    printf '\033[1A\033[2K'
  fi
}

ui_hide_cursor() { printf '\033[?25l'; }
ui_show_cursor() { printf '\033[?25h'; }

# 进入 raw 模式（无回显、逐键）。
ui_raw_mode() {
  _UI_SAVED_TTY="$(stty -g 2>/dev/null)" || _UI_SAVED_TTY=""
  stty -echo -icanon min 1 time 0 2>/dev/null || true
}

# 退出 raw 模式。
ui_restore_mode() {
  if [[ -n "${_UI_SAVED_TTY}" ]]; then
    stty "${_UI_SAVED_TTY}" 2>/dev/null || true
    _UI_SAVED_TTY=""
  fi
  ui_show_cursor
}

# ---------------------------------------------------------------------------
# 盒子字符（Unicode / ASCII 回退）
# ---------------------------------------------------------------------------

_UI_BOX_H="─"; _UI_BOX_V="│"
_UI_BOX_TL="┌"; _UI_BOX_TR="┐"; _UI_BOX_BL="└"; _UI_BOX_BR="┘"
_UI_BOX_ML="├"; _UI_BOX_MR="┤"; _UI_BOX_MT="┬"; _UI_BOX_MB="┴"; _UI_BOX_MC="┼"

ui_box_init() {
  if ! core_utf8; then
    _UI_BOX_H="-"; _UI_BOX_V="|"
    _UI_BOX_TL="+"; _UI_BOX_TR="+"; _UI_BOX_BL="+"; _UI_BOX_BR="+"
    _UI_BOX_ML="+"; _UI_BOX_MR="+"; _UI_BOX_MT="+"; _UI_BOX_MB="+"; _UI_BOX_MC="+"
  fi
}

# 顶部边框：┌──── 标题 ─────┐
ui_box_top() {
  local width="$1" title="${2:-}"
  local inner=$((width - 2))
  printf '%s' "${UI_BORDER}"
  printf '%s' "${_UI_BOX_TL}"
  if [[ -n "${title}" ]]; then
    local t=" ${title} "
    printf '%s' "${t}"
    local remain=$((inner - $(core_fit_width "${t}") ))
    (( remain < 0 )) && remain=0
    local i
    for ((i = 0; i < remain; i++)); do printf '%s' "${_UI_BOX_H}"; done
  else
    local i
    for ((i = 0; i < inner; i++)); do printf '%s' "${_UI_BOX_H}"; done
  fi
  printf '%s' "${_UI_BOX_TR}"
  printf '%s\n' "${UI_RESET}"
}

# 底边框：└────────────┘
ui_box_bottom() {
  local width="$1"
  local inner=$((width - 2))
  local i
  printf '%s' "${UI_BORDER}"
  printf '%s' "${_UI_BOX_BL}"
  for ((i = 0; i < inner; i++)); do printf '%s' "${_UI_BOX_H}"; done
  printf '%s' "${_UI_BOX_BR}"
  printf '%s\n' "${UI_RESET}"
}

# 中间分隔：├────────────┤
ui_box_mid() {
  local width="$1"
  local inner=$((width - 2))
  local i
  printf '%s' "${UI_BORDER}"
  printf '%s' "${_UI_BOX_ML}"
  for ((i = 0; i < inner; i++)); do printf '%s' "${_UI_BOX_H}"; done
  printf '%s' "${_UI_BOX_MR}"
  printf '%s\n' "${UI_RESET}"
}

# 一行内容（带左右边框），内容按显示宽度补齐到 width-2。
ui_box_row() {
  local width="$1" text="${2:-}"
  local inner=$((width - 2))
  printf '%s' "${UI_BORDER}"
  printf '%s' "${_UI_BOX_V}"
  printf '%s' "${text}"
  printf '%s' "${_UI_BOX_V}"
  printf '%s\n' "${UI_RESET}"
}

# 显示宽度（中文 2 列）。纯 bash，无 fork。
core_fit_width() {
  local s="${1:-}"
  _core_width "${s}"
  printf '%s' "${_CORE_W}"
}

# 居中文本到指定宽度。
ui_center() {
  local width="$1" text="$2"
  local w
  w="$(core_fit_width "${text}")"
  local left=$(( (width - w) / 2 ))
  (( left < 0 )) && left=0
  local i
  for ((i = 0; i < left; i++)); do printf ' '; done
  printf '%s' "${text}"
}

# ---------------------------------------------------------------------------
# 按键读取
# ---------------------------------------------------------------------------

# 读取一个键，返回命名键（UP/DOWN/LEFT/RIGHT/PGUP/PGDN/HOME/END/TAB/ENTER/BACKSPACE/ESC）
# 或原始字符（如 "a"、"1"、"r"）。
# 可选第一个参数为超时秒数（>0 时超时返回 "TIMEOUT"，便于主循环检查 resize）。
ui_read_key() {
  local timeout="${1:-0}" k rest seq seq2 rc
  if [[ "${timeout}" != "0" ]]; then
    IFS= read -r -s -n1 -t "${timeout}" k
    rc=$?
    if (( rc > 128 )); then printf 'TIMEOUT'; return 0; fi
    if (( rc != 0 )); then printf 'EOF'; return 0; fi
  else
    IFS= read -r -s -n1 k || { printf 'EOF'; return 0; }
  fi
  case "${k}" in
    $'\e')
      IFS= read -r -s -n1 -t 0.02 rest 2>/dev/null || rest=""
      if [[ "${rest}" == "[" ]]; then
        IFS= read -r -s -n1 -t 0.02 seq 2>/dev/null || seq=""
        case "${seq}" in
          A) printf 'UP'; return 0 ;;
          B) printf 'DOWN'; return 0 ;;
          C) printf 'RIGHT'; return 0 ;;
          D) printf 'LEFT'; return 0 ;;
          H) printf 'HOME'; return 0 ;;
          F) printf 'END'; return 0 ;;
          [0-9])
            IFS= read -r -s -n1 -t 0.02 seq2 2>/dev/null || seq2=""
            if [[ "${seq2}" == "~" ]]; then
              case "${seq}" in
                5) printf 'PGUP'; return 0 ;;
                6) printf 'PGDN'; return 0 ;;
                1|7) printf 'HOME'; return 0 ;;
                4|8) printf 'END'; return 0 ;;
                *) printf 'ESC'; return 0 ;;
              esac
            else
              printf 'ESC'; return 0
            fi
            ;;
          *) printf 'ESC'; return 0 ;;
        esac
      elif [[ "${rest}" == "O" ]]; then
        IFS= read -r -s -n1 -t 0.02 seq 2>/dev/null || seq=""
        case "${seq}" in
          H) printf 'HOME'; return 0 ;;
          F) printf 'END'; return 0 ;;
          *) printf 'ESC'; return 0 ;;
        esac
      else
        printf 'ESC'; return 0
      fi
      ;;
    $'\t') printf 'TAB'; return 0 ;;
    "") printf 'ENTER'; return 0 ;;
    $'\x7f'|$'\x08') printf 'BACKSPACE'; return 0 ;;
    *) printf '%s' "${k}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 文本输入（raw 模式内联编辑）
# ---------------------------------------------------------------------------

# ui_input <提示文本> <默认值> <secret(0|1)> [最大长度]
# 返回 0 并在全局 UI_INPUT_RESULT 存放结果；Esc 取消返回 1。
UI_INPUT_RESULT=""
ui_input() {
  local prompt="$1" default="${2:-}" secret="${3:-0}" maxlen="${4:-128}"
  local buf="${default}" cursor="${#default}" key ch
  local done=0
  while [[ "${done}" -eq 0 ]]; do
    # 重绘提示 + 输入
    printf '\r\033[K'
    printf '%s' "${prompt}"
    if [[ "${secret}" == "1" ]]; then
      local stars=""
      local i
      for ((i = 0; i < ${#buf}; i++)); do stars+="*"; done
      printf '%s' "${stars}"
    else
      printf '%s' "${buf}"
    fi
    key="$(ui_read_key)"
    case "${key}" in
      ENTER) done=1 ;;
      ESC) UI_INPUT_RESULT=""; return 1 ;;
      BACKSPACE)
        if [[ "${cursor}" -gt 0 ]]; then
          buf="${buf:0:cursor-1}${buf:cursor}"
          (( cursor -= 1 ))
        fi
        ;;
      LEFT) (( cursor > 0 )) && (( cursor -= 1 )) ;;
      RIGHT) (( cursor < ${#buf} )) && (( cursor += 1 )) ;;
      *)
        if [[ "${#key}" -eq 1 && "$(printf '%d' "'${key}")" -ge 32 && "${#buf}" -lt "${maxlen}" ]]; then
          buf="${buf:0:cursor}${key}${buf:cursor}"
          (( cursor += 1 ))
        fi
        ;;
    esac
  done
  printf '\r\033[K'
  UI_INPUT_RESULT="${buf}"
  return 0
}

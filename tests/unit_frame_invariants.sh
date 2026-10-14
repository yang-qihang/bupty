#!/usr/bin/env bash
# tests/unit_frame_invariants.sh —— 帧底色不变量（docs/ui-banner-palette-plan.md §10.2）。
#
# 本文件把 §10.2 的五条「可以静态验证的不变量」变成**会红**的断言。文档 §10.5 里的
# 数字是开发者声称的，本文件**自己独立算**，不引用文档、不复用展示台的检查器：
#   1. 帧内底色连续：除结尾退出重置外，任何 \033[0m 之后必须紧跟 \033[48;5;N m。
#   2. 擦屏带底色：\033[2J 出现之前必须先出现过底色 SGR。
#   3. 退出干净：退出路径的 \033[0m 之后不得再出现任何 \033[48;5;N m。
#   4. 各主题自身底色上的对比度：UI_TEXT/UI_MUTED/UI_SEL ≥ 4.5/3.0/4.5（10 套各算）。
#   5. 原有 5 套主题的 12 个前景角色相对 HEAD 逐字节不变。
#
# 负向对照：检查器必须能测出「故意漏色」，对比度函数必须给出 WCAG 标准值——
# 否则「全部达标」与「什么都没测到」在输出上长得一模一样（§10.5 第 4 条踩过这个坑）。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export XDG_CONFIG_HOME="$(mktemp -d)"
trap 'rm -rf "${XDG_CONFIG_HOME}"' EXIT

# shellcheck source=/dev/null
source "${BUPTY_HOME}/tui.sh"
set +e
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tests/lib/testlib.sh"

ui_size() { :; }
creds_exists() { return 1; }
export BUPTY_FORCE_UTF8=1
export BUPTY_FORCE_ICONS=half
BUPTY_AMBIG_W=1

# ===========================================================================
# 独立工具
# ===========================================================================

# 渲染一帧到全局 INV_FRAME（view/cols/rows 由调用方摆好）。
inv_render() {
  TUI_FRAME_FILE="$(mktemp)"
  INV_FRAME="$(tui_render)"
  rm -f "${TUI_FRAME_FILE}"
}

# \033[0m 之后不是本主题底色 SGR 的次数（0 = 底色连续）。
inv_bad_resets() {
  local s="$1" bg="$2" n=0
  while [[ "${s}" == *$'\033[0m'* ]]; do
    s="${s#*$'\033[0m'}"
    [[ "${s}" == "${bg}"* ]] || n=$((n + 1))
  done
  printf '%s' "${n}"
}

# 后台 256 索引 → RGB。
inv_rgb() {
  local i="$1" lv=(0 95 135 175 215 255)
  if (( i >= 232 )); then
    INV_R=$(( 8 + (i - 232) * 10 )); INV_G="${INV_R}"; INV_B="${INV_R}"; return 0
  fi
  i=$(( i - 16 ))
  INV_R=${lv[$(( i / 36 ))]}
  INV_G=${lv[$(( (i % 36) / 6 ))]}
  INV_B=${lv[$(( i % 6 ))]}
}

# 两个 256 索引的 WCAG 对比度（"%.2f"）。
inv_contrast() {
  local fi="$1" bi="$2" r1 g1 b1 r2 g2 b2
  inv_rgb "$fi"; r1=$INV_R; g1=$INV_G; b1=$INV_B
  inv_rgb "$bi"; r2=$INV_R; g2=$INV_G; b2=$INV_B
  awk -v r1="$r1" -v g1="$g1" -v b1="$b1" -v r2="$r2" -v g2="$g2" -v b2="$b2" '
    function lin(c,   x){ x=c/255; return (x<=0.03928) ? x/12.92 : ((x+0.055)/1.055)^2.4 }
    BEGIN {
      l1 = 0.2126*lin(r1) + 0.7152*lin(g1) + 0.0722*lin(b1)
      l2 = 0.2126*lin(r2) + 0.7152*lin(g2) + 0.0722*lin(b2)
      if (l1 < l2) { t = l1; l1 = l2; l2 = t }
      printf "%.2f", (l1 + 0.05) / (l2 + 0.05)
    }'
}

# 从 SGR 串取 256 前景 / 背景索引。
inv_fg_idx() { local s="${1#*38;5;}"; printf '%s' "${s%%[!0-9]*}"; }
inv_bg_idx() { local s="${1#*48;5;}"; printf '%s' "${s%%[!0-9]*}"; }

# ===========================================================================
# 0. 反向对照：检查器本身必须测得出来
# ===========================================================================
t_begin "反向对照：检查器灵敏度"
BG=$'\033[48;5;233m'
# 故意造一帧：一次裸复位（漏色）+ 一次正确复位。
leaky=$'\033[38;5;252mX\033[0m'          # \033[0m 之后没有底色
ok=$'\033[38;5;252mY\033[0m'"${BG}"     # \033[0m 之后紧跟底色
assert_eq "$(inv_bad_resets "${leaky}" "${BG}")" "1" "裸复位必须被计为 1（漏色探测器是活的）"
assert_eq "$(inv_bad_resets "${ok}" "${BG}")" "0" "正确复位不得被计为违规"
assert_eq "$(inv_bad_resets "${leaky}${ok}" "${BG}")" "1" "混合串应只计那一次裸复位"
# 对比度函数必须给出 WCAG 标准值（黑/白 = 21.00，同色 = 1.00）。
assert_eq "$(inv_contrast 16 231)" "21.00" "黑(16)/白(231) 对比度必须是 21.00"
assert_eq "$(inv_contrast 231 231)" "1.00" "同色对比度必须是 1.00"
assert_eq "$(inv_contrast 196 231)" "4.00" "纯红(196)/白 对比度必须是 4.00"

# ===========================================================================
# 1 & 2. 帧内底色连续 + 擦屏带底色（10 套主题 × 若干帧）
# ===========================================================================
# 帧样本覆盖：普通视图宽终端、首页降级窄终端、以及**大字符块开启**的首页
# （tui.sh 对块行尾复位有专门特判，是最易破坏不变量 1 的路径）。
t_begin "§10.2-1/2 帧内底色连续 + 擦屏带底色（10 套主题）"
inv_frames_bad=0
inv_frames_ng=0
inv_frame_count=0
for th in "${UI_THEME_NAMES[@]}"; do
  ui_theme_init "${th}"
  icon_init
  ui_box_init
  for spec in "home 100 30 0" "home 46 22 0" "settings 100 30 0" "home 100 30 1"; do
    read -r v cols rows force_banner <<< "${spec}"
    BUPTY_FORCE_BANNER="${force_banner}"
    UI_COLS="${cols}" UI_ROWS="${rows}" TUI_VIEW="${v}" HOME_FOCUS=grid HOME_SEL=1
    inv_render
    inv_frame_count=$(( inv_frame_count + 1 ))
    # 不变量 1：每个 \033[0m 后必须紧跟本主题底色。
    nbad="$(inv_bad_resets "${INV_FRAME}" "${UI_BG}")"
    if [[ "${nbad}" != "0" ]]; then
      inv_frames_bad=$(( inv_frames_bad + 1 ))
      printf 'FAIL [%s] %s %s×%s banner=%s：%s 处复位后缺底色\n' \
        "${TESTS_NAME}" "${th}" "${cols}" "${rows}" "${force_banner}" "${nbad}"
    fi
    # 不变量 2：\033[2J 之前必须先发过底色。
    if [[ "${INV_FRAME}" != *"${UI_BG}"$'\033[2J'* ]]; then
      inv_frames_ng=$(( inv_frames_ng + 1 ))
      printf 'FAIL [%s] %s %s×%s：\033[2J 之前没有底色\n' \
        "${TESTS_NAME}" "${th}" "${cols}" "${rows}"
    fi
  done
done
assert_ok test "${inv_frame_count}" -ge 40     # 10 套 × 4 帧
assert_eq "${inv_frames_bad}" "0" "所有帧的每个复位后都必须紧跟底色"
assert_eq "${inv_frames_ng}" "0" "所有帧的 \033[2J 之前必须发过底色"

# ===========================================================================
# 3. 退出干净：退出路径的复位之后不得再有底色
# ===========================================================================
t_begin "§10.2-3 退出后不得残留底色"
inv_exit_bad=0
for th in "${UI_THEME_NAMES[@]}"; do
  ui_theme_init "${th}"
  out="$(ui_exit_alt_screen)"
  # 退出必经一次 \033[0m；之后不得再出现任何 48;5;。
  if [[ "${out}" != $'\033[0m'* ]]; then
    inv_exit_bad=$(( inv_exit_bad + 1 ))
    printf 'FAIL [%s] %s：退出串未以 \033[0m 起头\n' "${TESTS_NAME}" "${th}"
  fi
  rest="${out#*$'\033[0m'}"
  if [[ "${rest}" == *"48;5;"* ]]; then
    inv_exit_bad=$(( inv_exit_bad + 1 ))
    printf 'FAIL [%s] %s：退出复位之后仍出现底色\n' "${TESTS_NAME}" "${th}"
  fi
done
assert_eq "${inv_exit_bad}" "0" "退出复位之后不得再出现任何底色 SGR"

# ===========================================================================
# 4. 各主题自身底色上的对比度（独立复算，不看文档数字）
# ===========================================================================
t_begin "§10.2-4 各主题对自身底色的对比度"
printf '\n  [独立复算] 主题 × UI_TEXT/UI_MUTED/UI_SEL 对**自己**底色（阈值 4.5/3.0/4.5）：\n'
printf '  %-14s %-6s %-6s %-7s %-6s %-7s %-6s %-7s\n' \
  "主题" "底色" "TEXT" "对比" "MUTED" "对比" "SEL" "对比"
inv_c_bad=0
inv_idx_bad=0
for th in "${UI_THEME_NAMES[@]}"; do
  ui_theme_init "${th}"
  bgidx="$(inv_bg_idx "${UI_BG}")"
  tidx="$(inv_fg_idx "${UI_TEXT}")"
  midx="$(inv_fg_idx "${UI_MUTED}")"
  sidx="$(inv_fg_idx "${UI_SEL}")"
  # 索引合法性：必须在 16..255（0..15 是终端可改的系统色，不参与本口径；
  # 越过 231 会掉进灰度区，256 色换算会给出错误的 RGB，所以这里必须挡住）。
  for pair in "bg:${bgidx}" "TEXT:${tidx}" "MUTED:${midx}" "SEL:${sidx}"; do
    if ! [[ "${pair#*:}" =~ ^[0-9]+$ ]] || (( ${pair#*:} < 16 )) || (( ${pair#*:} > 255 )); then
      inv_idx_bad=$(( inv_idx_bad + 1 ))
      printf 'FAIL [%s] %s 的 %s 索引越界：%s\n' "${TESTS_NAME}" "${th}" "${pair%%:*}" "${pair#*:}"
    fi
  done
  ct="$(inv_contrast "${tidx}" "${bgidx}")"
  cm="$(inv_contrast "${midx}" "${bgidx}")"
  cs="$(inv_contrast "${sidx}" "${bgidx}")"
  printf '  %-14s %-6s %-6s %-7s %-6s %-7s %-6s %-7s\n' \
    "${th}" "${bgidx}" "${tidx}" "${ct}" "${midx}" "${cm}" "${sidx}" "${cs}"
  awk -v a="${ct}" 'BEGIN{ exit !(a >= 4.5) }' || { inv_c_bad=$(( inv_c_bad + 1 )); printf 'FAIL [%s] %s TEXT %s < 4.5\n' "${TESTS_NAME}" "${th}" "${ct}"; }
  awk -v a="${cm}" 'BEGIN{ exit !(a >= 3.0) }' || { inv_c_bad=$(( inv_c_bad + 1 )); printf 'FAIL [%s] %s MUTED %s < 3.0\n' "${TESTS_NAME}" "${th}" "${cm}"; }
  awk -v a="${cs}" 'BEGIN{ exit !(a >= 4.5) }' || { inv_c_bad=$(( inv_c_bad + 1 )); printf 'FAIL [%s] %s SEL %s < 4.5\n' "${TESTS_NAME}" "${th}" "${cs}"; }
done
assert_eq "${inv_idx_bad}" "0" "所有测试角色的 256 色索引必须落在 16..255"
assert_eq "${inv_c_bad}" "0" "10 套主题的 TEXT/MUTED/SEL 对自身底色必须全部达标"

# ===========================================================================
# 5. 原有 5 套主题的 12 个前景角色相对 HEAD 逐字节不变
# ===========================================================================
t_begin "§10.2-5 老 5 套的 12 个前景角色相对 HEAD 不变"
inv_export_head() {
  local out="$1" gd wgd
  mkdir -p "${out}"
  if git -C "${BUPTY_HOME}" archive HEAD 2>/dev/null | tar -x -C "${out}" 2>/dev/null \
     && [[ -f "${out}/tui.sh" ]]; then return 0; fi
  gd="$(sed -n 's/^gitdir: //p' "${BUPTY_HOME}/.git" 2>/dev/null)"
  if [[ -n "${gd}" ]]; then
    wgd="$(printf '%s' "${gd}" | sed -E 's#^([A-Za-z]):/#/mnt/\L\1/#')"
    if [[ -d "${wgd}" ]] && git --git-dir="${wgd}" archive HEAD 2>/dev/null | tar -x -C "${out}" 2>/dev/null \
       && [[ -f "${out}/tui.sh" ]]; then return 0; fi
  fi
  return 1
}
INV_WORK="$(mktemp -d)"
INV_HEAD_TREE="${INV_WORK}/head"
INV_DUMP="${INV_WORK}/dump_roles.sh"
cat > "${INV_DUMP}" <<'DUMP_EOF'
#!/usr/bin/env bash
set -uo pipefail
root="$1"
export XDG_CONFIG_HOME="$(mktemp -d)"
source "$root/lib/core.sh"
source "$root/lib/ui.sh"
roles=(UI_TITLE UI_TEXT UI_MUTED UI_BORDER UI_ACCENT UI_SUCCESS UI_WARNING UI_DANGER UI_PURPLE UI_SEL UI_HL UI_HL_FG)
for t in dark light nord gruvbox high-contrast; do
  if declare -F ui_theme_apply >/dev/null 2>&1; then ui_theme_apply "$t"; else ui_theme_init "$t"; fi
  for r in "${roles[@]}"; do printf '%s|%s|%s\n' "$t" "$r" "${!r}"; done
done
DUMP_EOF
if inv_export_head "${INV_HEAD_TREE}"; then
  bash "${INV_DUMP}" "${INV_HEAD_TREE}" > "${INV_WORK}/head.txt"
  bash "${INV_DUMP}" "${BUPTY_HOME}"      > "${INV_WORK}/cur.txt"
  assert_eq "$(wc -l < "${INV_WORK}/head.txt" | tr -d ' ')" "60" "应导出 5×12=60 行角色"
  assert_eq "$(wc -l < "${INV_WORK}/cur.txt"  | tr -d ' ')" "60" "当前树也应导出 60 行角色"
  diff_out="$(diff "${INV_WORK}/head.txt" "${INV_WORK}/cur.txt")"
  if [[ -n "${diff_out}" ]]; then printf '%s\n' "${diff_out}" | head -20; fi
  assert_eq "${diff_out}" "" "老 5 套的 12 个前景角色必须与 HEAD 逐字节相同"
else
  assert_eq "无法导出 HEAD" "已导出" "git archive HEAD 失败，角色不变性未能验证（不静默通过）"
fi
rm -rf "${INV_WORK}"

t_summary

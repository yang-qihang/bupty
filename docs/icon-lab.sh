#!/usr/bin/env bash
# docs/icon-lab.sh —— 首页模块图标设计台。
#
# 读入 '#'/'.' 画的点阵，同时输出几种终端渲染，用来挑形状、看实心度：
#   半块版  ▀▄█ + 空格：每格 1 列 × 2 点，实心色块（Claude 吉祥物那种做法）
#   背景版  空格 + 背景色：每格 1 点，1×1 分辨率，宽度绝对安全（Ambiguous 兜底）
#   骨架版  #/+/.：把形状压成字符，纯看结构，不受字体影响
#
# 用法：  bash docs/icon-lab.sh grid.txt
#         cat grid.txt | bash docs/icon-lab.sh
#         bash docs/icon-lab.sh all        # 直接看内置的六个模块图标
#
# 点阵规约：每行等宽；只允许 . 和 #；半块版要求高度为偶数。
#           宽度无限制（半块版 1 点 = 1 列）。

set -uo pipefail

case "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" in
  *UTF-8* | *utf8* | *UTF8*) : ;;
  *) export LC_ALL=C.UTF-8 2>/dev/null || true ;;
esac

R=$'\033[0m'
C_DIM=$'\033[38;5;244m'
C_TT=$'\033[38;5;39;1m'
C_OK=$'\033[38;5;114m'
C_DAN=$'\033[38;5;203m'
[[ -t 1 ]] || { R=""; C_DIM=""; C_TT=""; C_OK=""; C_DAN=""; }

# ---------------------------------------------------------------------------
# 内置的六个模块图标（12 列 × 12 行）
# ---------------------------------------------------------------------------
icon_grid() {
  case "$1" in
    assignments) # 作业 DDL：折角文档 + 文本条
      cat <<'EOF'
.########...
.#########..
.##########.
.#........#.
.#.######.#.
.#........#.
.#.######.#.
.#........#.
.#.####...#.
.#........#.
.##########.
.##########.
EOF
      ;;
    schedule) # 课表：台历（两个环 + 实心顶栏 + 2×2 厚日程格）
      cat <<'EOF'
...#....#...
...#....#...
.##########.
.##########.
.#........#.
.#.##..##.#.
.#.##..##.#.
.#........#.
.#.##..##.#.
.#.##..##.#.
.##########.
.##########.
EOF
      ;;
    classrooms) # 空教室：教室轮廓 + 四组空座
      cat <<'EOF'
............
.##########.
.#........#.
.#.##..##.#.
.#.##..##.#.
.#........#.
.#.##..##.#.
.#.##..##.#.
.#........#.
.#........#.
.##########.
............
EOF
      ;;
    grades) # 成绩：三根递增的实心柱 + 基线
      cat <<'EOF'
........##..
........##..
........##..
.....##.##..
.....##.##..
.....##.##..
..##.##.##..
..##.##.##..
..##.##.##..
..##.##.##..
.##########.
.##########.
EOF
      ;;
    exams) # 考试：沙漏（时间在漏）
      cat <<'EOF'
.##########.
..########..
...######...
....####....
.....##.....
.....##.....
.....##.....
....####....
...######...
..########..
.##########.
............
EOF
      ;;
    public) # 公共查询：地球（赤道 + 子午线）
      cat <<'EOF'
....####....
..########..
.##..##..##.
.#...##...#.
#....##....#
############
############
#....##....#
.#...##...#.
.##..##..##.
..########..
....####....
EOF
      ;;
  esac
}

ICON_NAMES=(assignments schedule classrooms grades exams public)
LABELS=("作业 DDL" "课表" "空教室" "成绩" "考试" "公共查询")
COLORS=(203 39 114 135 215 39)

# ---------------------------------------------------------------------------
read_grid() {
  local src="${1:-}"
  local -a raw=()
  local line
  if [[ -n "${src}" ]]; then
    [[ -f "${src}" ]] || { printf '找不到文件：%s\n' "${src}" >&2; exit 1; }
    while IFS= read -r line; do raw+=("${line}"); done < "${src}"
  else
    while IFS= read -r line; do raw+=("${line}"); done
  fi
  GRID=()
  for line in "${raw[@]}"; do
    [[ -z "${line}" || "${line}" == '#'\ * ]] && continue
    GRID+=("${line}")
  done
  ROWS=${#GRID[@]}
  COLS=0
  ((ROWS > 0)) && COLS=${#GRID[0]}
}

check_grid() {
  local i l bad=0
  for ((i = 0; i < ROWS; i++)); do
    l="${GRID[$i]}"
    if ((${#l} != COLS)); then
      printf '%s✗ 第 %d 行宽度 %d，应为 %d%s\n' "${C_DAN}" "$((i + 1))" "${#l}" "${COLS}" "${R}"
      bad=1
    fi
    if [[ "${l}" =~ [^.#] ]]; then
      printf '%s✗ 第 %d 行含非法字符（只允许 . 和 #）：%s%s\n' "${C_DAN}" "$((i + 1))" "${l}" "${R}"
      bad=1
    fi
  done
  ((COLS % 2 != 0)) && { printf '%s✗ 宽度 %d 不是偶数%s\n' "${C_DAN}" "${COLS}" "${R}"; bad=1; }
  ((ROWS % 2 != 0)) && { printf '%s✗ 高度 %d 不是偶数（半块版按 2 行分组）%s\n' "${C_DAN}" "${ROWS}" "${R}"; bad=1; }
  return "${bad}"
}

render_halfblock() { # <颜色码>（空=不上色）
  local col="$1" r c t b
  for ((r = 0; r < ROWS; r += 2)); do
    if [[ -n "${col}" ]]; then printf '\033[38;5;%sm' "${col}"; fi
    for ((c = 0; c < COLS; c++)); do
      t=0; b=0
      [[ "${GRID[r]:c:1}" == '#' ]] && t=1
      [[ "${GRID[r + 1]:c:1}" == '#' ]] && b=1
      if ((t && b)); then printf '█'; elif ((t)); then printf '▀'; elif ((b)); then printf '▄'; else printf ' '; fi
    done
    [[ -n "${col}" ]] && printf '%s' "${R}"
    printf '\n'
  done
}

render_bg() { # 背景色方块：每格 1 点，纵向每 2 点取 1 点（和半块版占同样的行数）
  local col="$1" r c
  for ((r = 0; r < ROWS; r += 2)); do
    for ((c = 0; c < COLS; c++)); do
      if [[ "${GRID[r]:c:1}" == '#' ]]; then
        if [[ -n "${col}" ]]; then printf '\033[48;5;%sm \033[0m' "${col}"; else printf '#'; fi
      else
        printf ' '
      fi
    done
    printf '\n'
  done
}

render_skeleton() {
  local r c t b
  for ((r = 0; r < ROWS; r += 2)); do
    for ((c = 0; c < COLS; c++)); do
      t=0; b=0
      [[ "${GRID[r]:c:1}" == '#' ]] && t=1
      [[ "${GRID[r + 1]:c:1}" == '#' ]] && b=1
      if ((t && b)); then printf '#'; elif ((t || b)); then printf '+'; else printf '.'; fi
    done
    printf '\n'
  done
}

show_one() { # <名字> <颜色> <标签>
  local name="$1" col="$2" label="$3"
  icon_grid "${name}" | { read_grid ""; }
  printf '%s── %s（%d×%d 点 → %d 列 × %d 行）──%s\n' "${C_TT}" "${label}" "${COLS}" "${ROWS}" "${COLS}" "$((ROWS / 2))" "${R}"
  render_halfblock "${col}"
  printf '%s骨架：%s\n' "${C_DIM}" "${R}"
  render_skeleton
  printf '\n'
}

show_all() {
  local i n=${#ICON_NAMES[@]}
  printf '%s══ 半块版（实心色块，Ambiguous 宽度，启动时实测决定用不用）══%s\n\n' "${C_TT}" "${R}"
  for ((i = 0; i < n; i++)); do
    printf '%s【%s】%s\n' "${C_TT}" "${LABELS[$i]}" "${R}"
    icon_grid "${ICON_NAMES[$i]}" | { read_grid ""; render_halfblock "${COLORS[$i]}"; }
    printf '\n'
  done
  printf '%s══ 骨架（结构评审用）══%s\n\n' "${C_TT}" "${R}"
  for ((i = 0; i < n; i++)); do
    printf '%s【%s】%s\n' "${C_DIM}" "${LABELS[$i]}" "${R}"
    icon_grid "${ICON_NAMES[$i]}" | { read_grid ""; render_skeleton; }
    printf '\n'
  done
  printf '%s══ 背景色版兜底（1×1 分辨率，宽度绝对安全）══%s\n\n' "${C_TT}" "${R}"
  for ((i = 0; i < n; i++)); do
    printf '%s【%s】%s\n' "${C_TT}" "${LABELS[$i]}" "${R}"
    icon_grid "${ICON_NAMES[$i]}" | { read_grid ""; render_bg "${COLORS[$i]}"; }
    printf '\n'
  done
}

main() {
  case "${1:-}" in
    all | '') show_all ;;
    *)
      read_grid "$1"
      ((ROWS == 0)) && { printf '没读到点阵。\n' >&2; exit 1; }
      printf '%s点阵 %d×%d%s\n' "${C_TT}" "${COLS}" "${ROWS}" "${R}"
      if ! check_grid; then
        printf '%s尺寸不合规，先修好再看预览。%s\n' "${C_DAN}" "${R}"
        exit 1
      fi
      printf '\n%s── 半块版（%d 列 × %d 行）──%s\n' "${C_TT}" "${COLS}" "$((ROWS / 2))" "${R}"
      render_halfblock ""
      printf '\n%s── 骨架 ──%s\n' "${C_TT}" "${R}"
      render_skeleton
      ;;
  esac
}

main "$@"

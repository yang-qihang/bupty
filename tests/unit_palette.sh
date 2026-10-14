#!/usr/bin/env bash
# tests/unit_palette.sh —— 配色候选方案（docs/palette-lab.sh）单元测试（全离线、无网络）。
#
# 目的：把「重新设计配色方案」这件事的硬要求变成**会红**的断言，而不是靠人眼在展示台里看。
# 被测对象是 docs/palette-lab.sh —— 一个只读产品代码的展示脚本，自带 7 套候选方案
# （5 深色 + 2 浅色）。本文件不修改任何产品文件（不含 lib/ui.sh、lib/views/home.sh）；
# 第 7 节另外**读**产品 lib/ui.sh 的 10 套主题角色值做跨文件断言。
#
# 覆盖：
#   1. 方案清单自洽：名字/标签/来源/明暗/基准底色/处置六个数组一一对应，无重名
#   2. 每套方案的 13 个角色都非空、SGR 是合法 CSI 序列、颜色索引全在 0..255、不含真彩色
#   3. **除 UI_HL / UI_HL_FG 外，任何角色都不许带背景色**（选中态只准靠结构线索表达）
#   4. 「最近 256 色」映射可复算：另写一份欧氏距离穷举实现，逐色核对
#   5. WCAG 对比度：正文 / 选中正文 ≥ 4.5，次要文字 ≥ 3.0；且「选中方框」必须比
#      「未选中方框」明显更亮 —— 这是「一眼看出选中」的全部依据
#   6. 响应式硬不变量：每套方案 × 每个宽度，渲染出的每一行都 ≤ UI_COLS
#   7. 换配色不改几何：跨方案逐行等宽，且与「把颜色全清空」的渲染逐行等宽
#   8. 回归护栏：产品现有 5 套主题（dark 等）本轮一字未改，且它们的 UI_SEL 都不含背景
#   9. 回归护栏：新增 5 套主题（mocha/tokyonight/kanagawa/latte/rosepine）的 12 个角色
#      与 docs/palette-lab.sh 里同名方案**逐字节一致**；全部 10 套主题 × 12 个角色中，
#      **只有 UI_HL / UI_HL_FG 允许出现 48;5; 背景色**
#
# 负向对照（缺了它们，上面任何一条「通过」都可能是「什么都没测到」）：
#   strip 写坏会静默把宽度量成 0 / 检查器能不能真报出越界索引、真彩色、越权背景 /
#   宽度链能不能真量出超宽 / 未知方案名是否真被拒 / 对比度实现是否真的给出标准值 /
#   背景色扫描器能不能真的抓到一次注入的 48;5;。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 隔离配置目录：ui_theme_init 会读 settings.json，测试绝不碰用户真实配置。
TMPROOT="$(mktemp -d)"
export XDG_CONFIG_HOME="${TMPROOT}/config"
export HOME="${TMPROOT}/home"
mkdir -p "${XDG_CONFIG_HOME}" "${HOME}"
unset BUPTY_THEME

# 被测对象。它自己 source lib/core.sh + lib/ui.sh + lib/icons.sh + lib/views/home.sh，
# 全程只读；末尾有 `BASH_SOURCE[0] == $0` 守卫，被 source 时不会跑它的 main。
# shellcheck disable=SC1091
source "${BUPTY_HOME}/docs/palette-lab.sh"
set +e   # core.sh 带 set -e；本测试按「逐项检查、计数、最后汇总」跑，自己控制失败

# shellcheck disable=SC1091
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# 产品侧 13 个角色对应的变量名（与 docs/palette-lab.sh 的 LAB_UI_ROLES 同序）。
PAL_ROLE_VARS=(
  UI_TITLE UI_TEXT UI_MUTED UI_BORDER UI_ACCENT UI_SUCCESS UI_WARNING
  UI_DANGER UI_PURPLE UI_SEL UI_SEL_BORDER UI_HL UI_HL_FG
)

# ===========================================================================
# 独立检查器
# ===========================================================================
# **刻意不复用 docs/palette-lab.sh 里的 _lab_* 检查函数**：拿被测对象自己的检查器去验
# 被测对象，两边一起写错就会一起「通过」。下面这些是另写的一套。

# 剥 ANSI 转义 → 全局 PAL_PLAIN。
# 必须最短匹配逐个剥。写成 `${s//$'\033'\[[0-9;]*[a-zA-Z]/}` 是错的：bash 的 glob 里
# `*` 是通配符不是正则量词，它会从第一个转义一路吞到行尾，整行变空、宽度恒 0，
# 于是所有宽度断言都会「静默地永远通过」。
pal_strip() {
  local s="${1:-}" out="" rest
  while [[ "${s}" == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"
    s="${s#*$'\033['}"
    rest="${s#*[a-zA-Z]}"
    if [[ "${rest}" == "${s}" ]]; then
      s=""            # 找不到终止字母（截断的转义）：整段丢弃，避免死循环
      break
    fi
    s="${rest}"
  done
  PAL_PLAIN="${out}${s}"
}

# 抠出 SGR 串里所有 38;5;N / 48;5;N 的 N → 全局 PAL_IDXS（空格分隔）。
pal_indices() {
  local s="${1:-}" out=""
  while [[ "${s}" =~ (38|48)\;5\;([0-9]+) ]]; do
    out+="${BASH_REMATCH[2]} "
    s="${s#*"${BASH_REMATCH[0]}"}"
  done
  PAL_IDXS="${out% }"
}

# 独立实现的「最近 xterm-256 索引」→ 全局 PAL_NREF。
# 与 lab_nearest256 是**同一个算法定义**（RGB 欧氏距离平方最小、穷举 16..255、
# 并列时取较小索引）但代码另写一份：两份实现必须逐色给出同一个索引，
# 否则说明这个映射不可信。
pal_nearest_ref() {
  local hex="${1:-}" r g b i t cr cg cb d best=999999999 bi=-1
  r=$(( 16#${hex:1:2} )); g=$(( 16#${hex:3:2} )); b=$(( 16#${hex:5:2} ))
  for (( i = 16; i <= 255; i++ )); do
    if (( i >= 232 )); then
      cr=$(( 8 + 10 * (i - 232) )); cg="${cr}"; cb="${cr}"
    else
      t=$(( i - 16 ))
      cr=$(( t / 36 )); cg=$(( (t % 36) / 6 )); cb=$(( t % 6 ))
      (( cr > 0 )) && cr=$(( 55 + 40 * cr ))
      (( cg > 0 )) && cg=$(( 55 + 40 * cg ))
      (( cb > 0 )) && cb=$(( 55 + 40 * cb ))
    fi
    d=$(( (r - cr) * (r - cr) + (g - cg) * (g - cg) + (b - cb) * (b - cb) ))
    if (( d < best )); then best="${d}"; bi="${i}"; fi
  done
  PAL_NREF="${bi}"
}

# 索引 → #RRGGBB（独立实现的 xterm-256 调色板公式）→ stdout。
# 用来核对展示台印出来的「落点 RGB」是真的会画出来的颜色，而不是随手写的。
pal_hex_expected() {
  local i="${1:-0}" t r g b
  if (( i >= 232 )); then
    r=$(( 8 + 10 * (i - 232) )); g="${r}"; b="${r}"
  else
    t=$(( i - 16 ))
    r=$(( t / 36 )); g=$(( (t % 36) / 6 )); b=$(( t % 6 ))
    (( r > 0 )) && r=$(( 55 + 40 * r ))
    (( g > 0 )) && g=$(( 55 + 40 * g ))
    (( b > 0 )) && b=$(( 55 + 40 * b ))
  fi
  printf '#%02X%02X%02X' "${r}" "${g}" "${b}"
}

# 角色 SGR 检查器。问题数写 PAL_BAD，明细（若 quiet=0）直接打印。
#   pal_check_role <谁> <角色名> <变量名> [quiet]
pal_check_role() {
  local who="$1" role="$2" var="$3" quiet="${4:-0}"
  local sgr="${!var}" idxs n fill
  PAL_BAD=0
  fill=0
  for n in ${LAB_FILL_ROLES[*]}; do [[ "${n}" == "${role}" ]] && fill=1; done
  pal_bad() {
    PAL_BAD=$(( PAL_BAD + 1 ))
    if (( quiet == 0 )); then printf '  FAIL [%s] 角色 %s：%s\n' "${who}" "${role}" "$1"; fi
  }
  if [[ -z "${sgr}" ]]; then pal_bad "为空（角色未定义会渲染出无色/串色行）"; return 0; fi
  if [[ ! "${sgr}" =~ ^$'\033'\[[0-9\;]*m$ ]]; then pal_bad "SGR 不是合法 CSI 序列：$(printf '%q' "${sgr}")"; fi
  if [[ "${sgr}" == *"38;2;"* || "${sgr}" == *"48;2;"* ]]; then
    pal_bad "用了真彩色（本项目只支持 256 色 38;5;N / 48;5;N）"
  fi
  if [[ "${sgr}" == *"48;5;"* ]] && (( fill == 0 )); then
    pal_bad "带了背景色（只有 UI_HL / UI_HL_FG 允许铺底，选中态不许有填充块）"
  fi
  pal_indices "${sgr}"
  idxs="${PAL_IDXS}"
  if [[ -z "${idxs}" ]]; then pal_bad "SGR 里没有任何 38;5;N / 48;5;N 颜色"; fi
  for n in ${idxs}; do
    (( n < 0 || n > 255 )) && pal_bad "颜色索引越界：${n}"
  done
  # 颜色必须是零宽：产品的宽度引擎会把转义也当字符数进去，颜色若占列就会算错。
  pal_strip "${sgr}"
  if [[ -n "${PAL_PLAIN}" ]]; then pal_bad "剥色后仍剩内容：$(printf '%q' "${PAL_PLAIN}")"; fi
}

# ===========================================================================
# 0. 负向对照：先证明这些检查器**失败得出来**
# ===========================================================================
# 「全绿」本身没有说服力：如果断言永远走通过分支（或被测值恒为常量），测试会静默全过
# 却什么都没验证。下面每条都构造必然出错的输入，确认计数器真的涨。
t_begin "负向对照：检查器必须能失败"

_neg_selftest() {
  local before after ok=1
  # (a) 越界索引必须被报出来
  before="${TESTS_FAIL}"; UI_ACCENT=$'\033[38;5;300m'
  pal_check_role "neg" "accent" UI_ACCENT 1
  after="${PAL_BAD}"; UI_ACCENT=""
  (( after > 0 )) || { printf '  反向对照失败：索引 300 未被判越界\n'; ok=0; }
  # (b) 真彩色必须被报出来
  UI_TEXT=$'\033[38;2;255;0;0m'
  pal_check_role "neg" "text" UI_TEXT 1
  (( PAL_BAD > 0 )) || { printf '  反向对照失败：真彩色未被判失败\n'; ok=0; }
  # (c) 非铺满角色带背景色必须被报出来（这正是首页 9 列色块那个 bug 的形状）
  UI_SEL=$'\033[38;5;15;48;5;24m'
  pal_check_role "neg" "sel" UI_SEL 1
  (( PAL_BAD > 0 )) || { printf '  反向对照失败：UI_SEL 带背景色未被判失败\n'; ok=0; }
  # (d) 反过来：UI_HL 带背景色是合法的，不许误报（否则 (c) 恒成立就没意义）
  UI_HL=$'\033[38;5;15;48;5;24m'
  pal_check_role "neg" "hl" UI_HL 1
  (( PAL_BAD == 0 )) || { printf '  反向对照失败：UI_HL 的合法背景被误判\n'; ok=0; }
  # (e) 空角色必须被报出来
  UI_MUTED=""
  pal_check_role "neg" "muted" UI_MUTED 1
  (( PAL_BAD > 0 )) || { printf '  反向对照失败：空角色未被判失败\n'; ok=0; }
  # 复原（后面还要用这些变量）
  lab_apply "${LAB_NAMES[0]}"
  [[ "${before}" == "${TESTS_FAIL}" ]] || ok=0
  return $(( ok == 1 ? 0 : 1 ))
}
assert_ok _neg_selftest

# strip 的独立自检：带色行 `▸ 作业 DDL` 剥完必须正好 10 列。strip 一坏，
# 下面所有宽度断言都会塌成「0 列通过」。
_neg_strip() {
  pal_strip "$(core_sgr 244)▸$(core_sgr 252) 作业 DDL$(core_c_reset)"
  _core_width "${PAL_PLAIN}"
  local w="${_CORE_W}"
  pal_strip "${PAL_PLAIN}"     # 幂等：没有转义时必须原样返回
  [[ "${w}" == "10" && "${PAL_PLAIN}" == "▸ 作业 DDL" ]]
}
assert_ok _neg_strip

# 宽度链必须能量出超宽（否则「≤ UI_COLS」全部是假通过）。
_neg_overwide() {
  local wide
  printf -v wide '%*s' 201 ''
  _core_width "${wide}"
  (( _CORE_W > 200 ))
}
assert_ok _neg_overwide

# 对比度实现必须给出 WCAG 标准值（黑/白 = 21.00，同色 = 1.00，纯红/白 = 4.00）。
# 不校这一条，后面「正文 ≥ 4.5」的通过就可能是实现算错碰巧的结果。
_neg_contrast() {
  [[ "$(lab_contrast '#000000' '#FFFFFF')" == "21.00" ]] || return 1
  [[ "$(lab_contrast '#123456' '#123456')" == "1.00" ]] || return 1
  [[ "$(lab_contrast '#FF0000' '#FFFFFF')" == "4.00" ]] || return 1
  return 0
}
assert_ok _neg_contrast

# 「最近 256 色」实现必须能给出标准落点（含色立方两端与灰阶分支）。
_neg_nearest() {
  lab_nearest256 '#FFFFFF'; [[ "${LAB_IDX}" == "231" ]] || return 1
  lab_nearest256 '#000000'; [[ "${LAB_IDX}" == "16" ]] || return 1
  lab_nearest256 '#FF0000'; [[ "${LAB_IDX}" == "196" ]] || return 1
  lab_nearest256 '#808080'; [[ "${LAB_IDX}" == "244" ]] || return 1   # 灰阶分支
  return 0
}
assert_ok _neg_nearest

# ===========================================================================
# 1. 方案清单自洽
# ===========================================================================
t_begin "方案清单"
assert_ok test "${#LAB_NAMES[@]}" -ge 5                       # 任务要求 ≥5 套
assert_eq "${#LAB_LABELS[@]}"  "${#LAB_NAMES[@]}" "标签数应与方案数一致"
assert_eq "${#LAB_SOURCES[@]}" "${#LAB_NAMES[@]}" "来源数应与方案数一致"
assert_eq "${#LAB_VARIANTS[@]}" "${#LAB_NAMES[@]}" "明暗标记数应与方案数一致"
assert_eq "${#LAB_NOTES[@]}"   "${#LAB_NAMES[@]}" "处置说明数应与方案数一致"
# 基准底色表在 docs/palette-lab.sh 里由 LAB_NAMES 经 LAB_BG_OF **派生**（长度由结构保证），
# 所以「长度相等」本身已经不可能漂移；真正要钉的是**内容**：每个方案都得有一个真底色。
# 下述两条一起生效——长度（原有判据，保留）+ 合法 #RRGGBB 的个数必须等于方案数。
# 于是「从基准底色里删掉/写坏一项」会让合法值个数掉到方案数以下而变红（反向对照见报告）。
assert_eq "${#LAB_BG_BASE[@]}" "${#LAB_NAMES[@]}" "基准底色数应与方案数一致"
assert_eq "$(printf '%s\n' "${LAB_BG_BASE[@]}" | grep -c -x -E '#[0-9A-Fa-f]{6}')" \
  "${#LAB_NAMES[@]}" "每个方案都应有一个合法的 #RRGGBB 基准底色（漏项/空值/坏值都会红）"
assert_eq "${#LAB_UI_ROLES[@]}" "${#LAB_ROLE_VARS[@]}" "角色名与变量名应一一对应"
assert_eq "${#LAB_UI_ROLES[@]}" "13" "角色数应为 13（12 个产品角色 + 新增 UI_SEL_BORDER）"

# 每套方案都要有非空名字/标签/来源/处置，且名字不重复。
pal_dup=0
for i in "${!LAB_NAMES[@]}"; do
  assert_ok test -n "${LAB_NAMES[$i]}"
  assert_ok test -n "${LAB_LABELS[$i]}"
  assert_ok test -n "${LAB_SOURCES[$i]}"
  assert_ok test -n "${LAB_NOTES[$i]}"
  for j in "${!LAB_NAMES[@]}"; do
    (( i < j )) && [[ "${LAB_NAMES[$i]}" == "${LAB_NAMES[$j]}" ]] && pal_dup=1
  done
done
assert_eq "${pal_dup}" "0" "方案名不得重复"

# 明暗标记只能是 dark / light，且必须两种都有（浅色是硬要求）。
pal_dark=0; pal_light=0; pal_badvar=0
for v in "${LAB_VARIANTS[@]}"; do
  case "${v}" in
    dark)  pal_dark=$(( pal_dark + 1 )) ;;
    light) pal_light=$(( pal_light + 1 )) ;;
    *)     pal_badvar=$(( pal_badvar + 1 )) ;;
  esac
done
assert_eq "${pal_badvar}" "0" "明暗标记只允许 dark / light"
assert_ok test "${pal_dark}"  -ge 1
assert_ok test "${pal_light}" -ge 1   # 至少一套浅色主题

# 允许带背景色的角色恰好是 UI_HL / UI_HL_FG 两个。
assert_eq "${LAB_FILL_ROLES[*]}" "hl hl_fg" "只有 UI_HL / UI_HL_FG 允许铺底"

# 未知方案名必须被拒（否则「新增主题」这条路上会静默拿到别的方案的颜色）。
assert_fail lab_load_roles "no-such-palette"
assert_fail lab_apply "no-such-palette"

# 浅色/深色标记必须与该方案的基准底色真的一致（按相对亮度判定，不看人写的标签）。
t_begin "明暗标记与底色一致"
pal_mismatch=0
for i in "${!LAB_NAMES[@]}"; do
  bg="${LAB_BG_BASE[$i]}"
  c_white="$(lab_contrast "${bg}" '#FFFFFF')"
  c_black="$(lab_contrast "${bg}" '#000000')"
  if [[ "${LAB_VARIANTS[$i]}" == "light" ]]; then
    # 浅色底的「最坏情况背景」应更贴近白：对黑对比度更高
    awk -v a="${c_black}" -v b="${c_white}" 'BEGIN { exit !(a > b) }' || pal_mismatch=$(( pal_mismatch + 1 ))
  else
    awk -v a="${c_black}" -v b="${c_white}" 'BEGIN { exit !(b > a) }' || pal_mismatch=$(( pal_mismatch + 1 ))
  fi
done
assert_eq "${pal_mismatch}" "0" "声明为 light 的方案底色应偏白、dark 的应偏黑"

# ===========================================================================
# 2. 每套方案 × 13 个角色：非空 / 合法 / 无真彩 / 除铺满角色外无背景 / 索引 0..255
# ===========================================================================
# 先把每套方案的角色 SGR 存下来：后面「换配色不改几何」要反复切换方案，
# 每次都重算一遍是 13 次 fork，7 套 × 6 档宽度会让测试白白慢一个数量级。
declare -A PAL_SAVE=()
for name in "${LAB_NAMES[@]}"; do
  lab_apply "${name}" || { t_begin "应用 ${name}"; assert_ok false; continue; }
  for v in "${PAL_ROLE_VARS[@]}"; do PAL_SAVE["${name}|${v}"]="${!v}"; done
done

pal_use() {
  local v
  for v in "${PAL_ROLE_VARS[@]}"; do printf -v "${v}" '%s' "${PAL_SAVE["${1}|${v}"]}"; done
}

t_begin "角色 SGR 合法性（7 套 × 13 角色）"
pal_total_bad=0
for name in "${LAB_NAMES[@]}"; do
  lab_apply "${name}"
  for i in "${!LAB_UI_ROLES[@]}"; do
    pal_check_role "${name}" "${LAB_UI_ROLES[$i]}" "${LAB_ROLE_VARS[$i]}"
    pal_total_bad=$(( pal_total_bad + PAL_BAD ))
  done
done
assert_eq "${pal_total_bad}" "0" "所有角色都应合法（含「除 UI_HL/UI_HL_FG 外无背景色」）"

# 单独再钉一条：**没有任何角色索引落在 0..15**（那 16 个系统色由终端决定，
# 写进主题等于「颜色由用户的终端配置说了算」，同一套主题在不同机器上不是一个观感）。
t_begin "不使用 0..15 系统色"
pal_syscolor=0
for name in "${LAB_NAMES[@]}"; do
  lab_apply "${name}"
  for i in "${!LAB_UI_ROLES[@]}"; do
    pal_indices "${!LAB_ROLE_VARS[$i]}"
    for n in ${PAL_IDXS}; do
      (( n < 16 )) && pal_syscolor=$(( pal_syscolor + 1 ))
    done
  done
done
assert_eq "${pal_syscolor}" "0" "角色颜色不得使用 0..15 系统色索引"

# ===========================================================================
# 3. 「最近 256 色」映射可复算
# ===========================================================================
# 展示台声称索引是**算出来的最近邻**而不是凭感觉挑的。这里用另写一份的穷举实现逐色核对。
t_begin "256 色映射可复算"
pal_map_bad=0
for name in "${LAB_NAMES[@]}"; do
  lab_load_roles "${name}" || continue
  for role in title text muted border accent success warning danger purple sel sel_border hl_fg hl_bg; do
    lab_role_hex "${role}"
    hex="${LAB_HEX_ONE}"
    lab_nearest256 "${hex}"
    got="${LAB_IDX}"
    pal_nearest_ref "${hex}"
    if [[ "${got}" != "${PAL_NREF}" ]]; then
      pal_map_bad=$(( pal_map_bad + 1 ))
      printf 'FAIL [%s] %s 的 %s（%s）：展示台取 %s，独立复算为 %s\n' \
        "${TESTS_NAME}" "${name}" "${role}" "${hex}" "${got}" "${PAL_NREF}"
    fi
    # 落点 RGB 必须就是该索引真实会画出来的颜色（映射表里印的 hex 不能是编的）。
    lab_256_hex "${got}"
    pal_hex_ref="$(pal_hex_expected "${got}")"
    if [[ "${pal_hex_ref}" != "${LAB_RGB}" ]]; then
      pal_map_bad=$(( pal_map_bad + 1 ))
      printf 'FAIL [%s] %s 的 %s：索引 %s 的落点印成 %s，独立复算是 %s\n' \
        "${TESTS_NAME}" "${name}" "${role}" "${got}" "${LAB_RGB}" "${pal_hex_ref}"
    fi
  done
done
assert_eq "${pal_map_bad}" "0" "每个角色的 256 索引都应与独立复算一致"

# ===========================================================================
# 4. 对比度（WCAG）
# ===========================================================================
# **按 256 落点色算，不按上游真彩色算**：产品只发 38;5;N，屏幕上真正的颜色是「索引
# 对应的 RGB」。上游真彩与落点的 ΔRGB 可达 40（浅色方案尤其明显），拿真彩色算出来的
# 是「本该有的对比度」，不是用户实际看到的。
# 判据：正文 / 选中正文 ≥ 4.5（AA 正文）；次要文字 ≥ 3.0；反显药丸的前景/底色 ≥ 4.5；
# 且「选中方框」必须比「未选中方框」明显更亮——那是「一眼看出选中」的唯一依据。
t_begin "对比度（按 256 落点色）"
pal_text_low=0; pal_sel_low=0; pal_muted_low=0; pal_border_weak=0; pal_pill_low=0
for i in "${!LAB_NAMES[@]}"; do
  name="${LAB_NAMES[$i]}"
  lab_load_roles "${name}"
  bg="${LAB_BG_BASE[$i]}"
  lab_nearest256 "${LAB_TEXT}";      land_text="${LAB_RGB}"
  lab_nearest256 "${LAB_MUTED}";     land_muted="${LAB_RGB}"
  lab_nearest256 "${LAB_SEL}";       land_sel="${LAB_RGB}"
  lab_nearest256 "${LAB_SELBORDER}"; land_sb="${LAB_RGB}"
  lab_nearest256 "${LAB_BORDER}";    land_bd="${LAB_RGB}"
  lab_nearest256 "${LAB_HLFG}";      land_hf="${LAB_RGB}"
  lab_nearest256 "${LAB_HLBG}";      land_hb="${LAB_RGB}"
  c_text="$(lab_contrast "${land_text}" "${bg}")"
  c_muted="$(lab_contrast "${land_muted}" "${bg}")"
  c_sel="$(lab_contrast "${land_sel}" "${bg}")"
  c_sb="$(lab_contrast "${land_sb}" "${bg}")"
  c_bd="$(lab_contrast "${land_bd}" "${bg}")"
  c_pill="$(lab_contrast "${land_hf}" "${land_hb}")"
  awk -v r="${c_text}"  'BEGIN { exit !(r >= 4.5) }' || { pal_text_low=$(( pal_text_low + 1 ));
    printf 'FAIL [%s] %s 正文对比度 %s < 4.5（%s→%s on %s）\n' "${TESTS_NAME}" "${name}" "${c_text}" "${LAB_TEXT}" "${land_text}" "${bg}"; }
  awk -v r="${c_sel}"   'BEGIN { exit !(r >= 4.5) }' || { pal_sel_low=$(( pal_sel_low + 1 ));
    printf 'FAIL [%s] %s 选中正文对比度 %s < 4.5（%s→%s on %s）\n' "${TESTS_NAME}" "${name}" "${c_sel}" "${LAB_SEL}" "${land_sel}" "${bg}"; }
  awk -v r="${c_muted}" 'BEGIN { exit !(r >= 3.0) }' || { pal_muted_low=$(( pal_muted_low + 1 ));
    printf 'FAIL [%s] %s 次要文字对比度 %s < 3.0（%s→%s on %s）\n' "${TESTS_NAME}" "${name}" "${c_muted}" "${LAB_MUTED}" "${land_muted}" "${bg}"; }
  awk -v a="${c_sb}" -v b="${c_bd}" 'BEGIN { exit !(a > b) }' || { pal_border_weak=$(( pal_border_weak + 1 ));
    printf 'FAIL [%s] %s 选中方框(%s) 没有比未选中方框(%s) 更亮\n' "${TESTS_NAME}" "${name}" "${c_sb}" "${c_bd}"; }
  awk -v r="${c_pill}" 'BEGIN { exit !(r >= 4.5) }' || { pal_pill_low=$(( pal_pill_low + 1 ));
    printf 'FAIL [%s] %s 反显药丸对比度 %s < 4.5（%s on %s）\n' "${TESTS_NAME}" "${name}" "${c_pill}" "${land_hf}" "${land_hb}"; }
done
assert_eq "${pal_text_low}"    "0" "每套方案的正文对底色必须 ≥ 4.5"
assert_eq "${pal_sel_low}"     "0" "每套方案的选中正文对底色必须 ≥ 4.5（选中态也要能读）"
assert_eq "${pal_muted_low}"   "0" "每套方案的次要文字对底色必须 ≥ 3.0"
assert_eq "${pal_pill_low}"    "0" "反显药丸的前景对底色必须 ≥ 4.5（整行铺底最容易翻车）"
assert_eq "${pal_border_weak}" "0" "选中方框必须比未选中方框更亮（结构性线索要看得出来）"

# 选中正文必须与「普通正文」「次要文字」是**不同的 256 索引**。否则首页选中卡片的
# 名称会跟自己的描述行（UI_MUTED）或未选中卡片的名称（UI_TEXT）一个颜色，
# 「选中」就只剩加粗一个线索了。这条曾经真的抓到过 nord-frost 的 bug：
# nord9(#81A1C1) 与 nord7(#8FBCBB) 在 256 里落到同一个索引 109。
t_begin "选中正文与正文/次要文字必须不同色"
pal_sel_dup=0
for i in "${!LAB_NAMES[@]}"; do
  name="${LAB_NAMES[$i]}"
  lab_load_roles "${name}"
  lab_nearest256 "${LAB_SEL}";   i_sel="${LAB_IDX}"
  lab_nearest256 "${LAB_TEXT}";  i_text="${LAB_IDX}"
  lab_nearest256 "${LAB_MUTED}"; i_muted="${LAB_IDX}"
  if [[ "${i_sel}" == "${i_text}" || "${i_sel}" == "${i_muted}" ]]; then
    pal_sel_dup=$(( pal_sel_dup + 1 ))
    printf 'FAIL [%s] %s：UI_SEL 索引 %s 与 UI_TEXT %s / UI_MUTED %s 撞色\n' \
      "${TESTS_NAME}" "${name}" "${i_sel}" "${i_text}" "${i_muted}"
  fi
done
assert_eq "${pal_sel_dup}" "0" "选中正文与正文/次要文字不得落到同一个 256 索引"

# 低于 AA 但仍在用的角色（次要文字 3.0-4.5、浅色主题里的状态色）逐条列出来。
# 这些**不断言**（它们是上游体系的原色，改了就不再是该配色），但报告里必须诚实写清楚。
printf '\n提示：以下角色（按 256 落点色算）对比度 < 4.5，保留但需在报告里说明：\n'
for i in "${!LAB_NAMES[@]}"; do
  name="${LAB_NAMES[$i]}"
  lab_load_roles "${name}"
  bg="${LAB_BG_BASE[$i]}"
  for role in muted accent danger success warning purple; do
    lab_role_hex "${role}"
    lab_nearest256 "${LAB_HEX_ONE}"
    r="$(lab_contrast "${LAB_RGB}" "${bg}")"
    awk -v r="${r}" 'BEGIN { exit !(r < 4.5) }' && \
      printf '  %-13s %-9s %s→%s on %s = %s\n' "${name}" "${role}" "${LAB_HEX_ONE}" "${LAB_RGB}" "${bg}" "${r}"
  done
done

# ===========================================================================
# 5. 响应式硬不变量 + 换配色不改几何
# ===========================================================================
# 渲染的是**产品路径本身**（_home_layout + _home_palette + _home_render_*），
# 不是另画的示意网格。两条不变量：
#   ① 每套方案 × 每档宽度，任何一行 ≤ UI_COLS；
#   ② 任意两套方案在同一宽度下**逐行等宽**（颜色绝不许影响几何），
#      且与「把颜色全清空」的渲染也逐行等宽。
PAL_WIDTHS=(16 24 40 79 100 200)

# 渲染并逐行量宽 → 全局 PAL_W[]（每行显示列数）。
pal_frame() {
  local w="$1" line
  PAL_W=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    pal_strip "${line}"
    _core_width "${PAL_PLAIN}"
    PAL_W+=("${_CORE_W}")
  done < <(lab_render_home "${w}")
}

# 清空全部角色颜色 → 全局变量（用于「无色渲染」对照）。返回前由调用方 lab_apply 复原。
pal_blank_colors() {
  local v
  for v in "${PAL_ROLE_VARS[@]}"; do printf -v "${v}" '%s' ""; done
}

t_begin "响应式硬不变量与几何不变"
pal_overflow=0
pal_geom_diff=0
pal_blank_diff=0
for w in "${PAL_WIDTHS[@]}"; do
  pal_ref_name=""; pal_ref_sig=""
  for name in "${LAB_NAMES[@]}"; do
    pal_use "${name}"
    pal_frame "${w}"
    sig="${PAL_W[*]}"

    # ① 任何一行都不得超过 UI_COLS（宽度为 0 的空行不算）
    li=0
    for x in "${PAL_W[@]}"; do
      li=$(( li + 1 ))
      (( x == 0 )) && continue
      if (( x > w )); then
        pal_overflow=$(( pal_overflow + 1 ))
        printf 'FAIL [%s] %s @%d 列：第 %d 行实测 %d 列\n' "${TESTS_NAME}" "${name}" "${w}" "${li}" "${x}"
      fi
    done

    # ② 跨方案逐行等宽
    if [[ -z "${pal_ref_sig}" ]]; then
      pal_ref_name="${name}"; pal_ref_sig="${sig}"
    elif [[ "${sig}" != "${pal_ref_sig}" ]]; then
      pal_geom_diff=$(( pal_geom_diff + 1 ))
      read -ra _a <<< "${sig}"
      read -ra _b <<< "${pal_ref_sig}"
      printf 'FAIL [%s] %d 列：%s 与 %s 逐行宽度不同（行数 %d vs %d）\n' \
        "${TESTS_NAME}" "${w}" "${name}" "${pal_ref_name}" "${#_a[@]}" "${#_b[@]}"
      for (( k = 0; k < ${#_a[@]} && k < ${#_b[@]}; k++ )); do
        if (( _a[k] != _b[k] )); then
          printf '     第 %d 行：%d 列 vs %d 列\n' "$(( k + 1 ))" "${_a[k]}" "${_b[k]}"
          break
        fi
      done
    fi
  done

  # ③ 与「全无色」渲染对照：颜色完全不影响几何
  pal_blank_colors
  pal_frame "${w}"
  sig="${PAL_W[*]}"
  if [[ "${sig}" != "${pal_ref_sig}" ]]; then
    pal_blank_diff=$(( pal_blank_diff + 1 ))
    printf 'FAIL [%s] %d 列：无色渲染与带色渲染逐行宽度不同\n' "${TESTS_NAME}" "${w}"
  fi
  pal_use "${LAB_NAMES[0]}"
done
assert_eq "${pal_overflow}"   "0" "每套方案在每个宽度下都不得有行超过 UI_COLS"
assert_eq "${pal_geom_diff}"  "0" "换配色不得改变任何一行的宽度"
assert_eq "${pal_blank_diff}" "0" "清空颜色后逐行宽度必须不变"

# 宽度反过来也要「真的量到了东西」：帧里必须有若干非空行，否则上面全是空集的空真命题。
t_begin "渲染确实产出了内容"
pal_lines="$(printf '%s\n' "${PAL_W[@]}" | wc -l | tr -d '[:space:]')"
pal_nonzero=0
for x in "${PAL_W[@]}"; do (( x > 0 )) && pal_nonzero=$(( pal_nonzero + 1 )); done
assert_ok test "${pal_lines}"   -ge 10
assert_ok test "${pal_nonzero}" -ge 10

# 负向对照：往同一套量宽链路里喂一条必然超宽的行，溢出计数必须涨。
# （放在最后，因为要改动全局变量。）
_neg_overflow_detected() {
  pal_frame 100
  local before="${#PAL_W[@]}" hit=0 x
  PAL_W+=("201")          # 人为加一条 201 列的行
  for x in "${PAL_W[@]}"; do (( x > 100 )) && hit=$(( hit + 1 )); done
  [[ "${#PAL_W[@]}" -gt "${before}" && "${hit}" -ge 1 ]]
}
t_begin "负向对照：溢出必须能被计数"
assert_ok _neg_overflow_detected

# ===========================================================================
# 6. 回归护栏：现有 5 套主题本轮一字未改
# ===========================================================================
# 用户明确要求：dark 是**已认可的默认观感**，SGR 值逐字节冻结；本轮候选一律作为
# **新增**主题提出，现有 5 套（dark / light / nord / gruvbox / high-contrast）不许动。
t_begin "现有主题未被改动"
# 只断言「原有 5 套还在、且值没变」，**不**断言总数恰好是 5：候选方案正式落地时会
# 往 UI_THEME_NAMES 里加新主题（那是后续实现步骤），本条护栏不该被那次改动弄红。
assert_ok test "${#UI_THEME_NAMES[@]}" -ge 5
for t in dark light nord gruvbox high-contrast; do
  assert_ok ui_theme_valid "${t}"
done

ui_theme_init dark
assert_eq "${UI_THEME}"     "dark"                "dark 仍是默认主题"
assert_eq "${UI_ACCENT}"    "$(core_sgr 39)"      "dark 的 UI_ACCENT 应冻结为 39"
assert_eq "${UI_TEXT}"      "$(core_sgr 252)"     "dark 的 UI_TEXT 应冻结为 252"
assert_eq "${UI_MUTED}"     "$(core_sgr 244)"     "dark 的 UI_MUTED 应冻结为 244"
assert_eq "${UI_BORDER}"    "$(core_sgr 239)"     "dark 的 UI_BORDER 应冻结为 239"
assert_eq "${UI_HL}"        "$(core_sgr 0 24 bold)"   "dark 的 UI_HL 应冻结"
assert_eq "${UI_HL_FG}"     "$(core_sgr 15 24 bold)"  "dark 的 UI_HL_FG 应冻结"
assert_eq "${UI_TITLE}"     "$(core_sgr 39 bold)"     "dark 的 UI_TITLE 应冻结"
assert_eq "${UI_SEL}"       "$(core_sgr 81 bold)"     "dark 的 UI_SEL 应冻结为 81+bold"

# 现有 5 套主题的 UI_SEL 都必须是**纯前景、不含背景**——这正是「不要异常填充」那条约定的
# 代码级表达（首页选中卡片正文用它；带背景的就是那个 9 列色块 bug 的形状）。
t_begin "现有主题的 UI_SEL 无背景"
pal_ship_bg=0
for t in dark light nord gruvbox high-contrast; do
  ui_theme_init "${t}"
  [[ -n "${UI_SEL}" ]] || { pal_ship_bg=$(( pal_ship_bg + 1 )); printf 'FAIL [%s] %s 的 UI_SEL 为空\n' "${TESTS_NAME}" "${t}"; }
  [[ "${UI_SEL}" == *"48;5;"* ]] && { pal_ship_bg=$(( pal_ship_bg + 1 )); printf 'FAIL [%s] %s 的 UI_SEL 带背景色\n' "${TESTS_NAME}" "${t}"; }
done
assert_eq "${pal_ship_bg}" "0" "UI_SEL 必须是纯前景角色"
ui_theme_init dark

# ===========================================================================
# 7. 回归护栏：新品主题 == 展示台方案；全主题背景色契约
# ===========================================================================
# 上一节钉住「原有 5 套一字未改」，这一节钉住**本轮新增的 5 套**：
#   (a) 产品的 12 个角色必须与 docs/palette-lab.sh 里同名方案**逐字节相同**。
#       展示台是这些主题的设计源与对外承诺：两边一旦脱钩（改了产品值却没同步展示台，
#       或反之），用户切过去看到的就不是当初被认可的那套观感，而且再没人会发现。
#   (b) 全部 10 套主题 × 12 个角色：**只有 UI_HL / UI_HL_FG 允许出现 48;5; 背景色**。
#       这是首页 9 列色块那个 bug 的代码级护栏——非铺满角色带背景，画出来就是那块方形。
#
# 配对说明：5 套新品在两侧**同名**（mocha / tokyonight / kanagawa / latte / rosepine），
# 直接同名配对。展示台里另外两套 nord-frost / gruvbox-warm 是**未采用**的候选，
# 与产品的 nord / gruvbox **刻意不配对**（它们本来就不是同一套设计）。
t_begin "新品主题与展示台方案逐字节一致"
PAL_PRODUCT_ROLES=(
  UI_TITLE UI_TEXT UI_MUTED UI_BORDER UI_ACCENT UI_SUCCESS UI_WARNING
  UI_DANGER UI_PURPLE UI_SEL UI_HL UI_HL_FG
)
PAL_NEW_THEMES=(mocha tokyonight kanagawa latte rosepine)
pal_new_bad=0
for t in "${PAL_NEW_THEMES[@]}"; do
  declare -A pal_prod=()
  ui_theme_apply "${t}"
  for v in "${PAL_PRODUCT_ROLES[@]}"; do pal_prod["${v}"]="${!v}"; done
  if ! lab_apply "${t}"; then
    pal_new_bad=$(( pal_new_bad + 1 ))
    printf 'FAIL [%s] 展示台里没有方案 %s，无法比对\n' "${TESTS_NAME}" "${t}"
    continue
  fi
  for v in "${PAL_PRODUCT_ROLES[@]}"; do
    if [[ "${pal_prod[$v]}" != "${!v}" ]]; then
      pal_new_bad=$(( pal_new_bad + 1 ))
      printf 'FAIL [%s] %s 的 %s：产品 %q ≠ 展示台 %q\n' \
        "${TESTS_NAME}" "${t}" "${v}" "${pal_prod[$v]}" "${!v}"
    fi
  done
  unset pal_prod
done
assert_eq "${pal_new_bad}" "0" "5 套新品主题 × 12 角色的产品值都应与展示台方案逐字节一致"

# 全主题背景色扫描器：扫「当前已应用主题」的 12 个角色 →
#   PAL_LEAK   非铺满角色里带 48;5; 的个数（必须为 0）
#   PAL_FILLOK UI_HL / UI_HL_FG 里带 48;5; 的个数（每套应恰为 2）
#   PAL_EMPTY  空角色个数（必须为 0）
pal_scan_roles() {
  local v
  PAL_LEAK=0; PAL_FILLOK=0; PAL_EMPTY=0
  for v in "${PAL_PRODUCT_ROLES[@]}"; do
    [[ -n "${!v}" ]] || PAL_EMPTY=$(( PAL_EMPTY + 1 ))
    if [[ "${v}" == "UI_HL" || "${v}" == "UI_HL_FG" ]]; then
      [[ "${!v}" == *"48;5;"* ]] && PAL_FILLOK=$(( PAL_FILLOK + 1 ))
      continue
    fi
    [[ "${!v}" == *"48;5;"* ]] && PAL_LEAK=$(( PAL_LEAK + 1 ))
  done
}

t_begin "全主题只有 UI_HL/UI_HL_FG 可带背景色"
pal_empty_bad=0; pal_leak_bad=0; pal_fill_ok=0
for t in "${UI_THEME_NAMES[@]}"; do
  ui_theme_init "${t}"
  pal_scan_roles
  pal_empty_bad=$(( pal_empty_bad + PAL_EMPTY ))
  pal_leak_bad=$(( pal_leak_bad + PAL_LEAK ))
  pal_fill_ok=$(( pal_fill_ok + PAL_FILLOK ))
  (( PAL_EMPTY > 0 || PAL_LEAK > 0 )) && \
    printf 'FAIL [%s] %s：空角色 %d 个、越权背景 %d 个\n' "${TESTS_NAME}" "${t}" "${PAL_EMPTY}" "${PAL_LEAK}"
done
assert_eq "${pal_empty_bad}" "0" "10 套主题的 12 个角色都不得为空"
assert_eq "${pal_leak_bad}" "0" "除 UI_HL / UI_HL_FG 外，任何主题的角色都不得带 48;5; 背景"
# 「恰好为 2 × 主题数」：证明 UI_HL / UI_HL_FG 真的带背景——否则上一条可能是空集真命题。
assert_eq "${pal_fill_ok}" "$(( 2 * ${#UI_THEME_NAMES[@]} ))" \
  "每套主题的 UI_HL / UI_HL_FG 都应是带背景的铺满角色"

# 负向对照：往一个非铺满角色里塞背景色，扫描器必须真的报出 1 个泄漏。
_neg_bg_leak_detected() {
  local saved="${UI_TEXT}"
  UI_TEXT=$'\033[38;5;252;48;5;24m'
  pal_scan_roles
  UI_TEXT="${saved}"
  (( PAL_LEAK == 1 ))
}
assert_ok _neg_bg_leak_detected
# 反向对照：干净的 dark 主题下扫描器必须报 0 泄漏且 2 个铺满角色（防上一条恒真）。
_neg_bg_leak_clear() {
  ui_theme_init dark
  pal_scan_roles
  (( PAL_LEAK == 0 && PAL_FILLOK == 2 && PAL_EMPTY == 0 ))
}
assert_ok _neg_bg_leak_clear
ui_theme_init dark

# ===========================================================================
# 8. 断言自检（负向对照）：证明上面的断言真「失败得出来」
# ===========================================================================
# 每个对照函数在返回前把「故意制造的失败」从计数器里抹掉，所以故意造的失败不污染总账；
# 自检本身的结论由外层 assert_ok 记入总账——自检一旦失效，测试就会红。
t_begin "断言自检（负向对照）"

# 7.1 清单少一项时，「长度一致」类断言必须失败。
_neg_len_mismatch_fails() {
  local before="${TESTS_FAIL}" after
  assert_eq "${#LAB_LABELS[@]}" "$(( ${#LAB_NAMES[@]} + 1 ))" "故意错配"
  after="${TESTS_FAIL}"
  TESTS_FAIL="${before}"
  [[ "${after}" -gt "${before}" ]]
}
assert_ok _neg_len_mismatch_fails

# 7.2 反向：长度真一致时不得误判失败（防止 7.1 恒成立而失去意义）。
_neg_len_match_passes() {
  local before="${TESTS_FAIL}" after
  assert_eq "${#LAB_LABELS[@]}" "${#LAB_NAMES[@]}" "应当一致"
  after="${TESTS_FAIL}"
  [[ "${after}" -eq "${before}" ]]
}
assert_ok _neg_len_match_passes

# 7.3 几何断言必须真的会红：把一套方案的一行人为加宽 1 列，跨方案比较必须报差异。
_neg_geometry_fails() {
  local before="${TESTS_FAIL}" ok=0
  lab_apply "${LAB_NAMES[1]}"
  pal_frame 100
  local ref="${PAL_W[*]}"
  PAL_W[3]=$(( PAL_W[3] + 1 ))     # 人为破坏第 4 行
  local cur="${PAL_W[*]}"
  [[ "${cur}" != "${ref}" ]] && ok=1
  TESTS_FAIL="${before}"
  [[ "${ok}" == "1" ]]
}
assert_ok _neg_geometry_fails

# 7.4 负向：两套方案的真实渲染必须逐行等宽（防止 7.3 恒真）。
_neg_geometry_ok_passes() {
  local a b
  lab_apply "${LAB_NAMES[0]}"; pal_frame 100; a="${PAL_W[*]}"
  lab_apply "${LAB_NAMES[5]}"; pal_frame 100; b="${PAL_W[*]}"
  [[ "${a}" == "${b}" ]]
}
assert_ok _neg_geometry_ok_passes

# 复原成第一套方案，避免污染后续（若有）断言。
lab_apply "${LAB_NAMES[0]}"

# ===========================================================================
# 10. UI_BG（第 13 个角色）——「展示台是唯一权威来源」这条承诺的守门人
# ===========================================================================
# docs/palette-lab.sh 的底色表注释写着：它是**产品 UI_BG 的唯一权威来源**。
# 但在这一节之前，**没有任何断言读过这句话**：第 7 节只比了 12 个前景角色
# （UI_TITLE…UI_HL_FG），UI_BG 恰好是第 13 个、被漏掉的那个。也就是说
# 「改了产品底色却没同步展示台」（或反之）目前**没人会发现**。
#
# 判据：两边**各算一次**再比，期望值不抄任何人的参考数字——
#   产品侧：  ui_theme_init <主题> 之后从 UI_BG（\033[48;5;Nm）里抠出 N；
#   展示台侧：lab_nearest256 "<该方案的 hex 底色>" 得到的 256 索引。
# 两端相等才算过。写死「mocha 是 235」这种断言测的是转抄，不是代码。

# 从 UI_BG 里抠出 48;5; 的索引（不是背景色就返回空串，让断言去红）。
pal_bg_index() {
  local s="${1:-}" rest
  [[ "${s}" == *"48;5;"* ]] || { printf ''; return 0; }
  rest="${s#*48;5;}"
  printf '%s' "${rest%%[!0-9]*}"
}

# 抠索引这一步本身必须先被证明是活的（否则两边都返回空串会「相等」）。
t_begin "UI_BG 索引抠取器灵敏度"
assert_eq "$(pal_bg_index $'\033[48;5;233m')" "233" "应抠出 233"
assert_eq "$(pal_bg_index $'\033[48;5;16m')"  "16"  "应抠出 16"
assert_eq "$(pal_bg_index $'\033[38;5;252m')" ""    "纯前景色不应被当成底色"
assert_eq "$(pal_bg_index '')"                ""    "空串应返回空"

# 候选方案名 → 产品主题名。
# 5 套同名直接配对；nord-frost / gruvbox-warm 是展示台里的**候选名**，本轮产品落地的是
# 同源主题 nord / gruvbox（展示台自己在 LAB_NOTES 里写明这份同源关系）。
# 注意这与第 7 节的「nord-frost / gruvbox-warm 刻意不配对」不矛盾：那边比的是 12 个
# **前景角色**（两套设计各自选色不同），这边比的是**底色**（同源 → 同一支基色）。
declare -A PAL_LAB_TO_THEME=(
  [mocha]=mocha
  [tokyonight]=tokyonight
  [nord-frost]=nord
  [gruvbox-warm]=gruvbox
  [kanagawa]=kanagawa
  [latte]=latte
  [rosepine]=rosepine
)

t_begin "7 套候选方案 × UI_BG == 展示台基准底色的 256 落点"
pal_bg_bad=0
pal_bg_seen=0
for i in "${!LAB_NAMES[@]}"; do
  name="${LAB_NAMES[$i]}"
  hex="${LAB_BG_BASE[$i]}"
  theme="${PAL_LAB_TO_THEME[${name}]:-}"
  if [[ -z "${theme}" ]]; then
    pal_bg_bad=$(( pal_bg_bad + 1 ))
    printf 'FAIL [%s] 方案 %s 没有登记对应的产品主题名\n' "${TESTS_NAME}" "${name}"
    continue
  fi
  lab_nearest256 "${hex}"; want="${LAB_IDX}"
  ui_theme_init "${theme}"
  got="$(pal_bg_index "${UI_BG}")"
  if [[ -z "${got}" || "${got}" != "${want}" ]]; then
    pal_bg_bad=$(( pal_bg_bad + 1 ))
    printf 'FAIL [%s] %s(→产品 %s)：UI_BG 索引 %q ≠ lab_nearest256(%s)=%s\n' \
      "${TESTS_NAME}" "${name}" "${theme}" "${got}" "${hex}" "${want}"
  fi
  # 反向对照用：两边各自到底算出了什么，留痕便于人复核。
  printf '  %-14s → %-12s %-9s nearest256=%s  产品 UI_BG=%s\n' \
    "${name}" "${theme}" "${hex}" "${want}" "${got:-<无>}"
  pal_bg_seen=$(( pal_bg_seen + 1 ))
done
assert_eq "${pal_bg_bad}"  "0" "7 套候选方案的 UI_BG 索引都必须等于展示台基准底色的 256 落点"
assert_eq "${pal_bg_seen}" "7" "必须真的逐套验过（防循环空转）"

t_begin "3 套既有主题 × UI_BG == 展示台 LAB_BG_EXISTING 的 256 落点"
# 这一条同时给 LAB_BG_EXISTING 一个**真正的消费点**：它此前只登记了值，没有任何产品代码
# 或测试读它——与「LAB_BG_BASE 旧写法里多出来的 3 项没人读」是同一类味道。
pal_bg_ex_bad=0
pal_bg_ex_seen=0
for theme in dark light high-contrast; do
  hex="${LAB_BG_EXISTING[${theme}]:-}"
  if [[ -z "${hex}" ]]; then
    pal_bg_ex_bad=$(( pal_bg_ex_bad + 1 ))
    printf 'FAIL [%s] LAB_BG_EXISTING 缺少 %s 的底色登记\n' "${TESTS_NAME}" "${theme}"
    continue
  fi
  lab_nearest256 "${hex}"; want="${LAB_IDX}"
  ui_theme_init "${theme}"
  got="$(pal_bg_index "${UI_BG}")"
  if [[ -z "${got}" || "${got}" != "${want}" ]]; then
    pal_bg_ex_bad=$(( pal_bg_ex_bad + 1 ))
    printf 'FAIL [%s] %s：UI_BG 索引 %q ≠ lab_nearest256(%s)=%s\n' \
      "${TESTS_NAME}" "${theme}" "${got}" "${hex}" "${want}"
  fi
  printf '  %-14s %-9s nearest256=%s  产品 UI_BG=%s\n' \
    "${theme}" "${hex}" "${want}" "${got:-<无>}"
  pal_bg_ex_seen=$(( pal_bg_ex_seen + 1 ))
done
assert_eq "${pal_bg_ex_bad}"  "0" "3 套既有主题的 UI_BG 索引都必须等于 LAB_BG_EXISTING 的 256 落点"
assert_eq "${pal_bg_ex_seen}" "3" "必须真的逐套验过（防循环空转）"

# 负向对照：把产品侧的期望值改一位，抠索引 + 比较这条链路必须真的报错
# （证明上面两条不是「两个空串相等」那种恒真）。
t_begin "负向对照：UI_BG 索引不一致必须被报出"
_neg_bg_index_mismatch_detected() {
  lab_nearest256 "${LAB_BG_EXISTING[dark]}"; local want="${LAB_IDX}"
  ui_theme_init dark
  local got; got="$(pal_bg_index "${UI_BG}")"
  [[ "${got}" == "${want}" ]] || return 1      # 现状必须一致
  local saved="${UI_BG}"
  UI_BG=$'\033[48;5;231m'                       # 注入一个错的底色
  got="$(pal_bg_index "${UI_BG}")"
  UI_BG="${saved}"
  [[ "${got}" != "${want}" ]]                   # 注入后必须能看出不一致
}
assert_ok _neg_bg_index_mismatch_detected
ui_theme_init dark

rm -rf "${TMPROOT}"
t_summary

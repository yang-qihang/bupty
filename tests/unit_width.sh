#!/usr/bin/env bash
# tests/unit_width.sh —— 显示宽度引擎单测（对应 lib/core.sh 的宽度部分）
#
# 覆盖两种 bash 语义，本文件在哪种模式下跑都应当全绿：
#   * 字节模式：LANG/LC_ALL/LC_CTYPE 都没设（C locale，MSYS2/Git Bash 常见），BUPTY_MB=0
#   * 字符模式：LANG=zh_CN.UTF-8 之类（WSL/Linux，以及装了 UTF-8 locale 的 Git Bash），BUPTY_MB=1
# 所有非 ASCII 字符都用 \xNN 字节字面量构造，源码里不出现非 ASCII 字符，
# 免得文件本身在别处被按别的编码重新解读。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck source=/dev/null
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# ---------------------------------------------------------------------------
# 测试专用小工具
# ---------------------------------------------------------------------------

# 取出 _core_width 的结果（它只写全局 _CORE_W，不往 stdout 写东西）。
w_width() {
  _core_width "${1:-}"
  printf '%s' "${_CORE_W}"
}

# 在「强制字节模式」下数字节数：与当前 locale / BUPTY_MB 无关。
w_bytes() {
  local s="${1:-}"
  ( LC_ALL=C; printf '%s' "${#s}" )
}

# 在「强制字节模式」下取第 i 个字节的数值。
w_byte_at() {
  local s="${1:-}" i="${2:-0}"
  ( LC_ALL=C; printf '%d' "'${s:i:1}" )
}

# 纯 bash 的 UTF-8 结构校验：孤立续接字节（10xxxxxx）和「被截断的多字节序列」
# 都判为非法。截断测试靠它把关——老引擎用 ${s%?} 砍字节，正好会踩这两个坑。
w_valid_utf8() {
  local s="${1:-}" i=0 n b k need
  n="$(w_bytes "${s}")"
  while ((i < n)); do
    b="$(w_byte_at "${s}" "${i}")"
    if ((b < 0x80)); then
      i=$((i + 1))
      continue
    fi
    if ((b >= 0xC2 && b <= 0xDF)); then
      need=1
    elif ((b >= 0xE0 && b <= 0xEF)); then
      need=2
    elif ((b >= 0xF0 && b <= 0xF4)); then
      need=3
    else
      return 1 # 裸续接字节，或 0xC0/0xC1/0xF5+ 这类非法首字节
    fi
    if ((i + need >= n)); then
      return 1 # 序列被尾部截断
    fi
    for ((k = 1; k <= need; k++)); do
      b="$(w_byte_at "${s}" "$((i + k))")"
      if (((b & 0xC0) != 0x80)); then
        return 1
      fi
    done
    i=$((i + need + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# 测试字符（一律用字节字面量）
# ---------------------------------------------------------------------------
printf -v W_ABC 'abc'                                                     # 纯 ASCII
printf -v W_HAN2 '\xE8\xAF\xBE\xE8\xA1\xA8'                               # 课表
printf -v W_HAN6 '\xE8\xAF\xBE\xE8\xA1\xA8\xE8\xAF\xBE\xE8\xA1\xA8\xE8\xAF\xBE\xE8\xA1\xA8' # 课表 ×3
printf -v W_FWCOMMA '\xEF\xBC\x8C'                                        # ，U+FF0C（全角，宽）
printf -v W_BOXH '\xE2\x94\x80'                                           # ─ U+2500（框线，歧义）
printf -v W_BLOCK '\xE2\x96\x88'                                          # █ U+2588（方块，歧义）
printf -v W_UP '\xE2\x86\x91'                                             # ↑ U+2191（箭头，歧义）
printf -v W_CIRC '\xE2\x91\xA0'                                           # ① U+2460（带圈数字，歧义）
printf -v W_ACCENT '\xCC\x81'                                             # ́ U+0301（组合记号，零宽）
printf -v W_MIX '\xE2\x94\x82 \xE8\xAF\xBE\xE8\xA1\xA8 \xE2\x94\x82'     # │ 课表 │
printf -v W_ANGLE '\xE2\x80\xBA'                                          # › U+203A（Unicode 窄，界面选择行标记）
printf -v W_SMALLTRI '\xE2\x96\xB8'                                       # ▸ U+25B8（Unicode 窄，首页未选中标记）
printf -v W_TRI '\xE2\x96\xB6'                                            # ▶ U+25B6（真歧义，首页选中标记）

# 模式自检：两种语义下 _bupty_detect_mb 都要给出正确结论。
t_begin "环境探测"
case "${BUPTY_MB}" in
  0) assert_eq "${#W_HAN2}" "6" "字节模式下「课表」应为 6 字节" ;;
  1) assert_eq "${#W_HAN2}" "2" "字符模式下「课表」应为 2 字符" ;;
  *) assert_eq "${BUPTY_MB}" "0或1" "BUPTY_MB 只能是 0 或 1" ;;
esac

# ---- 1. 纯 ASCII ----------------------------------------------------------
t_begin "1 ASCII"
assert_eq "$(w_width "${W_ABC}")" "3" "abc 宽度为 3"

# ---- 2. 汉字 --------------------------------------------------------------
t_begin "2 汉字"
assert_eq "$(w_width "${W_HAN2}")" "4" "课表 宽度为 4（不是字节模式下错误的 6）"

# ---- 3. 全角标点 ----------------------------------------------------------
t_begin "3 全角标点"
assert_eq "$(w_width "${W_FWCOMMA}")" "2" "，U+FF0C 宽度为 2"

# ---- 8. 空串 --------------------------------------------------------------
t_begin "8 空串"
assert_eq "$(w_width "")" "0" "空串宽度为 0"

# ---- 4/5/6/7. 歧义字符跟随 BUPTY_AMBIG_W --------------------------------
t_begin "4/5/6/7 歧义字符"
BUPTY_AMBIG_W=1
assert_eq "$(w_width "${W_BOXH}")" "1" "BUPTY_AMBIG_W=1 时 ─ U+2500 为 1 列"
assert_eq "$(w_width "${W_BLOCK}")" "1" "BUPTY_AMBIG_W=1 时 █ U+2588 为 1 列"
assert_eq "$(w_width "${W_UP}")" "1" "BUPTY_AMBIG_W=1 时 ↑ U+2191 为 1 列"
assert_eq "$(w_width "${W_CIRC}")" "1" "BUPTY_AMBIG_W=1 时 ① U+2460 为 1 列"
assert_eq "$(w_width "${W_MIX}")" "8" "BUPTY_AMBIG_W=1 时「│ 课表 │」为 8 列"

BUPTY_AMBIG_W=2
assert_eq "$(w_width "${W_BOXH}")" "2" "BUPTY_AMBIG_W=2 时 ─ U+2500 为 2 列"
assert_eq "$(w_width "${W_BLOCK}")" "2" "BUPTY_AMBIG_W=2 时 █ U+2588 为 2 列"
assert_eq "$(w_width "${W_UP}")" "2" "BUPTY_AMBIG_W=2 时 ↑ U+2191 为 2 列"
assert_eq "$(w_width "${W_CIRC}")" "2" "BUPTY_AMBIG_W=2 时 ① U+2460 为 2 列"
assert_eq "$(w_width "${W_MIX}")" "10" "BUPTY_AMBIG_W=2 时「│ 课表 │」为 10 列"
BUPTY_AMBIG_W=1

# 歧义开关不能影响「本来就宽」和「本来就窄」的字符。
assert_eq "$(w_width "${W_HAN2}")" "4" "切换 BUPTY_AMBIG_W 后汉字宽度不变"
assert_eq "$(w_width "${W_FWCOMMA}")" "2" "切换 BUPTY_AMBIG_W 后全角标点宽度不变"
assert_eq "$(w_width "${W_ABC}")" "3" "切换 BUPTY_AMBIG_W 后 ASCII 宽度不变"

# ---- 整块歧义区间里的「窄」例外 ------------------------------------------
# 引擎的歧义表是**整块区间**近似，会把少数 Unicode 判「窄(N)」的字符一起划进歧义类。
# 终端只加宽 Ambiguous、不加宽 Narrow，所以这些字符在任何终端里恒为 1 列。
# 曾经 › 和 ▸ 就被误判成歧义，在 BUPTY_AMBIG_W=2 的 CJK 终端上多算 1 列：
#   › 让 7 个视图的选择行高亮底色短 1 列；
#   ▸ 让首页档位 B 卡片的右边框比选中的 ▶ 那一行左移 1 列（框内错位，肉眼可见）。
t_begin "窄字符不受 BUPTY_AMBIG_W 影响"
for amb in 1 2; do
  BUPTY_AMBIG_W="${amb}"
  assert_eq "$(w_width "${W_ANGLE}")" "1" "BUPTY_AMBIG_W=${amb} 时 › U+203A 恒为 1 列"
  assert_eq "$(w_width "${W_SMALLTRI}")" "1" "BUPTY_AMBIG_W=${amb} 时 ▸ U+25B8 恒为 1 列"
done
# 对照组：把特判做过了头会把真歧义字符也钉死，这里钉住它们必须继续跟随开关。
BUPTY_AMBIG_W=2
assert_eq "$(w_width "${W_BOXH}")" "2" "对照组：AMBIG_W=2 时 ─ U+2500 仍为 2 列"
assert_eq "$(w_width "${W_BLOCK}")" "2" "对照组：AMBIG_W=2 时 █ U+2588 仍为 2 列"
# 选中/未选中这对标记的宽度**本来就不同**（▶ 真歧义、▸ 是窄），布局代码靠补空格
# 补偿，卡片总宽不变。这里钉住引擎的判定，防止日后被"统一成一样宽"改坏。
assert_eq "$(w_width "${W_TRI}")" "2" "AMBIG_W=2 时 ▶ U+25B6 为 2 列（真歧义）"
BUPTY_AMBIG_W=1
assert_eq "$(w_width "${W_TRI}")" "1" "AMBIG_W=1 时 ▶ U+25B6 为 1 列"

# ---- 零宽字符（不在必测清单里，但引擎声称支持） --------------------------
t_begin "零宽字符"
assert_eq "$(w_width "${W_ACCENT}")" "0" "组合记号 U+0301 为零宽"

# ---- 9. 非法 BUPTY_AMBIG_W 回退 ------------------------------------------
# 注意：这里必须在本进程里直接调 _core_width，不能走 $(w_width ...)，
# 否则「就地纠正 BUPTY_AMBIG_W」是发生在子 shell 里的，查不到。
t_begin "9 非法 BUPTY_AMBIG_W"
for bad in 0 5 abc; do
  BUPTY_AMBIG_W="${bad}"
  _core_width "${W_BOXH}"
  assert_eq "${_CORE_W}" "1" "BUPTY_AMBIG_W='${bad}' 时 ─ 回退为 1 列"
  assert_eq "${BUPTY_AMBIG_W}" "1" "BUPTY_AMBIG_W='${bad}' 应被就地纠正为 1"
done
BUPTY_AMBIG_W=""
_core_width "${W_BOXH}"
assert_eq "${_CORE_W}" "1" "BUPTY_AMBIG_W 为空时 ─ 回退为 1 列"
# 空值等价于「没设」，走 ${VAR:-1} 的分支，不会改写全局；只要求结果正确。
assert_eq "$(w_width "${W_CIRC}")" "1" "BUPTY_AMBIG_W 为空时 ① 也为 1 列"
BUPTY_AMBIG_W=1

# ---- 10. 截断不劈开 UTF-8 ------------------------------------------------
t_begin "10 截断的编码合法性"
out="$(core_fit "${W_HAN6}" 3)"
assert_eq "$(w_width "${out}")" "3" "core_fit 截断后宽度为 3"
assert_ok w_valid_utf8 "${out}"
# 「课表」×3 是 6 个字 = 12 列，截到 3 列只能是 1 个字（2 列）+ 1 个空格 = 4 字节。
# 这个精确字节数同时证明了「砍掉了完整的 3 字节汉字」和「只补了 1 个空格」。
assert_eq "$(w_bytes "${out}")" "4" "截断结果应为 1 个汉字 + 1 个空格（4 字节）"
# 再核对内容本身：应该是「课」+ 1 个空格。
printf -v want_han1 '\xE8\xAF\xBE '
assert_eq "${out}" "${want_han1}" "截断结果应为「课」加一个空格"

# 逐个宽度都试一遍，任何一个宽度都不能产生非法 UTF-8。
for n in 0 1 2 3 4 5 11 12 13; do
  assert_ok w_valid_utf8 "$(core_fit "${W_HAN6}" "${n}")"
done

# ---- 11. 补空格 ----------------------------------------------------------
t_begin "11 补空格"
assert_eq "$(core_fit 'ab' 5)" "ab   " "core_fit ab 5 应补 3 个空格"

# ---- 12. 截断后总宽度恰好等于目标 ----------------------------------------
t_begin "12 截断宽度"
for n in 0 1 2 3 4 7 12; do
  assert_eq "$(w_width "$(core_fit "${W_HAN6}" "${n}")")" "${n}" "core_fit 宽度 ${n} 应补齐到 ${n}"
done
for n in 0 1 5 10; do
  assert_eq "$(w_width "$(core_fit "${W_MIX}" "${n}")")" "${n}" "混排串 core_fit 宽度 ${n} 应补齐到 ${n}"
done

# ---- 13. 幂等 / 一致性 ---------------------------------------------------
t_begin "13 幂等性"
for pair in "0:${W_HAN6}" "3:${W_HAN6}" "5:${W_HAN6}" "20:${W_HAN6}" "4:${W_MIX}" "8:${W_MIX}"; do
  n="${pair%%:*}"
  s="${pair#*:}"
  once="$(core_fit "${s}" "${n}")"
  twice="$(core_fit "${once}" "${n}")"
  assert_eq "${twice}" "${once}" "core_fit ${n} 再套一次 core_fit ${n} 结果不变"
done
# 宽串截断后的宽度 = min(原宽, 目标)；窄串则原样保留内容、补空格到目标宽。
printf -v wide_want '%s%*s' "${W_HAN2}" 96 ''
assert_eq "$(core_fit "${W_HAN2}" 100)" "${wide_want}" "未超宽时原样保留内容（2 列 + 96 空格）"
assert_eq "$(w_width "$(core_fit "${W_HAN2}" 100)")" "100" "未超宽时补齐到目标宽 100"

# ---- 13b. core_clip：只截断、不补齐 --------------------------------------
# 和 core_fit 的唯一区别就是「不补空格」。这条区别必须钉死：视图里凡是套在
# 本来就不长的文本上的 core_clip，一旦退化成 core_fit，就会给每一行凭空添出
# 尾随空格——字节变了、每帧多传一大截空白，而肉眼完全看不出来。
t_begin "13b core_clip 只截断不补齐"
assert_eq "$(core_clip 'ab' 5)" "ab" "core_clip 不得补空格（core_fit 在此会补成 ab   ）"
assert_eq "$(core_clip "${W_HAN2}" 100)" "${W_HAN2}" "未超预算时逐字节原样返回"
assert_eq "$(core_clip "" 5)" "" "空串保持空串"
assert_eq "$(core_clip 'abc' 3)" "abc" "恰好等宽时原样返回"
assert_eq "$(w_width "$(core_clip "${W_HAN6}" 3)")" "3" "超预算时按显示列截断到 3"
assert_eq "$(w_width "$(core_clip "${W_HAN6}" 3)")" "$(w_width "$(core_fit "${W_HAN6}" 3)")" \
  "超预算时 core_clip 与 core_fit 截断结果宽度一致"
# 截断到 0 / 负宽度：退化成空串，绝不能因为负宽度反而变宽。
assert_eq "$(core_clip "${W_HAN6}" 0)" "" "宽度 0 截成空串"
assert_eq "$(core_clip "${W_HAN6}" -5)" "" "负宽度也截成空串"
# 幂等：再套一次不变（视图里可能连续截两层）。
for n in 0 3 5 20; do
  once="$(core_clip "${W_HAN6}" "${n}")"
  assert_eq "$(core_clip "${once}" "${n}")" "${once}" "core_clip ${n} 幂等"
done

# ---- 谓词接口 ------------------------------------------------------------
t_begin "谓词接口"
assert_ok _core_is_wide 0x4E00
assert_ok _core_is_wide 0xFF0C
assert_fail _core_is_wide 0x41
assert_fail _core_is_wide 0x2500
assert_ok _core_is_ambig 0x2500
assert_ok _core_is_ambig 0x2588
assert_ok _core_is_ambig 0x2191
assert_ok _core_is_ambig 0x25B6
assert_fail _core_is_ambig 0x4E00
# 整块歧义区间里的窄字符例外（Unicode 判 N，必须判窄）。
assert_fail _core_is_ambig 0x203A
assert_fail _core_is_ambig 0x25B8
assert_ok _core_is_zero 0x0301
assert_fail _core_is_zero 0x41
# 十进制和十六进制都要认。
_core_cols 9608
assert_eq "${_CORE_CLASS}" "3" "十进制 9608（█）应归为歧义"
_core_cols 0x2588
assert_eq "${_CORE_CLASS}" "3" "十六进制 0x2588（█）应归为歧义"
_core_cols 0x4E00
assert_eq "${_CORE_COLS}" "2" "0x4E00（一）应为 2 列"
# 非法码点在 set -u 下丢进算术会直接打死进程，这里必须被净化成窄字符而不是崩掉。
_core_cols "abc"
assert_eq "${_CORE_CLASS}" "1" "码点 'abc' 应净化为窄字符"
_core_cols "12abc"
assert_eq "${_CORE_CLASS}" "1" "码点 '12abc' 应净化为窄字符"
_core_cols ""
assert_eq "${_CORE_COLS}" "1" "空码点应为 1 列"
_core_cols "0x"
assert_eq "${_CORE_COLS}" "1" "码点 '0x' 应为 1 列"

# ---- core_pad 行为保持不变 ----------------------------------------------
t_begin "core_pad"
assert_eq "$(core_pad "${W_HAN2}" 6)" "  " "core_pad 课表 6 应补 2 个空格（6-4）"
assert_eq "$(core_pad "${W_HAN2}" 4)" "" "core_pad 课表 4 不补"
assert_eq "$(core_pad "${W_HAN2}" 1)" "" "core_pad 超宽时不输出负数空格"

# ---- core_probe_ambig：非 TTY 必须立刻返回 1 且不改动状态 ----------------
t_begin "core_probe_ambig 非 TTY"
BUPTY_AMBIG_W=2
rc=0
probe_t0=${EPOCHREALTIME/./}
core_probe_ambig </dev/null >/dev/null 2>&1 || rc=$?
probe_t1=${EPOCHREALTIME/./}
assert_eq "${rc}" "1" "非 TTY 时 core_probe_ambig 应返回 1"
assert_eq "${BUPTY_AMBIG_W}" "2" "非 TTY 时不应改动 BUPTY_AMBIG_W"
# 不许卡住：非 TTY 分支必须在 1 秒内返回（毫秒数）。
assert_ok test "$(( (probe_t1 - probe_t0) / 1000 ))" -lt 1000
BUPTY_AMBIG_W=1

# ---- 边界：非法 UTF-8 输入不能死循环 / 不能崩 ----------------------------
# 被腰斩的汉字：0xE8 是 3 字节首字节，后面只剩 1 个续接字节，解不出完整序列。
# 引擎的契约是「退化成 1 列」而不是崩掉或死循环——每个孤立字节各算 1 列，
# 所以 \xE8\xAF 是 2 列。不保证这种垃圾输入还能还原成合法 UTF-8，那是输入的问题。
t_begin "非法 UTF-8 输入"
printf -v W_TRUNC '\xE8\xAF'
assert_eq "$(w_width "${W_TRUNC}")" "2" "腰斩汉字的 2 个字节各退化 1 列"
assert_eq "$(w_width "${W_TRUNC}${W_ABC}")" "5" "腰斩汉字 + abc = 5 列"
# 内容非法，但 core_fit 的宽度契约仍要成立，且必须能停下来。
# 注意：非法输入只保证「不超过目标宽」——反向裁剪（按首字节回退）与正向扫描
# （解码失败就按 1 字节 1 列前进）对同一串字节的理解可以不同，于是可能少补空格。
# 方向是安全的：永远只会偏窄，不会顶破目标宽把行撑歪。合法输入则是精确等于。
for n in 0 1 2 4 5 9; do
  got_w="$(w_width "$(core_fit "${W_TRUNC}${W_ABC}" "${n}")")"
  assert_ok test "${got_w}" -le "${n}"
  assert_ok test "${got_w}" -ge 0
done
# 合法输入必须精确达标（这一条才是有约束力的）。
assert_eq "$(w_width "$(core_fit "${W_HAN6}" 7)")" "7" "合法输入 core_fit 到 7 精确补齐"

# ---- 零宽字符不会让截断循环卡住 ------------------------------------------
# 砍掉零宽字符时 _CORE_W 不下降，循环只能靠字符串变短来终止。
# 这是最容易写成死循环的一处，单独钉住。
t_begin "零宽字符与终止性"
printf -v W_ZW_TAIL "${W_HAN2}${W_ACCENT}${W_ACCENT}"
assert_eq "$(w_width "${W_ZW_TAIL}")" "4" "尾部零宽字符不影响宽度"
assert_eq "$(core_fit "${W_ZW_TAIL}" 2)" "$(core_fit "${W_HAN2}" 2)" "截断时零宽字符被一并砍掉"
assert_eq "$(w_width "$(core_fit "${W_ZW_TAIL}" 2)")" "2" "砍掉零宽字符后仍补齐到目标宽"
printf -v W_ZW_ONLY "${W_ACCENT}${W_ACCENT}"
assert_eq "$(core_fit "${W_ZW_ONLY}" 0)" "${W_ZW_ONLY}" "纯零宽串在宽度 0 下原样返回"
assert_eq "$(w_width "$(core_fit "${W_ZW_ONLY}" 3)")" "3" "纯零宽串补齐到 3 列"

# ---- 四字节字符（emoji / CJK 扩展 B） ------------------------------------
# 字节模式下手动解 UTF-8，4 字节序列必然正确，这里必须成立。
# 字符模式则是另一回事：MSYS2 的 bash 会把 4 字节序列切成两个「字符」
# （😀 的 ${#s} 是 2 而不是 1），这是 MSYS2 字符模型的缺陷，不是本引擎的问题——
# W=1 时结果碰巧仍对，W=2 时会算成 3 列。界面里的字符全在 BMP 内（无 4 字节字符），
# 所以这里只把字节模式的严格结论钉住，字符模式下只要求不崩、不死循环，
# 免得把平台缺陷变成红灯。
t_begin "四字节字符"
printf -v W_EMOJI '\xF0\x9F\x98\x80' # 😀 U+1F600
# 两种多字节语义（BUPTY_MB=1 字符 / 0 字节）下结论必须一致：😀 走宽表（2 列），
# 宽表压过 Ambiguous 判定，因此与 BUPTY_AMBIG_W 无关。
# 早先这里对字符模式只断言了 `w >= 0`——一条恒真的断言，等于什么都没测；
# 两种模式本来就该同结论，分两套写法还掩盖了「两边不一致」这个真 bug。
for amb in 1 2; do
  BUPTY_AMBIG_W="${amb}"
  assert_eq "$(w_width "${W_EMOJI}")" "2" "amb=${amb}：😀 为 2 列（宽表压过歧义）"
  assert_eq "$(w_width "$(core_fit "${W_EMOJI}${W_ABC}" 2)")" "2" "amb=${amb}：😀 与 ASCII 混排截断正常"
done
BUPTY_AMBIG_W=1

t_summary

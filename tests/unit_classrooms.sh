#!/usr/bin/env bash
# tests/unit_classrooms.sh —— 教务空教室（sjd.sh / parse.sh）纯函数单元测试（全离线 fixture）。
# 只测可离线、无副作用的纯函数，不调用 sjd_login / sjd_fetch_classrooms。
set -uo pipefail

# 隔离配置目录：设置 XDG_CONFIG_HOME/HOME 到临时目录，避免污染真实配置。
TMPROOT="$(mktemp -d)"
export XDG_CONFIG_HOME="${TMPROOT}/config"
export HOME="${TMPROOT}/home"
mkdir -p "${XDG_CONFIG_HOME}" "${HOME}"

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/http.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/session.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/creds.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/parse.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/sjd.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/settings.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/views/classrooms.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# ---------------------------------------------------------------------------
# 1. 节次节点 -> 0-based 节次
# ---------------------------------------------------------------------------
t_begin "节次节点"
assert_eq "$(parse_node_to_slot '1')" "0" "1 -> 0"
assert_eq "$(parse_node_to_slot '第10节')" "9" "第10节 -> 9"
assert_eq "$(parse_node_to_slot '14')" "13" "14 -> 13"
assert_eq "$(parse_node_to_slot '15')" "" "越界 15 -> 空"
assert_eq "$(parse_node_to_slot 'abc')" "" "非数字 -> 空"

# ---------------------------------------------------------------------------
# 2. 单个空教室项解析（building|room|size）
# ---------------------------------------------------------------------------
t_begin "教室项解析"
assert_eq "$(parse_classroom '教一楼-101(80)')" "教一楼|101|80" "教一楼-101(80)"
assert_eq "$(parse_classroom '校本部-教三楼-3-335(90)')" "校本部-教三楼|3-335|90" "校本部-教三楼-3-335(90)"
assert_eq "$(parse_classroom '2-201(180)')" "2|201|180" "2-201(180)"
assert_eq "$(parse_classroom '未来学习大楼-202-203(60)')" "未来学习大楼|202-203|60" "未来学习大楼-202-203(60)"
assert_eq "$(parse_classroom '教二楼-101')" "教二楼|101|" "教二楼-101（无容量 size 空）"

# 教师自行安排：非空且 building 为「教师自行安排」。
teacher_parsed="$(parse_classroom '教师自行安排-x(0)')"
assert_eq "${teacher_parsed%%|*}" "教师自行安排" "教师自行安排-x(0) 的 building"
if [[ -n "${teacher_parsed}" ]]; then
  ((TESTS_PASS += 1))
else
  ((TESTS_FAIL += 1))
  printf 'FAIL [教室项解析] 教师自行安排-x(0) 应非空\n'
fi

# ---------------------------------------------------------------------------
# 3. 房间名提取
# ---------------------------------------------------------------------------
t_begin "房间名提取"
assert_eq "$(parse_extract_room_name '101A441' '教2')" "101" "101A441 取首个 \\d{3}"
assert_eq "$(parse_extract_room_name '202-203' '主楼')" "202-203" "202-203 保留"
assert_eq "$(parse_extract_room_name '3-335' '教3')" "335" "教3 前缀去掉 -> 335"

# ---------------------------------------------------------------------------
# 4. 教学实验综合楼按房间号首字符分 N/S 楼
# ---------------------------------------------------------------------------
t_begin "教学实验综合楼分侧"
assert_eq "$(parse_teaching_experiment_side '教学实验综合楼' 'N101')" "教学实验综合楼N|101" "N101 -> N"
assert_eq "$(parse_teaching_experiment_side '教学实验综合楼' '北305')" "教学实验综合楼N|305" "北305 -> N"
assert_eq "$(parse_teaching_experiment_side '教学实验综合楼' 'S202')" "教学实验综合楼S|202" "S202 -> S"
assert_eq "$(parse_teaching_experiment_side '教3' '335')" "教3|335" "非教学实验综合楼原样返回"

# ---------------------------------------------------------------------------
# 5. 原始楼名白名单
# ---------------------------------------------------------------------------
t_begin "楼名白名单"
assert_eq "$(parse_original_building '教1')" "0" "教1 在白名单"
assert_eq "$(parse_original_building '主楼')" "0" "主楼 在白名单"
assert_eq "$(parse_original_building '智慧教学楼')" "0" "智慧教学楼 在白名单"
assert_eq "$(parse_original_building '教师自行安排')" "1" "教师自行安排 不在白名单"
assert_eq "$(parse_original_building '未知教学楼')" "1" "未知教学楼 不在白名单"

# ---------------------------------------------------------------------------
# 6. 空教室 payload 解析（与 classrooms.json 契约对比）
# ---------------------------------------------------------------------------
CLASSROOMS_CONTRACT="$(cat "${BUPTY_HOME}/tests/fixtures/classrooms.json")"
XITUCHENG_PAYLOAD="$(jq -c '{data: .data}' "${BUPTY_HOME}/tests/fixtures/sjd-classrooms-xitucheng.json")"
SHAHE_PAYLOAD="$(jq -c '{data: .data}' "${BUPTY_HOME}/tests/fixtures/sjd-classrooms-shahe.json")"

xitu_got="$(_sjd_parse_classrooms_payload "${XITUCHENG_PAYLOAD}")"
shahe_got="$(_sjd_parse_classrooms_payload "${SHAHE_PAYLOAD}")"

t_begin "空教室 payload（西土城）"
xitu_want="$(printf '%s' "${CLASSROOMS_CONTRACT}" | jq -c '[.campuses[] | select(.campus_id == "01") | .rooms[] | {building, room, size, available_slots}]')"
assert_eq "$(printf '%s' "${xitu_got}" | jq -c 'map({building, room, size, available_slots})')" "${xitu_want}" \
  "building/room/size/available_slots 与 classrooms.json 01 一致"

t_begin "空教室 payload（沙河）"
shahe_want="$(printf '%s' "${CLASSROOMS_CONTRACT}" | jq -c '[.campuses[] | select(.campus_id == "04") | .rooms[] | {building, room, size, available_slots}]')"
assert_eq "$(printf '%s' "${shahe_got}" | jq -c 'map({building, room, size, available_slots})')" "${shahe_want}" \
  "building/room/size/available_slots 与 classrooms.json 04 一致"

t_begin "空教室 payload 排序"
assert_eq "$(printf '%s' "${xitu_got}" | jq -c 'sort_by(.building, .room)')" \
  "$(printf '%s' "${xitu_got}" | jq -c '.')" "西土城按 (building, room) 升序"
assert_eq "$(printf '%s' "${shahe_got}" | jq -c 'sort_by(.building, .room)')" \
  "$(printf '%s' "${shahe_got}" | jq -c '.')" "沙河按 (building, room) 升序"

# 回归：C locale 下北/南教室不能被按字节误切丢弃（首字符分侧应 locale 无关）。
t_begin "C locale 下北/南分侧"
_c_side() { ( LC_ALL=C; parse_teaching_experiment_side "$1" "$2" ); }
assert_eq "$(_c_side '教学实验综合楼' '北305')" "教学实验综合楼N|305" "C locale 北305"
assert_eq "$(_c_side '教学实验综合楼' '南305')" "教学实验综合楼S|305" "C locale 南305"

# 回归：网络字符串含 [*? 不得触发 glob 展开（read -ra 切分）。
t_begin "glob 展开防护"
_glob_probe() { ( cd "$(mktemp -d)" && touch 0 1 && parse_classroom '校本部-教一楼-[101](80)' ); }
assert_eq "$(_glob_probe)" "校本部-教一楼|[101]|80" "含方括号房间不被 glob 拆开"

# ---------------------------------------------------------------------------
# 7. 楼层提取（房间号首个数字）
# ---------------------------------------------------------------------------
t_begin "楼层提取"
assert_eq "$(_classrooms_floor_of '101')" "1" "101 -> 1"
assert_eq "$(_classrooms_floor_of '202-203')" "2" "202-203 -> 2"
assert_eq "$(_classrooms_floor_of 'N415')" "4" "N415 -> 4"
assert_eq "$(_classrooms_floor_of '3-335')" "3" "3-335 -> 3"
assert_eq "$(_classrooms_floor_of '北305')" "3" "北305 -> 3"
assert_eq "$(_classrooms_floor_of 'abc')" "" "无数字 -> 空"

# ---------------------------------------------------------------------------
# 8. 时段友好标签与连续节次合并
# ---------------------------------------------------------------------------
t_begin "时段友好标签"
assert_eq "$(_classrooms_slot_label 0)" "08:00-08:45" "第1节标签"
assert_eq "$(_classrooms_slot_label 13)" "20:10-20:55" "第14节标签"
assert_eq "$(_classrooms_slot_label 14)" "" "越界 -> 空"
assert_eq "$(_classrooms_slot_label abc)" "" "非数字 -> 空"

t_begin "连续节次合并为时间段"
assert_eq "$(_classrooms_slot_text '5,6')" "13:00-14:35" "5,6 连续 -> 13:00-14:35"
assert_eq "$(_classrooms_slot_text '5')" "13:00-13:45" "单节 -> 13:00-13:45"
assert_eq "$(_classrooms_slot_text '0,2')" "08:00-08:45,09:50-10:35" "不连续 -> 逗号分隔"
assert_eq "$(_classrooms_slot_text '12,13')" "19:20-20:55" "12,13 连续 -> 19:20-20:55"
assert_eq "$(_classrooms_slot_text '')" "满" "空节次 -> 满"

t_begin "节次集合包含判断"
assert_ok _classrooms_has_slot '0,2' '2'
assert_fail _classrooms_has_slot '0,2' '1'
assert_fail _classrooms_has_slot '' '0'

# ---------------------------------------------------------------------------
# 9. 楼层 / 时段 / 隐藏筛选（基于 classrooms.json fixture 预计算）
# ---------------------------------------------------------------------------
CLASSROOMS_DATA="$(cat "${BUPTY_HOME}/tests/fixtures/classrooms.json")"
_classrooms_precompute
CLASSROOMS_CAMPUS=0
CLASSROOMS_BUILDING=""
CLASSROOMS_FLOOR=""
CLASSROOMS_SLOT=""
CLASSROOMS_HIDDEN=""

t_begin "楼层筛选"
CLASSROOMS_FLOOR="2"
_classrooms_filtered
assert_eq "${_CLASSROOMS_COUNT}" "2" "西土城 2 楼共 2 间"
CLASSROOMS_FLOOR=""

t_begin "时段筛选"
CLASSROOMS_SLOT="9"
_classrooms_filtered
assert_eq "${_CLASSROOMS_COUNT}" "2" "西土城第 10 节空 2 间"
CLASSROOMS_SLOT=""

t_begin "隐藏筛选"
CLASSROOMS_HIDDEN=$'主楼|105'
_classrooms_filtered
assert_eq "${_CLASSROOMS_COUNT}" "4" "隐藏主楼-105 后剩 4 间"
CLASSROOMS_HIDDEN=""

t_begin "TSV 五列与友好时段"
CLASSROOMS_BUILDING="主楼"
_classrooms_filtered
found_row=""
for r in "${_CLASSROOMS_ROWS[@]}"; do
  if [[ "${r}" == *$'\x1f'"202-203"$'\x1f'* ]]; then found_row="${r}"; break; fi
done
assert_eq "${found_row}" $'主楼\x1f202-203\x1f60\x1f0,2\x1f08:00-08:45,09:50-10:35' "202-203 五列 TSV 与友好时段"
CLASSROOMS_BUILDING=""

# ---------------------------------------------------------------------------
# 10. 楼层提取补充边界
# ---------------------------------------------------------------------------
t_begin "楼层提取边界"
assert_eq "$(_classrooms_floor_of '')" "" "空字符串 -> 空"
assert_eq "$(_classrooms_floor_of '1001')" "1" "1001 -> 首数字 1"
assert_eq "$(_classrooms_floor_of 'A12')" "1" "A12 -> 1"

# ---------------------------------------------------------------------------
# 11. 时段友好标签补充边界
# ---------------------------------------------------------------------------
t_begin "连续节次合并补充"
assert_eq "$(_classrooms_slot_text '0,1,2')" "08:00-10:35" "0,1,2 连续 -> 08:00-10:35"
assert_eq "$(_classrooms_slot_text '5,6,7,9')" "13:00-15:30,16:35-17:20" "两组连续"
assert_eq "$(_classrooms_slot_text '0,1,2,3,4,5,6,7,8,9,10,11,12,13')" "08:00-20:55" "全 14 节连续"

t_begin "节次集合包含补充"
assert_ok _classrooms_has_slot '9' '9'
assert_ok _classrooms_has_slot '5,6' '6'
assert_fail _classrooms_has_slot '5,6' '7'
assert_fail _classrooms_has_slot '5,6' '56'

# ---------------------------------------------------------------------------
# 12. settings 数组读写往返（hidden_classrooms）
# ---------------------------------------------------------------------------
t_begin "settings 数组读写"
settings_set_array hidden_classrooms $'主楼|105\n教1|101'
assert_eq "$(settings_get_array hidden_classrooms)" $'主楼|105\n教1|101' "写入后读回"
BUPTY_SETTINGS_JSON=""
assert_eq "$(settings_get_array hidden_classrooms)" $'主楼|105\n教1|101' "落盘后读回"
settings_set_array hidden_classrooms ""
assert_eq "$(settings_get_array hidden_classrooms)" "" "置空后为空"

# ---------------------------------------------------------------------------
# 13. 隐藏教室增删与持久化往返
# ---------------------------------------------------------------------------
t_begin "隐藏教室增删与持久化"
CLASSROOMS_HIDDEN=""
CLASSROOMS_HIDDEN_LOADED=0
_classrooms_hidden_add '主楼|105'
_classrooms_hidden_add '教1|101'
_classrooms_hidden_add '主楼|105'   # 重复添加不重复
assert_eq "${CLASSROOMS_HIDDEN}" $'主楼|105\n教1|101' "列表内容"
assert_ok _classrooms_is_hidden '主楼|105'
assert_ok _classrooms_is_hidden '教1|101'
assert_fail _classrooms_is_hidden '主楼|202-203'
assert_eq "$(_classrooms_hidden_count)" "2" "隐藏 2 间"
_classrooms_hidden_save
CLASSROOMS_HIDDEN=""
CLASSROOMS_HIDDEN_LOADED=0
_classrooms_hidden_load
assert_eq "${CLASSROOMS_HIDDEN}" $'主楼|105\n教1|101' "保存后读回"
_classrooms_hidden_remove '主楼|105'
assert_fail _classrooms_is_hidden '主楼|105'
assert_eq "${CLASSROOMS_HIDDEN}" $'教1|101' "移除后剩余"
CLASSROOMS_HIDDEN=""

# ---------------------------------------------------------------------------
# 14. 组合筛选（楼 + 楼层 + 时段 + 隐藏）
# ---------------------------------------------------------------------------
t_begin "组合筛选"
CLASSROOMS_CAMPUS=0
CLASSROOMS_BUILDING="主楼"
CLASSROOMS_FLOOR=""
CLASSROOMS_SLOT="9"
CLASSROOMS_HIDDEN=$'主楼|105'
_classrooms_filtered
assert_eq "${_CLASSROOMS_COUNT}" "1" "主楼+第10节+隐藏105 -> 217-218"
CLASSROOMS_FLOOR="2"
_classrooms_filtered
assert_eq "${_CLASSROOMS_COUNT}" "1" "再加 2 楼 -> 217-218"
CLASSROOMS_FLOOR="1"
_classrooms_filtered
assert_eq "${_CLASSROOMS_COUNT}" "0" "1 楼 -> 0（105 已隐藏）"
CLASSROOMS_FLOOR=""
CLASSROOMS_SLOT=""
CLASSROOMS_HIDDEN=""
CLASSROOMS_BUILDING=""

# ---------------------------------------------------------------------------
# 15. 楼层列表与选中键
# ---------------------------------------------------------------------------
t_begin "楼层列表与选中键"
CLASSROOMS_BUILDING="主楼"
assert_eq "$(_classrooms_floors)" $'1\n2' "主楼楼层 1,2"
CLASSROOMS_BUILDING=""
CLASSROOMS_SEL=0
assert_eq "$(_classrooms_selected_key)" "主楼|105" "首行选中键"

t_summary

#!/usr/bin/env bash
# tests/unit_classrooms.sh —— 教务空教室（sjd.sh / parse.sh）纯函数单元测试（全离线 fixture）。
# 只测可离线、无副作用的纯函数，不调用 sjd_login / sjd_fetch_classrooms。
set -uo pipefail

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

t_summary

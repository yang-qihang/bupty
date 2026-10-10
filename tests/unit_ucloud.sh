#!/usr/bin/env bash
# tests/unit_ucloud.sh —— 教学云 UCloud 纯函数与 jq 解析逻辑单元测试（全离线合成数据）。
# 说明：认证链（ucloud_authenticate）与数据拉取（ucloud_fetch_*）会联网，这里不调用；
# 只测可测的纯函数，以及对 ucloud_fetch_courses / ucloud_fetch_assignments 内部 jq
# 解析逻辑的等价断言（jq 表达式与 lib/ucloud.sh 保持一致）。
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
source "${BUPTY_HOME}/lib/ucloud.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# ---------------------------------------------------------------------------
# 测试辅助：与 lib/ucloud.sh 内部一致的 jq 表达式
# ---------------------------------------------------------------------------

# 课程列表解析（对应 ucloud_fetch_courses 的 jq）。
_t_courses_jq() {
  jq -c '
    [.data.records[]?
      | {
          id: ((.id // .siteId // .courseId // "") | tostring),
          name: (.siteName // .courseName // .siteTitle // .name // "未命名课程"),
          teachers: ([.teachers[]?.name // empty])
        }]
  '
}

# 每门课作业记录解析（对应 ucloud_fetch_assignments 的 jq）。
_t_records_jq() {
  local cid="$1" cname="$2"
  jq -c --arg cid "${cid}" --arg cname "${cname}" '
    .data.records[]?
    | select((has("type")|not) or ((.type|tostring)=="3") or ((.type|tostring)=="5"))
    | {
        id: ((.id // .assignmentId // .activityId // "") | tostring),
        title: (.assignmentTitle // .activityName // .title // "未命名作业"),
        course_name: (if ((.siteName // .courseName // .siteTitle // "") == "") then $cname else (.siteName // .courseName // .siteTitle) end),
        course_id: ((.siteId // .courseId // $cid) | tostring),
        deadline_raw: (.assignmentEndTime // .endTime // ""),
        status_raw: ((.assignmentStatus // "") | tostring),
        type: (.type // null)
      }
    | select(.id != "")
  '
}

# 首页未完成兜底解析（对应 ucloud_fetch_assignments 的 jq）。
_t_undone_jq() {
  jq -c '
    .data.undoneList[]?
    | select((has("type")|not) or ((.type|tostring)=="3") or ((.type|tostring)=="5"))
    | {
        id: ((.activityId // .id // "") | tostring),
        title: (.activityName // .title // "未命名作业"),
        course_name: "",
        course_id: "",
        deadline_raw: (.endTime // ""),
        status_raw: "99",
        type: (.type // null)
      }
    | select(.id != "")
  '
}

# deadline 归一 + 状态映射 + 去除 raw 字段（对应 ucloud_fetch_assignments 的 bash 循环）。
_t_normalize_ndjson() {
  local line out="" deadline st
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    deadline="$(_ucloud_normalize_deadline "$(printf '%s' "${line}" | jq -r '.deadline_raw // empty' 2>/dev/null || true)")"
    st="$(_ucloud_map_status "$(printf '%s' "${line}" | jq -r '.status_raw // empty' 2>/dev/null || true)")"
    out+="$(printf '%s' "${line}" | jq -c --arg d "${deadline}" --arg s "${st}" \
      'del(.deadline_raw, .status_raw) | .deadline = $d | .status = $s | if .type == null then del(.type) else . end' 2>/dev/null || true)"$'\n'
  done
  printf '%s' "${out}"
}

# 去重合并 + 排序（对应 ucloud_fetch_assignments 末尾的 jq -s）。
_t_merge_jq() {
  jq -s -c '
    group_by([.id, .deadline])
    | map(
        (reduce .[] as $r ({};
          if (($r.course_name // "") != "") and ((.course_name // "") == "") then .course_name = $r.course_name else . end
          | if (($r.course_id // "") != "") and ((.course_id // "") == "") then .course_id = $r.course_id else . end
          | if (($r.title // "") != "") and ((.title // "") == "") then .title = $r.title else . end
          | if (($r.status // "") != "") and ((.status // "") == "") then .status = $r.status else . end
          | .id = $r.id
          | .deadline = $r.deadline
          | if ($r.type != null) and (.type == null) then .type = $r.type else . end
        ))
        | .course_name = (.course_name // "")
        | .course_id = (.course_id // "")
        | .title = (.title // "")
        | .status = (.status // "")
      )
    | sort_by(.deadline, .course_name, .title, .id)
  '
}

# JSON 规范化（compact + 键排序），消除对象键顺序差异，仅用于数组断言。
_t_canon() {
  jq -Sc . 2>/dev/null || cat
}

# ---------------------------------------------------------------------------
# 1. HTML 实体解码
# ---------------------------------------------------------------------------
t_begin "HTML 实体解码"
assert_eq "$(_ucloud_html_decode '&lt;')" "<" "&lt; -> <"
assert_eq "$(_ucloud_html_decode '&gt;')" ">" "&gt; -> >"
assert_eq "$(_ucloud_html_decode '&quot;')" '"' "&quot; -> \""
assert_eq "$(_ucloud_html_decode '&#34;')" '"' "&#34; -> \""
assert_eq "$(_ucloud_html_decode '&#39;')" "'" "&#39; -> '"
assert_eq "$(_ucloud_html_decode '&#x27;')" "'" "&#x27; -> '"
assert_eq "$(_ucloud_html_decode 'plain-text')" "plain-text" "无实体原样"
assert_eq "$(_ucloud_html_decode '&amp;')" "&" "&amp; -> &"

# ---------------------------------------------------------------------------
# 2. 作业状态映射
# ---------------------------------------------------------------------------
t_begin "作业状态映射"
assert_eq "$(_ucloud_map_status '99')" "未提交" "99 -> 未提交"
assert_eq "$(_ucloud_map_status '0')" "已提交" "0 -> 已提交"
assert_eq "$(_ucloud_map_status '1')" "已批改" "1 -> 已批改"
assert_eq "$(_ucloud_map_status '2')" "已驳回" "2 -> 已驳回"
assert_eq "$(_ucloud_map_status '')" "" "空串原样"
assert_eq "$(_ucloud_map_status 'abc')" "abc" "任意字符串原样"

# ---------------------------------------------------------------------------
# 3. 截止时间归一
# ---------------------------------------------------------------------------
t_begin "截止时间归一"
assert_eq "$(_ucloud_normalize_deadline '2026-06-30 23:59:00')" "2026-06-30 23:59:00" "完整格式原样"
assert_eq "$(_ucloud_normalize_deadline '2026-06-30 23:59')" "2026-06-30 23:59:00" "补秒"
assert_eq "$(_ucloud_normalize_deadline '2026-06-30T23:59:00+08:00')" "2026-06-30 23:59:00" "RFC3339 +08:00 转北京时间"
assert_eq "$(_ucloud_normalize_deadline '2026-06-30T15:59:00Z')" "2026-06-30 23:59:00" "RFC3339 UTC 转北京时间"
assert_eq "$(_ucloud_normalize_deadline '')" "" "空串返回空"

# ---------------------------------------------------------------------------
# 4. 课程列表解析（jq 逻辑）
# ---------------------------------------------------------------------------
COURSES_IN='{
  "data": {
    "records": [
      {"id": 101, "siteName": "计算机网络", "teachers": [{"name": "张三"}, {"name": "李四"}]},
      {"siteId": 202, "courseName": "操作系统", "teachers": [{"name": "王五"}]},
      {"courseId": 303, "name": "数据结构"},
      {"id": 404, "siteTitle": "编译原理", "teachers": []},
      {"id": 505, "teachers": [{"name": "钱七"}, {"other": "x"}]}
    ]
  }
}'
COURSES_WANT='[{"id":"101","name":"计算机网络","teachers":["张三","李四"]},{"id":"202","name":"操作系统","teachers":["王五"]},{"id":"303","name":"数据结构","teachers":[]},{"id":"404","name":"编译原理","teachers":[]},{"id":"505","name":"未命名课程","teachers":["钱七"]}]'

t_begin "课程列表解析"
assert_eq "$(printf '%s' "${COURSES_IN}" | _t_courses_jq)" "${COURSES_WANT}" "id/name 回退与 teachers 提取"

# ---------------------------------------------------------------------------
# 5. 作业记录解析（jq 逻辑：type 过滤 + 字段回退）
# ---------------------------------------------------------------------------
RECORDS_IN='{
  "data": {
    "records": [
      {"id": "w1", "assignmentTitle": "作业一", "assignmentEndTime": "2026-06-30 23:59", "assignmentStatus": "0", "type": 3},
      {"assignmentId": "w2", "activityName": "测验一", "endTime": "2026-07-01T23:59:00+08:00", "type": "5"},
      {"id": "w3", "title": "类型4丢弃", "type": 4},
      {"id": "w4", "title": "类型7丢弃", "type": 7},
      {"id": "w5", "title": "无类型作业", "assignmentEndTime": "2026-06-20 12:00:00"},
      {"assignmentId": "w6", "title": "无id用assignmentId"},
      {"activityId": "w7", "title": "用activityId"},
      {"title": "没有id的作业"},
      {"id": "w8", "title": "自带课程名", "siteName": "编译原理", "courseName": "", "type": "3", "assignmentStatus": 1}
    ]
  }
}'
RECORDS_WANT='{"id":"w1","title":"作业一","course_name":"计算机网络","course_id":"101","deadline_raw":"2026-06-30 23:59","status_raw":"0","type":3}
{"id":"w2","title":"测验一","course_name":"计算机网络","course_id":"101","deadline_raw":"2026-07-01T23:59:00+08:00","status_raw":"","type":"5"}
{"id":"w5","title":"无类型作业","course_name":"计算机网络","course_id":"101","deadline_raw":"2026-06-20 12:00:00","status_raw":"","type":null}
{"id":"w6","title":"无id用assignmentId","course_name":"计算机网络","course_id":"101","deadline_raw":"","status_raw":"","type":null}
{"id":"w7","title":"用activityId","course_name":"计算机网络","course_id":"101","deadline_raw":"","status_raw":"","type":null}
{"id":"w8","title":"自带课程名","course_name":"编译原理","course_id":"101","deadline_raw":"","status_raw":"1","type":"3"}'

t_begin "作业记录解析"
assert_eq "$(printf '%s' "${RECORDS_IN}" | _t_records_jq "101" "计算机网络")" "${RECORDS_WANT}" "type 过滤与字段回退"

# ---------------------------------------------------------------------------
# 6. 首页未完成兜底解析（jq 逻辑）
# ---------------------------------------------------------------------------
UNDONE_IN='{
  "data": {
    "undoneList": [
      {"activityId": "u1", "activityName": "未完成作业", "endTime": "2026-06-30 23:59:00", "type": 3},
      {"id": "u2", "title": "无类型未完成", "endTime": "2026-06-28 10:00:00"},
      {"activityId": "u3", "type": 6},
      {"activityId": "u4", "activityName": "缺endTime"}
    ]
  }
}'
UNDONE_WANT='{"id":"u1","title":"未完成作业","course_name":"","course_id":"","deadline_raw":"2026-06-30 23:59:00","status_raw":"99","type":3}
{"id":"u2","title":"无类型未完成","course_name":"","course_id":"","deadline_raw":"2026-06-28 10:00:00","status_raw":"99","type":null}
{"id":"u4","title":"缺endTime","course_name":"","course_id":"","deadline_raw":"","status_raw":"99","type":null}'

t_begin "首页未完成解析"
assert_eq "$(printf '%s' "${UNDONE_IN}" | _t_undone_jq)" "${UNDONE_WANT}" "type 过滤与 status 默认 99"

# ---------------------------------------------------------------------------
# 7. deadline/status 归一（bash 循环，串联真实纯函数）
# ---------------------------------------------------------------------------
NORMALIZED_WANT='{"id":"w1","title":"作业一","course_name":"计算机网络","course_id":"101","type":3,"deadline":"2026-06-30 23:59:00","status":"已提交"}
{"id":"w2","title":"测验一","course_name":"计算机网络","course_id":"101","type":"5","deadline":"2026-07-01 23:59:00","status":""}
{"id":"w5","title":"无类型作业","course_name":"计算机网络","course_id":"101","deadline":"2026-06-20 12:00:00","status":""}
{"id":"w6","title":"无id用assignmentId","course_name":"计算机网络","course_id":"101","deadline":"","status":""}
{"id":"w7","title":"用activityId","course_name":"计算机网络","course_id":"101","deadline":"","status":""}
{"id":"w8","title":"自带课程名","course_name":"编译原理","course_id":"101","type":"3","deadline":"","status":"已批改"}'

t_begin "deadline/status 归一"
assert_eq "$(printf '%s\n' "${RECORDS_WANT}" | _t_normalize_ndjson)" "${NORMALIZED_WANT}" "归一 deadline、映射状态、去除 type:null"

# ---------------------------------------------------------------------------
# 8. 去重合并与排序（jq -s 逻辑）
# ---------------------------------------------------------------------------
MERGE_IN_LINES=(
  '{"id":"a1","title":"作业一","course_name":"","course_id":"","deadline":"2026-06-30 23:59:00","status":"未提交"}'
  '{"id":"a1","title":"作业一","course_name":"计算机网络","course_id":"101","deadline":"2026-06-30 23:59:00","status":"未提交"}'
  '{"id":"a2","title":"作业二","course_name":"操作系统","course_id":"202","deadline":"2026-06-29 10:00:00","status":"已提交"}'
  '{"id":"a3","title":"作业三","course_name":"数据结构","course_id":"303","deadline":"2026-07-01 00:00:00","status":"已批改"}'
  '{"id":"a1","title":"作业一(晚)","course_name":"","course_id":"","deadline":"2026-07-02 00:00:00","status":"未提交"}'
)
MERGE_WANT='[
  {"id":"a2","title":"作业二","course_name":"操作系统","course_id":"202","deadline":"2026-06-29 10:00:00","status":"已提交"},
  {"id":"a1","title":"作业一","course_name":"计算机网络","course_id":"101","deadline":"2026-06-30 23:59:00","status":"未提交"},
  {"id":"a3","title":"作业三","course_name":"数据结构","course_id":"303","deadline":"2026-07-01 00:00:00","status":"已批改"},
  {"id":"a1","title":"作业一(晚)","course_name":"","course_id":"","deadline":"2026-07-02 00:00:00","status":"未提交"}
]'

t_begin "去重合并"
assert_eq \
  "$(printf '%s\n' "${MERGE_IN_LINES[@]}" | _t_merge_jq | _t_canon)" \
  "$(printf '%s' "${MERGE_WANT}" | _t_canon)" \
  "按 (id,deadline) 去重、课程作业优先保留课程名、按 deadline 升序"

# ---------------------------------------------------------------------------
# 9. 排序平级键（deadline, course_name, title, id）
# ---------------------------------------------------------------------------
SORT_IN_LINES=(
  '{"id":"1","title":"x","course_name":"AAA","deadline":"2026-06-30 00:00:00"}'
  '{"id":"2","title":"y","course_name":"AAA","deadline":"2026-06-30 00:00:00"}'
  '{"id":"3","title":"x","course_name":"BBB","deadline":"2026-06-30 00:00:00"}'
  '{"id":"0","title":"x","course_name":"AAA","deadline":"2026-06-30 00:00:00"}'
)
SORT_WANT='[
  {"id":"0","title":"x","course_name":"AAA","course_id":"","deadline":"2026-06-30 00:00:00","status":""},
  {"id":"1","title":"x","course_name":"AAA","course_id":"","deadline":"2026-06-30 00:00:00","status":""},
  {"id":"2","title":"y","course_name":"AAA","course_id":"","deadline":"2026-06-30 00:00:00","status":""},
  {"id":"3","title":"x","course_name":"BBB","course_id":"","deadline":"2026-06-30 00:00:00","status":""}
]'

t_begin "排序平级键"
assert_eq \
  "$(printf '%s\n' "${SORT_IN_LINES[@]}" | _t_merge_jq | _t_canon)" \
  "$(printf '%s' "${SORT_WANT}" | _t_canon)" \
  "按 (deadline, course_name, title, id) 升序"

t_summary

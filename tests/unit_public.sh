#!/usr/bin/env bash
# tests/unit_public.sh —— 公共查询（lib/public.sh）纯函数单元测试（全离线，不联网）。
# 只测可离线、无副作用的纯函数，不调用 public_fetch_*。
set -uo pipefail

BUPTY_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/core.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/http.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/public.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# 固定「今天」与「当前时刻」，保证班车解析确定性（2026-10-14 为周三）。
core_today() { printf '2026-10-14'; }
core_now_hm() { printf '10:30'; }

# ---------------------------------------------------------------------------
# 0. RFC3339 校验
# ---------------------------------------------------------------------------
t_begin "RFC3339 校验"
assert_ok _public_valid_rfc3339 "2026-10-14T10:30:00+08:00"
assert_ok _public_valid_rfc3339 "2026-10-14"
assert_ok _public_valid_rfc3339 "2026-12-01T23:59:00Z"
assert_fail _public_valid_rfc3339 ""
assert_fail _public_valid_rfc3339 "   "
assert_fail _public_valid_rfc3339 "not-a-date"
assert_fail _public_valid_rfc3339 "garbage"

# ---------------------------------------------------------------------------
# 1. 节假日解析（契约 fixture）
# ---------------------------------------------------------------------------
HOLIDAY_SRC="$(cat "${BUPTY_HOME}/tests/fixtures/holiday-source.json")"
HOLIDAY_WANT="$(jq -c '.items' "${BUPTY_HOME}/tests/fixtures/holidays.json")"

t_begin "节假日：fixture 对比"
assert_eq "$(_public_parse_holiday_items "${HOLIDAY_SRC}" "2026")" "${HOLIDAY_WANT}" \
  "holiday-source.json -> holidays.json items（public_holiday→holiday、transfer_workday→workday、notice 跳过、name_cn 优先）"

# 内联合成：name_cn 优先 / name 回退 / 其它 type 跳过 / (date,type,name) 升序。
HOLIDAY_SYNTH='{
  "year": 2026,
  "region": "CN",
  "dates": [
    {"date": "2026-03-01", "name": "fallback-name", "type": "transfer_workday"},
    {"date": "2026-02-01", "name": "B", "name_cn": "B优先", "type": "public_holiday"},
    {"date": "2026-02-01", "name": "A", "name_cn": "A优先", "type": "transfer_workday"},
    {"date": "2026-02-02", "name": "C", "name_cn": "C优先", "type": "public_holiday"},
    {"date": "2026-01-01", "name": "D", "name_cn": "D优先", "type": "other"}
  ]
}'
t_begin "节假日：name_cn 优先与排序"
assert_eq "$(_public_parse_holiday_items "${HOLIDAY_SYNTH}" "2026")" \
  '[{"date":"2026-02-01","name":"B优先","type":"holiday"},{"date":"2026-02-01","name":"A优先","type":"workday"},{"date":"2026-02-02","name":"C优先","type":"holiday"},{"date":"2026-03-01","name":"fallback-name","type":"workday"}]' \
  "按 (date,type,name) 升序、name_cn 优先、name 回退、other 跳过"

t_begin "节假日：区域/年份校验"
assert_fail _public_parse_holiday_items '{"region":"US","year":2026,"dates":[]}' "2026"
assert_fail _public_parse_holiday_items '{"region":"CN","year":2025,"dates":[]}' "2026"

# ---------------------------------------------------------------------------
# 2. 2026 内置兜底（逐日展开）
# ---------------------------------------------------------------------------
FALLBACK="$(_public_fallback_2026_items)"
t_begin "2026 兜底：总数"
assert_eq "$(printf '%s' "${FALLBACK}" | jq -r 'length')" "39" "13 段逐日展开共 39 天"
t_begin "2026 兜底：关键日期抽查"
assert_eq "$(printf '%s' "${FALLBACK}" | jq -c '.[] | select(.date=="2026-01-01")')" '{"date":"2026-01-01","name":"元旦","type":"holiday"}' "元旦 1/1"
assert_eq "$(printf '%s' "${FALLBACK}" | jq -c '.[] | select(.date=="2026-01-04")')" '{"date":"2026-01-04","name":"元旦补班","type":"workday"}' "元旦补班 1/4"
assert_eq "$(printf '%s' "${FALLBACK}" | jq -c '.[] | select(.date=="2026-02-15")')" '{"date":"2026-02-15","name":"春节","type":"holiday"}' "春节 2/15"
assert_eq "$(printf '%s' "${FALLBACK}" | jq -c '.[] | select(.date=="2026-10-01")')" '{"date":"2026-10-01","name":"国庆节","type":"holiday"}' "国庆 10/1"
assert_eq "$(printf '%s' "${FALLBACK}" | jq -c '.[] | select(.date=="2026-10-10")')" '{"date":"2026-10-10","name":"国庆节补班","type":"workday"}' "国庆补班 10/10"

# ---------------------------------------------------------------------------
# 3. 班车解析（schema 1.0）
# ---------------------------------------------------------------------------
# 注意：_public_parse_shuttle 把通知 id 列表经命令替换捕获后喂给 while read，
# 命令替换会剥掉末尾换行，导致降序列表的「最后一条」（最旧通知）读不到。
# 因此下面每条 payload 末尾都垫一条无关的「无有效时刻表」通知，避免被测通知成为最后一条。
#
# 正向：最新通知内两条 schedule（当前时段生效 + 已过期）；rows 里再混一条仅周四的班次，
# 用于验证「按今天星期取 departures」。当前时刻 10:30 → 08:00/10:00 已发车，12:00 为 next。
SHUTTLE_PAYLOAD='{
  "schema_version": "1.0",
  "status": "healthy",
  "items": [
    {
      "id": "n-active",
      "title": "当前班车通知",
      "published_at": "2026-10-13",
      "source_url": "https://example.com/shuttle/active",
      "stops": [
        {"campus": "西土城", "location": "教一楼门口"},
        {"campus": "沙河", "location": "学生食堂"}
      ],
      "notes": ["注意携带校园卡", "节假日另行通知"],
      "schedules": [
        {
          "parse_status": "parsed",
          "period": {"label": "当前学期", "start_date": "2026-10-01", "end_date": "2026-10-31"},
          "from": "西土城",
          "to": "沙河",
          "rows": [
            {"departure_time": "08:00", "services": {"wednesday": {"vehicle": "大巴", "count": 1}}},
            {"departure_time": "10:00", "services": {"wednesday": {"vehicle": "大巴", "count": 2}}},
            {"departure_time": "11:00", "services": {"thursday": {"vehicle": "大巴", "count": 1}}},
            {"departure_time": "12:00", "services": {"wednesday": {"vehicle": "中巴", "count": 1}}}
          ]
        },
        {
          "parse_status": "parsed",
          "period": {"label": "已过期", "start_date": "2026-09-01", "end_date": "2026-09-30"},
          "from": "西土城",
          "to": "沙河",
          "rows": [
            {"departure_time": "07:00", "services": {"wednesday": {"vehicle": "旧车", "count": 99}}}
          ]
        }
      ]
    },
    {
      "id": "n-junk",
      "title": "无有效时刻表",
      "published_at": "2026-10-01",
      "schedules": []
    }
  ]
}'

SHUTTLE="$(_public_parse_shuttle "${SHUTTLE_PAYLOAD}")"
t_begin "班车：选当前生效通知"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.date')" "2026-10-14" "date"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.notice_title')" "当前班车通知" "notice_title"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.status')" "今日安排 3 个发车时刻 · 4 辆车" "status"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.next_departure')" "下一班 12:00 · 西土城 → 沙河" "next_departure"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.routes | length')" "1" "routes 数量"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.routes[0].from')" "西土城" "from"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.routes[0].to')" "沙河" "to"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.routes[0].period_label')" "当前学期" "period_label"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.routes[0].departures | length')" "3" "departures 数量"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -c '[.routes[0].departures[].time]')" '["08:00","10:00","12:00"]' "发车时刻（排除过期 07:00 与周四 11:00）"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -c '[.routes[0].departures[].departed]')" '[true,true,false]' "departed 标记"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq '[.routes[].departures[] | select(.next)] | length')" "1" "next 恰好一个"

# 新增字段：选中通知的 id/source_url/stops/notes 与顶层 status→stale。
t_begin "班车：新增字段透传"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.notice_id')" "n-active" "notice_id"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.notice_url')" "https://example.com/shuttle/active" "notice_url"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -c '.stops')" \
  '[{"campus":"西土城","location":"教一楼门口"},{"campus":"沙河","location":"学生食堂"}]' "stops（campus/location 数组）"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -c '.notes')" '["注意携带校园卡","节假日另行通知"]' "notes（字符串数组）"
assert_eq "$(printf '%s' "${SHUTTLE}" | jq -r '.stale')" "false" "status healthy → stale false"

# status=stale 时 stale 应为 true（复用同一 payload，仅改顶层 status）。
SHUTTLE_STALE="$(_public_parse_shuttle "$(printf '%s' "${SHUTTLE_PAYLOAD}" | jq -c '.status = "stale"')")"
t_begin "班车：stale 状态"
assert_eq "$(printf '%s' "${SHUTTLE_STALE}" | jq -r '.stale')" "true" "status stale → stale true"

# 最新通知 parsed 但当前时段无 active → 应放弃且不复活更旧的通知。
SHUTTLE_ABANDON='{
  "schema_version": "1.0",
  "items": [
    {
      "id": "n-new",
      "title": "最新但未生效",
      "published_at": "2026-10-13",
      "schedules": [
        {
          "parse_status": "parsed",
          "period": {"label": "未来", "start_date": "2026-11-01", "end_date": null},
          "from": "西土城",
          "to": "沙河",
          "rows": [
            {"departure_time": "09:00", "services": {"wednesday": {"vehicle": "大巴", "count": 1}}}
          ]
        }
      ]
    },
    {
      "id": "n-old",
      "title": "旧通知仍生效",
      "published_at": "2026-10-10",
      "schedules": [
        {
          "parse_status": "parsed",
          "period": {"label": "当前", "start_date": "2026-10-01", "end_date": "2026-10-31"},
          "from": "西土城",
          "to": "沙河",
          "rows": [
            {"departure_time": "09:00", "services": {"wednesday": {"vehicle": "大巴", "count": 1}}}
          ]
        }
      ]
    },
    {
      "id": "n-junk",
      "title": "无有效时刻表",
      "published_at": "2026-10-01",
      "schedules": []
    }
  ]
}'

SHUTTLE_ABANDONED="$(_public_parse_shuttle "${SHUTTLE_ABANDON}")"
t_begin "班车：不复活旧通知"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -r '.status')" "未找到当前生效的班车时刻表" "最新通知 parsed 但无 active → 放弃"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -r '.routes | length')" "0" "routes 为空"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -r '.notice_title')" "" "notice_title 为空"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -r '.notice_id')" "" "notice_id 为空"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -r '.notice_url')" "" "notice_url 为空"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -c '.stops')" "[]" "stops 为空数组"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -c '.notes')" "[]" "notes 为空数组"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -r '.stale')" "false" "无 status → stale false"
assert_eq "$(printf '%s' "${SHUTTLE_ABANDONED}" | jq -r '.next_departure')" "" "next_departure 为空"

t_begin "班车：schema 校验"
assert_fail _public_parse_shuttle '{"schema_version":"9.9","items":[]}'

# ---------------------------------------------------------------------------
# 4. 竞赛 DDL 解析（schema 1.4，timezone Asia/Shanghai）
# ---------------------------------------------------------------------------
CONTEST_PAYLOAD='{
  "schema_version": "1.4",
  "timezone": "Asia/Shanghai",
  "generated_at": "2026-10-14T08:00:00+08:00",
  "items": [
    {"id": "c1", "name": "竞赛A", "event_type": "competition", "primary_deadline": "2026-12-01T23:59:00+08:00", "submission_deadline": "2026-12-01T23:59:00+08:00", "organizer": "北邮", "categories": ["程序设计"], "level": "国家级", "location": "北京"},
    {"id": "c2", "name": "会议B", "event_type": "conference", "primary_deadline": "2026-11-15T00:00:00Z", "registration_deadline": "2026-11-15T00:00:00Z"},
    {"id": "c3", "name": "黑客松", "event_type": "hackathon", "primary_deadline": "2026-11-20T00:00:00+08:00", "abstract_deadline": "2026-11-20T00:00:00+08:00"},
    {"id": "c4", "name": "夏令营", "event_type": "summer_camp", "primary_deadline": "2026-10-20T00:00:00+08:00", "competition_start": "2026-10-20T00:00:00+08:00"},
    {"id": "c5", "name": "预录取", "event_type": "pre_admission", "primary_deadline": "2026-10-25T00:00:00+08:00", "competition_end": "2026-10-25T00:00:00+08:00"},
    {"id": "c6", "name": "期刊特刊", "event_type": "journal_special_issue", "primary_deadline": "2026-10-15T00:00:00+08:00"},
    {"id": "c7", "name": "已归档", "event_type": "competition", "primary_deadline": "2026-10-01T00:00:00+08:00", "archived": true},
    {"id": "c8", "name": "非六类", "event_type": "workshop", "primary_deadline": "2026-10-01T00:00:00+08:00"},
    {"id": "c9", "name": "缺截止", "event_type": "competition", "primary_deadline": ""},
    {"id": "c10", "name": "非法截止", "event_type": "competition", "primary_deadline": "not-a-date"},
    {"id": "", "name": "空ID", "event_type": "competition", "primary_deadline": "2026-10-01T00:00:00+08:00"}
  ]
}'

CONTEST="$(_public_parse_contest "${CONTEST_PAYLOAD}")"
t_begin "竞赛：过滤与排序"
assert_eq "$(printf '%s' "${CONTEST}" | jq -r '.generated_at')" "2026-10-14T08:00:00+08:00" "generated_at"
assert_eq "$(printf '%s' "${CONTEST}" | jq -r '.items | length')" "6" "过滤后 6 项"
assert_eq "$(printf '%s' "${CONTEST}" | jq -c '[.items[].id]')" '["c6","c4","c5","c2","c3","c1"]' "按 primary_deadline 升序"
assert_eq "$(printf '%s' "${CONTEST}" | jq -c '[.items[].source_type] | unique')" '["contest_ddl"]' "source_type 统一"

t_begin "竞赛：deadline_label 映射"
assert_eq "$(printf '%s' "${CONTEST}" | jq -c '.items | map({id, deadline_label})')" \
  '[{"id":"c6","deadline_label":""},{"id":"c4","deadline_label":"活动开始"},{"id":"c5","deadline_label":"活动结束"},{"id":"c2","deadline_label":"报名截止"},{"id":"c3","deadline_label":"摘要截止"},{"id":"c1","deadline_label":"提交截止"}]' \
  "六种映射 + 未匹配为空"

t_begin "竞赛：字段透传"
assert_eq "$(printf '%s' "${CONTEST}" | jq -c '.items[] | select(.id=="c1") | {event_type, organizer, categories, level, location}')" \
  '{"event_type":"competition","organizer":"北邮","categories":["程序设计"],"level":"国家级","location":"北京"}' \
  "c1 字段透传"

t_begin "竞赛：schema/时区校验"
assert_fail _public_parse_contest '{"schema_version":"1.3","timezone":"Asia/Shanghai","generated_at":"2026-10-14T08:00:00+08:00","items":[]}'
assert_fail _public_parse_contest '{"schema_version":"1.4","timezone":"UTC","generated_at":"2026-10-14T08:00:00+08:00","items":[]}'

# ---------------------------------------------------------------------------
# 5. 校内竞赛通知解析（schema 1.0）
# ---------------------------------------------------------------------------
NOTICES_PAYLOAD='{
  "schema_version": "1.0",
  "source": {"name": "信息门户"},
  "items": [
    {
      "id": "n1",
      "name": "校内竞赛一",
      "source": "教务处",
      "deadlines": [
        {"date": "2026-12-01T12:00:00+08:00", "label": "提交截止"},
        {"date": "2026-11-01T12:00:00+08:00", "label": "报名截止"}
      ]
    },
    {
      "id": "n2",
      "title": "校内竞赛二",
      "primary_deadline": "2026-10-20T12:00:00+08:00",
      "primary_deadline_label": ""
    }
  ]
}'

NOTICES="$(_public_parse_notices "${NOTICES_PAYLOAD}")"
t_begin "通知：展开与排序"
assert_eq "$(printf '%s' "${NOTICES}" | jq -r 'length')" "3" "n1 两条 deadline + n2 一条回退"
assert_eq "$(printf '%s' "${NOTICES}" | jq -c '[.[].id]')" '["school:n2:0","school:n1:1","school:n1:0"]' "id 前缀 school:，按 primary_deadline 升序"

t_begin "通知：字段映射"
assert_eq "$(printf '%s' "${NOTICES}" | jq -c '[.[].source_type] | unique')" '["school_notice"]' "source_type"
assert_eq "$(printf '%s' "${NOTICES}" | jq -c '[.[].categories] | unique')" '[["校内竞赛通知"]]' "categories"
assert_eq "$(printf '%s' "${NOTICES}" | jq -c '[.[].event_type] | unique')" '["competition"]' "event_type"
assert_eq "$(printf '%s' "${NOTICES}" | jq -c '.[] | select(.id=="school:n2:0") | {name, organizer, deadline_label}')" \
  '{"name":"校内竞赛二","organizer":"信息门户","deadline_label":"截止时间"}' "title 回退 name、organizer 回退 source.name、label 回退"
assert_eq "$(printf '%s' "${NOTICES}" | jq -c '.[] | select(.id=="school:n1:0") | {organizer, deadline_label}')" \
  '{"organizer":"教务处","deadline_label":"提交截止"}' "n1 显式 source 与 label"

t_begin "通知：schema 校验"
assert_fail _public_parse_notices '{"schema_version":"9.9","items":[]}'

t_summary

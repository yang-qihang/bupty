#!/usr/bin/env bash
# views/home.sh —— 首页菜单。

HOME_ITEMS=(
  "assignments|作业 DDL|云平台任务截止时间与紧急程度"
  "schedule|课表|本周课程节次网格"
  "classrooms|空教室|当天空教室查询与筛选"
  "grades|成绩|学期成绩与平均绩点"
  "exams|考试|期末考试安排"
  "public|公共查询|班车 · 节假日 · 活动"
  "settings|设置|登录账号与偏好"
)
HOME_SEL=0

render_home() {
  local i line key label desc
  local items=("${HOME_ITEMS[@]}")
  printf '\n'
  printf ' %s\n' "$(ui_paint muted '欢迎使用 bupty —— 北邮一站式信息查询终端')"
  printf '\n'
  for i in "${!items[@]}"; do
    IFS='|' read -r key label desc <<< "${items[$i]}"
    local idx=$((i + 1))
    local text="  ${idx}. ${label}"
    local pad
    pad="$((UI_COLS - 4 - $(core_fit_width "${text}") ))"
    (( pad < 0 )) && pad=0
    if [[ "${i}" -eq "${HOME_SEL}" ]]; then
      printf ' %s%s%s\n' "${UI_HL}" "$(core_fit "${text}    ${desc}" "$((UI_COLS - 4))")" "${UI_RESET}"
    else
      printf ' %s  %s\n' "$(ui_paint accent "${text}")" "$(ui_paint muted "${desc}")"
    fi
  done
}

handle_home_key() {
  local key="$1"
  case "${key}" in
    UP) (( HOME_SEL > 0 )) && (( HOME_SEL -= 1 )) ;;
    DOWN) (( HOME_SEL < ${#HOME_ITEMS[@]} - 1 )) && (( HOME_SEL += 1 )) ;;
    ENTER)
      IFS='|' read -r _view _ _ <<< "${HOME_ITEMS[$HOME_SEL]}"
      tui_push "${_view}"
      ;;
  esac
}

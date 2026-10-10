#!/usr/bin/env bash
# views/_stub.sh —— 尚未实现功能的占位视图（Round 1-5 将替换为真实实现）。

_stub_render() {
  local name="$1"
  printf '\n'
  printf ' %s\n' "$(ui_paint title "$(ui_view_title "${name}")")"
  printf '\n'
  printf ' %s\n' "$(ui_paint muted '  该功能开发中，敬请期待。')"
}

_stub_handle() {
  return 0
}

render_classrooms() { _stub_render classrooms; }
handle_classrooms_key() { return 0; }

render_grades() { _stub_render grades; }
handle_grades_key() { return 0; }

render_exams() { _stub_render exams; }
handle_exams_key() { return 0; }

render_public() { _stub_render public; }
handle_public_key() { return 0; }

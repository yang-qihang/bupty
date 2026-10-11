#!/usr/bin/env bash
# submit.sh —— 作业提交：附件约束校验、上传编排与提交流程编排。
# 协议见 docs/ucloud-submit.md。校验类函数纯离线，可用本地文件直接单测。

if [[ -n "${_BUPTY_SUBMIT_LOADED:-}" ]]; then
  return 0
fi
_BUPTY_SUBMIT_LOADED=1

# ---------------------------------------------------------------------------
# 全局状态（一次提交流程内使用）
# ---------------------------------------------------------------------------
SUBMIT_FILES=()           # 合规附件路径
SUBMIT_CONTENT_FILE=""    # 目录中的 homework_content.txt 路径
SUBMIT_WARNINGS=()        # 被跳过文件的说明（人类可读）
SUBMIT_ATTACHMENT_IDS=()  # 上传后得到的 resourceId
SUBMIT_ERR=""             # 单文件校验错误信息
SUBMIT_MSG=""             # 提交成功后的服务端提示（body.msg）

# ---------------------------------------------------------------------------
# 附件约束（docs/ucloud-submit.md 第 3 节）
# ---------------------------------------------------------------------------

# 分类 -> 单文件大小上限（字节）。
_submit_limit_bytes() {
  case "$1" in
    audio)    printf '%s' $((100 * 1024 * 1024)) ;;
    video)    printf '%s' $((200 * 1024 * 1024)) ;;
    image)    printf '%s' $((20 * 1024 * 1024)) ;;
    text)     printf '%s' $((100 * 1024 * 1024)) ;;
    text-ppt) printf '%s' $((300 * 1024 * 1024)) ;;
    other)    printf '%s' $((3 * 1024 * 1024 * 1024)) ;;
    *)        printf '0' ;;
  esac
}

# 分类 -> 人类可读大小上限。
_submit_limit_label() {
  case "$1" in
    audio)    printf '100MB' ;;
    video)    printf '200MB' ;;
    image)    printf '20MB' ;;
    text)     printf '100MB' ;;
    text-ppt) printf '300MB' ;;
    other)    printf '3GB' ;;
    *)        printf '' ;;
  esac
}

# 按扩展名（转小写）返回附件分类：audio/video/image/text/text-ppt/other；
# 不在白名单返回空。
submit_ext_category() {
  local filename="$1" base ext
  base="$(basename "${filename}")"
  ext="${base##*.}"
  [[ "${ext}" == "${base}" ]] && { printf ''; return 0; }
  ext="$(printf '%s' "${ext}" | tr '[:upper:]' '[:lower:]')"
  case "${ext}" in
    mp3|m4a) printf 'audio' ;;
    mp4) printf 'video' ;;
    jpg|gif|png|jpeg) printf 'image' ;;
    txt|doc|docx|pdf|xls|xlsx) printf 'text' ;;
    ppt|pptx) printf 'text-ppt' ;;
    rar|zip) printf 'other' ;;
    *) printf '' ;;
  esac
}

# 校验单个附件文件：存在、非目录、size>0、扩展名合法、大小≤上限。
# 合法返回 0；非法置 SUBMIT_ERR（人类可读）返回 1。
submit_check_file() {
  local path="$1" name size cat limit
  SUBMIT_ERR=""
  name="$(basename "${path}")"
  if [[ ! -e "${path}" ]]; then
    SUBMIT_ERR="${name}：文件不存在"
    return 1
  fi
  if [[ -d "${path}" ]]; then
    SUBMIT_ERR="${name}：是目录，请选择文件"
    return 1
  fi
  size="$(stat -c %s "${path}" 2>/dev/null || printf '0')"
  if (( size <= 0 )); then
    SUBMIT_ERR="${name}：空文件"
    return 1
  fi
  cat="$(submit_ext_category "${name}")"
  if [[ -z "${cat}" ]]; then
    SUBMIT_ERR="${name}：不支持该格式"
    return 1
  fi
  limit="$(_submit_limit_bytes "${cat}")"
  if (( size > limit )); then
    SUBMIT_ERR="${name}：超过 $(_submit_limit_label "${cat}")"
    return 1
  fi
  return 0
}

# 扫描目录顶层普通文件：合规的进 SUBMIT_FILES；不合规的跳过并记入 SUBMIT_WARNINGS；
# homework_content.txt 记入 SUBMIT_CONTENT_FILE（不当附件）。始终返回 0。
submit_check_folder() {
  local dir="$1" f name
  SUBMIT_FILES=()
  SUBMIT_CONTENT_FILE=""
  SUBMIT_WARNINGS=()
  if [[ ! -d "${dir}" ]]; then
    SUBMIT_ERR="${dir}：目录不存在"
    return 1
  fi
  while IFS= read -r -d '' f; do
    [[ -f "${f}" ]] || continue
    name="$(basename "${f}")"
    if [[ "${name}" == "homework_content.txt" ]]; then
      SUBMIT_CONTENT_FILE="${f}"
      continue
    fi
    if submit_check_file "${f}"; then
      SUBMIT_FILES+=("${f}")
    else
      SUBMIT_WARNINGS+=("${SUBMIT_ERR}")
    fi
  done < <(find "${dir}" -maxdepth 1 -type f -print0 2>/dev/null)
  return 0
}

# 逐个上传 SUBMIT_FILES，收集 resourceId 到 SUBMIT_ATTACHMENT_IDS。
# 任一失败置 BUPTY_ERR 返回 1（已上传的不回滚，仅提示）。
submit_upload_files() {
  local f rid rid_tmp
  # 上传函数内部使用 BUPTY_UCLOUD_USER_ID。
  SUBMIT_ATTACHMENT_IDS=()
  for f in "${SUBMIT_FILES[@]}"; do
    # 用临时文件承接 stdout，避免 $(...) 子 shell 丢失 BUPTY_ERR / 重登副作用。
    rid_tmp="$(mktemp)"
    if ! ucloud_upload_attachment "${f}" > "${rid_tmp}"; then
      rm -f "${rid_tmp}"
      return 1
    fi
    rid="$(cat "${rid_tmp}")"
    rm -f "${rid_tmp}"
    SUBMIT_ATTACHMENT_IDS+=("${rid}")
  done
  return 0
}

# 字节数 -> 人类可读大小。
_submit_human_size() {
  local b="${1:-0}"
  if (( b >= 1073741824 )); then
    awk -v n="${b}" 'BEGIN{printf "%.1fGB", n/1073741824}'
  elif (( b >= 1048576 )); then
    awk -v n="${b}" 'BEGIN{printf "%.1fMB", n/1048576}'
  elif (( b >= 1024 )); then
    awk -v n="${b}" 'BEGIN{printf "%.1fKB", n/1024}'
  else
    printf '%dB' "${b}"
  fi
}

# ---------------------------------------------------------------------------
# 目录 / 文件选择器
# ---------------------------------------------------------------------------

# 是否有图形会话（无显示环境时跳过 kdialog/zenity，直接回退手输）。
_ui_has_display() {
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

# 选择目录：优先 kdialog，其次 zenity，最后回退手输路径。输出路径或空。
ui_select_directory() {
  local prompt="$1" out=""
  if _ui_has_display && command -v kdialog >/dev/null 2>&1; then
    out="$(kdialog --getexistingdirectory "${prompt}" 2>/dev/null || true)"
    printf '%s' "${out}"
    return 0
  fi
  if _ui_has_display && command -v zenity >/dev/null 2>&1; then
    out="$(zenity --file-selection --directory --title="${prompt}" 2>/dev/null || true)"
    printf '%s' "${out}"
    return 0
  fi
  if ui_input "${prompt}（目录路径，Esc 取消）： " "" 0 256; then
    printf '%s' "${UI_INPUT_RESULT}"
  fi
  return 0
}

# 选择文件：优先 kdialog，其次 zenity，最后回退手输路径。输出路径或空。
ui_select_file() {
  local prompt="$1" out=""
  if _ui_has_display && command -v kdialog >/dev/null 2>&1; then
    out="$(kdialog --getopenfilename 2>/dev/null || true)"
    printf '%s' "${out}"
    return 0
  fi
  if _ui_has_display && command -v zenity >/dev/null 2>&1; then
    out="$(zenity --file-selection --title="${prompt}" 2>/dev/null || true)"
    printf '%s' "${out}"
    return 0
  fi
  if ui_input "${prompt}（文件路径，Esc 取消）： " "" 0 256; then
    printf '%s' "${UI_INPUT_RESULT}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 提交编排
# ---------------------------------------------------------------------------

# submit_do <assignment_id> <method> <path>：编排认证、可提交判定、附件校验/收集、
# 内容读取、确认、上传、提交。成功置 SUBMIT_MSG 返回 0；失败置 BUPTY_ERR 返回 1。
# method：1=文件夹、2=单个文件。
submit_do() {
  local assignment_id="$1" method="$2" path="$3"
  SUBMIT_MSG=""
  # 重置附件 id，防止上一次提交流程的 resourceId 串场到本次提交。
  SUBMIT_ATTACHMENT_IDS=()
  local detail status assignment_type group_id is_overtime
  local content="" content_preview="" names="" n_attachments=0 total_size=0
  local f name sz joined summary ans atts_json

  # 1. 认证。
  if ! creds_load; then
    core_err "请先在设置中登录。"
    return 1
  fi
  if ! ucloud_ensure_token "${BUPTY_ACCOUNT}" "$(creds_assignment_password)" >/dev/null; then
    return 1
  fi

  # 2. 详情与可提交判定（status 为 evaluationStatus：3=已结束）。
  # 用临时文件承接 stdout，避免 $(...) 子 shell 丢失 BUPTY_ERR 与重登副作用。
  local detail_tmp
  detail_tmp="$(mktemp)"
  if ! ucloud_fetch_work_detail "${assignment_id}" > "${detail_tmp}"; then
    rm -f "${detail_tmp}"
    return 1
  fi
  detail="$(cat "${detail_tmp}")"
  rm -f "${detail_tmp}"
  if [[ -z "${detail}" || "${detail}" == "{}" || "${detail}" == "null" ]]; then
    core_err "未获取到作业详情，无法判断是否可提交。"
    return 1
  fi
  status="$(printf '%s' "${detail}" | jq -r '.status // empty' 2>/dev/null || true)"
  is_overtime="$(printf '%s' "${detail}" | jq -r '.isOvertimeCommit // 0' 2>/dev/null || true)"
  assignment_type="$(printf '%s' "${detail}" | jq -r '.assignmentType // 0' 2>/dev/null || true)"
  group_id="$(printf '%s' "${detail}" | jq -r '.subGroupId // ""' 2>/dev/null || true)"
  if [[ "${status}" == "3" && "${is_overtime}" != "0" ]]; then
    core_err "该作业已截止且不允许补交。"
    return 1
  fi

  # 3. 校验并收集附件 / 作业内容。
  if [[ "${method}" == "1" ]]; then
    if ! submit_check_folder "${path}"; then
      core_err "${SUBMIT_ERR:-目录校验失败。}"
      return 1
    fi
    if [[ -n "${SUBMIT_CONTENT_FILE}" ]]; then
      content="$(cat "${SUBMIT_CONTENT_FILE}" 2>/dev/null || true)"
      content="$(core_trim "${content}")"
    fi
  else
    if ! submit_check_file "${path}"; then
      core_err "${SUBMIT_ERR:-文件校验失败。}"
      return 1
    fi
    SUBMIT_FILES=("${path}")
    SUBMIT_CONTENT_FILE=""
    SUBMIT_WARNINGS=()
  fi

  # 数量上限 10。
  if (( ${#SUBMIT_FILES[@]} > 10 )); then
    core_err "附件数量超过 10 个上限（当前 ${#SUBMIT_FILES[@]} 个）。"
    return 1
  fi

  # 被跳过的文件展示给用户（有不合规也继续，但需用户确认）。
  if (( ${#SUBMIT_WARNINGS[@]} > 0 )); then
    joined="$(printf '；%s' "${SUBMIT_WARNINGS[@]}")"
    joined="${joined#；}"
    if ! ui_input "以下文件被跳过：${joined}（回车继续，Esc 取消）" "" 0 0; then
      core_err "已取消提交。"
      return 1
    fi
  fi

  # 4. 确认：作业内容摘要 + 附件清单与总大小。
  if core_is_blank "${content}"; then
    content_preview="（空）"
  else
    content_preview="${content//$'\n'/ }"
    if (( ${#content_preview} > 24 )); then content_preview="${content_preview:0:24}…"; fi
  fi
  n_attachments="${#SUBMIT_FILES[@]}"
  for f in "${SUBMIT_FILES[@]}"; do
    name="$(basename "${f}")"
    [[ -n "${names}" ]] && names+="、"
    names+="${name}"
    sz="$(stat -c %s "${f}" 2>/dev/null || printf '0')"
    total_size=$(( total_size + sz ))
  done
  [[ -z "${names}" ]] && names="（无）"
  summary="作业内容：${content_preview}｜附件 ${n_attachments} 个（${names}）共 $(_submit_human_size "${total_size}")"
  if (( ${#summary} > 180 )); then summary="${summary:0:180}…"; fi
  if ! ui_input "${summary} —— 确认提交？(y/回车=确认，其它=取消)" "" 0 1; then
    core_err "已取消提交。"
    return 1
  fi
  ans="${UI_INPUT_RESULT}"
  if [[ -n "${ans}" && "${ans}" != "y" && "${ans}" != "Y" ]]; then
    core_err "已取消提交。"
    return 1
  fi

  # 5. 上传附件。
  if (( ${#SUBMIT_FILES[@]} > 0 )); then
    tui_set_status "正在上传附件…"
    tui_render
    if ! submit_upload_files "${BUPTY_UCLOUD_USER_ID}"; then
      return 1
    fi
  fi

  # 6. 提交作业。
  atts_json='[]'
  if (( ${#SUBMIT_ATTACHMENT_IDS[@]} > 0 )); then
    atts_json="$(printf '%s\n' "${SUBMIT_ATTACHMENT_IDS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')"
  fi
  tui_set_status "正在提交作业…"
  tui_render
  if ! ucloud_submit_assignment "${assignment_id}" "${content}" "${atts_json}" "${assignment_type}" "${group_id}"; then
    return 1
  fi

  # 7. 成功反馈（body.msg）。
  SUBMIT_MSG="$(printf '%s' "${HTTP_BODY:-}" | jq -r '.msg // empty' 2>/dev/null || true)"
  if core_is_blank "${SUBMIT_MSG}"; then SUBMIT_MSG="操作成功"; fi
  return 0
}

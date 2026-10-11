#!/usr/bin/env bash
# tests/unit_submit.sh —— 作业提交（submit.sh）附件约束纯函数单元测试（全离线临时文件）。
# 只测可离线、无副作用的纯函数 submit_ext_category / submit_check_file / submit_check_folder；
# 不调用 submit_upload_files / submit_do / ui_select_* / ucloud_*（联网或弹窗）。
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
source "${BUPTY_HOME}/lib/ui.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/lib/submit.sh"
# shellcheck disable=SC1090
source "${BUPTY_HOME}/tests/lib/testlib.sh"

# core.sh 会开启 `set -e`，而这里需要直接调用返回非零的纯函数（如 submit_check_file），
# 故关闭 -e，保留 -u 与 pipefail。失败的判定交给 testlib 计数器与 t_summary 的退出码。
set +e

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# 断言 haystack 包含 needle（testlib 无此原语，本地补充）。
assert_contains() {
  local haystack="$1" needle="$2" desc="${3:-}"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    ((TESTS_PASS += 1))
  else
    ((TESTS_FAIL += 1))
    printf 'FAIL [%s] %s\n' "${TESTS_NAME}" "${desc}"
    printf '  want contains: %q\n' "${needle}"
    printf '  got          : %q\n' "${haystack}"
  fi
}

# 运行 submit_check_file 并把返回码 / SUBMIT_ERR 存入全局 _T_RC / _T_ERR。
_run_check_file() {
  local path="$1"
  SUBMIT_ERR=""
  submit_check_file "${path}"
  _T_RC=$?
  _T_ERR="${SUBMIT_ERR}"
}

# ---------------------------------------------------------------------------
# 1. submit_ext_category：扩展名 -> 分类
# ---------------------------------------------------------------------------
t_begin "扩展名分类"
assert_eq "$(submit_ext_category 'a.mp3')" "audio" "mp3 -> audio"
assert_eq "$(submit_ext_category 'a.m4a')" "audio" "m4a -> audio"
assert_eq "$(submit_ext_category 'a.mp4')" "video" "mp4 -> video"
assert_eq "$(submit_ext_category 'a.jpg')" "image" "jpg -> image"
assert_eq "$(submit_ext_category 'a.gif')" "image" "gif -> image"
assert_eq "$(submit_ext_category 'a.png')" "image" "png -> image"
assert_eq "$(submit_ext_category 'a.jpeg')" "image" "jpeg -> image"
assert_eq "$(submit_ext_category 'a.txt')" "text" "txt -> text"
assert_eq "$(submit_ext_category 'a.doc')" "text" "doc -> text"
assert_eq "$(submit_ext_category 'a.docx')" "text" "docx -> text"
assert_eq "$(submit_ext_category 'a.pdf')" "text" "pdf -> text"
assert_eq "$(submit_ext_category 'a.xls')" "text" "xls -> text"
assert_eq "$(submit_ext_category 'a.xlsx')" "text" "xlsx -> text"
assert_eq "$(submit_ext_category 'a.ppt')" "text-ppt" "ppt -> text-ppt"
assert_eq "$(submit_ext_category 'a.pptx')" "text-ppt" "pptx -> text-ppt"
assert_eq "$(submit_ext_category 'a.rar')" "other" "rar -> other"
assert_eq "$(submit_ext_category 'a.zip')" "other" "zip -> other"

t_begin "扩展名大小写不敏感"
assert_eq "$(submit_ext_category 'A.MP3')" "audio" "A.MP3 -> audio"
assert_eq "$(submit_ext_category 'X.PDF')" "text" "X.PDF -> text"

t_begin "非法/无扩展名"
assert_eq "$(submit_ext_category 'foo')" "" "无扩展名 -> 空"
assert_eq "$(submit_ext_category 'foo.exe')" "" "白名单外 .exe -> 空"

# ---------------------------------------------------------------------------
# 2. submit_check_file：单文件校验
# ---------------------------------------------------------------------------
printf 'hello pdf' > "${TMPDIR}/a.pdf"
printf '' > "${TMPDIR}/empty.txt"
printf 'hello exe' > "${TMPDIR}/a.exe"
truncate -s 100M "${TMPDIR}/ok.mp3"    # 恰好边界 = 100*1024*1024
truncate -s 101M "${TMPDIR}/big.mp3"    # 超过 audio 上限
truncate -s 21M  "${TMPDIR}/big.jpg"    # 超过 image 上限 20MB
truncate -s 301M "${TMPDIR}/big.pptx"   # 超过 text-ppt 上限 300MB
mkdir -p "${TMPDIR}/subdir"

t_begin "合法文件"
_run_check_file "${TMPDIR}/a.pdf"
assert_eq "${_T_RC}" "0" "a.pdf 返回 0"
assert_eq "${_T_ERR}" "" "a.pdf 无错误"

t_begin "空文件"
_run_check_file "${TMPDIR}/empty.txt"
assert_eq "${_T_RC}" "1" "空文件返回 1"
assert_contains "${_T_ERR}" "空文件" "SUBMIT_ERR 含「空文件」"

t_begin "超大文件 mp3"
_run_check_file "${TMPDIR}/big.mp3"
assert_eq "${_T_RC}" "1" "101M mp3 返回 1"
assert_contains "${_T_ERR}" "超过" "含「超过」"
assert_contains "${_T_ERR}" "100MB" "含「100MB」"

t_begin "超大文件 jpg"
_run_check_file "${TMPDIR}/big.jpg"
assert_eq "${_T_RC}" "1" "21M jpg 返回 1"
assert_contains "${_T_ERR}" "超过" "含「超过」"
assert_contains "${_T_ERR}" "20MB" "含「20MB」"

t_begin "超大文件 pptx"
_run_check_file "${TMPDIR}/big.pptx"
assert_eq "${_T_RC}" "1" "301M pptx 返回 1"
assert_contains "${_T_ERR}" "超过" "含「超过」"
assert_contains "${_T_ERR}" "300MB" "含「300MB」"

t_begin "恰好边界 100M"
_run_check_file "${TMPDIR}/ok.mp3"
assert_eq "${_T_RC}" "0" "100M mp3 返回 0（≤100MB 通过）"
assert_eq "${_T_ERR}" "" "无错误"

t_begin "非法扩展名"
_run_check_file "${TMPDIR}/a.exe"
assert_eq "${_T_RC}" "1" "a.exe 返回 1"
assert_contains "${_T_ERR}" "格式" "SUBMIT_ERR 含「格式」"

t_begin "目录与不存在路径"
_run_check_file "${TMPDIR}/subdir"
assert_eq "${_T_RC}" "1" "目录返回 1"
assert_contains "${_T_ERR}" "目录" "含「目录」"
_run_check_file "${TMPDIR}/nope.pdf"
assert_eq "${_T_RC}" "1" "不存在路径返回 1"
assert_contains "${_T_ERR}" "不存在" "含「不存在」"

# ---------------------------------------------------------------------------
# 3. submit_check_folder：目录扫描
# ---------------------------------------------------------------------------
mkdir -p "${TMPDIR}/folder"
printf 'a' > "${TMPDIR}/folder/a.pdf"
printf 'b' > "${TMPDIR}/folder/b.mp4"
printf '作业内容' > "${TMPDIR}/folder/homework_content.txt"
printf 'c' > "${TMPDIR}/folder/c.exe"
: > "${TMPDIR}/folder/d.txt"   # 空文件

t_begin "目录扫描（合规+内容+非法+空文件）"
SUBMIT_ERR=""
submit_check_folder "${TMPDIR}/folder"
rc=$?
assert_eq "${rc}" "0" "返回 0"
assert_eq "${#SUBMIT_FILES[@]}" "2" "SUBMIT_FILES 数量为 2"
sorted_files="$(printf '%s\n' "${SUBMIT_FILES[@]}" | sort)"
want_files="$(printf '%s\n' "${TMPDIR}/folder/a.pdf" "${TMPDIR}/folder/b.mp4" | sort)"
assert_eq "${sorted_files}" "${want_files}" "SUBMIT_FILES 只含 a.pdf/b.mp4"
assert_eq "${SUBMIT_CONTENT_FILE}" "${TMPDIR}/folder/homework_content.txt" "SUBMIT_CONTENT_FILE 指向 homework_content.txt"
assert_eq "${#SUBMIT_WARNINGS[@]}" "2" "SUBMIT_WARNINGS 数量为 2"
joined_warnings="$(printf '；%s' "${SUBMIT_WARNINGS[@]}")"
joined_warnings="${joined_warnings#；}"
assert_contains "${joined_warnings}" "c.exe" "警告含 c.exe"
assert_contains "${joined_warnings}" "d.txt" "警告含 d.txt"
assert_contains "${joined_warnings}" "不支持该格式" "警告含格式错误"
assert_contains "${joined_warnings}" "空文件" "警告含空文件错误"

# 数量上限：submit_check_folder 只负责收集、不拒绝，>10 的拒绝在 submit_do（联网层）做。
mkdir -p "${TMPDIR}/folder11"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  printf '%s' "${i}" > "${TMPDIR}/folder11/f${i}.pdf"
done

t_begin "目录扫描（11 个合规附件，数量校验不在本层）"
SUBMIT_ERR=""
submit_check_folder "${TMPDIR}/folder11"
rc=$?
assert_eq "${rc}" "0" "返回 0（本层不拒绝超量）"
assert_eq "${#SUBMIT_FILES[@]}" "11" "SUBMIT_FILES 数量为 11"
assert_eq "${#SUBMIT_WARNINGS[@]}" "0" "无警告（超量校验在 submit_do，不在此层）"
assert_eq "${SUBMIT_CONTENT_FILE}" "" "无 homework_content.txt"

t_summary

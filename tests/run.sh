#!/usr/bin/env bash
# tests/run.sh —— 运行全部单元测试。
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

for t in "${TESTS_DIR}"/unit_*.sh; do
  echo "==> $(basename "${t}")"
  if bash "${t}"; then
    :
  else
    FAILED=1
  fi
done

if [[ "${FAILED}" -eq 0 ]]; then
  echo "全部单元测试通过。"
else
  echo "存在失败测试。"
fi
exit "${FAILED}"

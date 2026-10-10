#!/usr/bin/env bash
# install.sh —— 将 bupty 安装到稳定目录并加入 shell PATH（bash/zsh/fish）。
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_DIR="${BUPTY_INSTALL_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/bupty}"
BIN_DIR="${HOME}/.local/bin"
WRAPPER="${BIN_DIR}/bupty"

# 复制文件到安装目录（排除 .git 与凭据/缓存）。
echo "==> 安装到 ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
rsync -a --delete \
  --exclude '.git' --exclude '.gitignore' --exclude 'credentials.json' \
  --exclude '*.tmp' --exclude '__pycache__' --exclude '.pytest_cache' \
  "${SRC_DIR}/" "${INSTALL_DIR}/" 2>/dev/null \
  || cp -R "${SRC_DIR}"/. "${INSTALL_DIR}/"

# 生成入口 wrapper。
echo "==> 创建入口 ${WRAPPER}"
mkdir -p "${BIN_DIR}"
cat > "${WRAPPER}" <<EOF
#!/usr/bin/env bash
# bupty 启动器（由 install.sh 生成）。
exec "${INSTALL_DIR}/bin/bupty" "\$@"
EOF
chmod +x "${WRAPPER}"

# 将 ~/.local/bin 加入 PATH（幂等）。
_add_path_bash() {
  local rc="$1"
  [[ -f "${rc}" ]] || touch "${rc}"
  if ! grep -q 'bupty' "${rc}"; then
    printf '\n# bupty\nexport PATH="%s:$PATH"\n' "${BIN_DIR}" >> "${rc}"
    echo "==> 已写入 ${rc}"
  else
    echo "==> ${rc} 已包含 bupty，跳过"
  fi
}

_add_path_fish() {
  local rc="${HOME}/.config/fish/config.fish"
  mkdir -p "$(dirname "${rc}")"
  [[ -f "${rc}" ]] || touch "${rc}"
  if ! grep -q 'bupty' "${rc}"; then
    printf '\n# bupty\nfish_add_path %s\n' "${BIN_DIR}" >> "${rc}"
    echo "==> 已写入 ${rc}"
  else
    echo "==> ${rc} 已包含 bupty，跳过"
  fi
}

shell_name="$(basename "${SHELL:-bash}")"
case "${shell_name}" in
  zsh) _add_path_bash "${HOME}/.zshrc" ;;
  fish) _add_path_fish ;;
  *) _add_path_bash "${HOME}/.bashrc" ;;
esac

# 检查是否已可直接运行。
if [[ ":$PATH:" == *":${BIN_DIR}:"* ]]; then
  echo "==> ${BIN_DIR} 已在 PATH 中，可直接运行。"
else
  echo "==> 提示：请重新打开终端，或执行：export PATH=\"${BIN_DIR}:\$PATH\""
fi

echo
echo "安装完成。运行： bupty"

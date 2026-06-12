# Optional shared uv environment.
# Source this file only if you want to use the shared uv installation.

# 安装前缀与管理员组：默认值可在 source 前用环境变量覆盖。
# 机器相关配置由安装目录下的 muv.env 提供，env.sh 本身保持模板化。
_muv_env_path=""
if [ -n "${BASH_SOURCE:-}" ]; then
  _muv_env_path="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _muv_env_path="${(%):-%x}"
fi

if [ -z "${UV_ROOT+x}" ]; then
  if [ -n "$_muv_env_path" ]; then
    _muv_env_dir="$(cd "$(dirname "$_muv_env_path")" >/dev/null 2>&1 && pwd -P)"
    UV_ROOT="${_muv_env_dir:-/opt/uv}"
  else
    UV_ROOT="/opt/uv"
  fi
fi

_muv_config="${UV_CONFIG_FILE:-${UV_ROOT}/muv.env}"
[ -r "$_muv_config" ] && . "$_muv_config"

UV_GROUP="${UV_GROUP:-${MUV_GROUP:-uvusers}}"

# 所有用户都能用的部分
export UV_CACHE_DIR="${UV_ROOT}/cache"
# 镜像源：默认值由 install.sh / muv mirror 写入 muv.env；用户可在 source 前预设覆盖
export UV_DEFAULT_INDEX="${UV_DEFAULT_INDEX:-${MUV_DEFAULT_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple/}}"

# uv-managed Python 共享存储（仅管理员可写，版本集中管理）
export UV_PYTHON_INSTALL_DIR="${UV_ROOT}/python"
export UV_PYTHON_CACHE_DIR="${UV_ROOT}/python-cache"
export UV_MANAGED_PYTHON="true"
# 普通用户禁止下载/安装 Python，只能使用管理员预置的版本（下方管理员段会放开）
export UV_PYTHON_DOWNLOADS="never"

# ext4 不支持 reflink/CoW，显式使用 hardlink 共享缓存数据块
export UV_LINK_MODE="hardlink"

# 避免重复追加 PATH
case ":$PATH:" in
  *":${UV_ROOT}/bin:"*) ;;
  *) export PATH="${UV_ROOT}/bin:$PATH" ;;
esac

# 以下仅 uvusers 组可用：共享工具 + symlink 写入 /opt/uv/bin/
if [ "$(id -u)" -ne 0 ] && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "${UV_GROUP}"; then
  return 0 2>/dev/null || exit 0
fi

# Python symlink 写入共享 bin（仅管理员）
export UV_PYTHON_BIN_DIR="${UV_ROOT}/bin"

# 管理员可显式安装 Python（manual：允许 uv python install，但不自动下载）
export UV_PYTHON_DOWNLOADS="manual"

# uv tool 共享存储（仅管理员）
export UV_TOOL_DIR="${UV_ROOT}/tools"
export UV_TOOL_BIN_DIR="${UV_ROOT}/bin"

# 权限由目录级 default ACL 统一保证，不修改用户 umask

unset _muv_env_path _muv_env_dir _muv_config

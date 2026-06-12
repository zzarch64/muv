#!/usr/bin/env bash
#
# install.sh - muv 安装器
#
# 用法:
#   install.sh [options]
#   install.sh install [options]   兼容旧入口写法
#   install.sh help
#
# 选项:
#   --prefix <dir>                 安装前缀。默认: /opt/uv。
#   --group <name>                 管理员组。默认: uvusers。
#   --index <url>                  配置默认包索引地址。
#   --no-mirror                    不执行镜像自动选择。
#   --python <version>             安装默认托管 Python 版本。默认: 3.12。
#
# 安装结果:
#   $PREFIX/env.sh                 用户 source 的环境脚本。
#   $PREFIX/muv.env                机器相关运行配置。
#   $PREFIX/bin/muv                安装后的共享 uv 管理命令。
#
set -euo pipefail

UV_ROOT="${UV_ROOT:-/opt/uv}"
UV_GROUP="${UV_GROUP:-uvusers}"
ENV_FILE="$UV_ROOT/env.sh"
CONFIG_FILE="$UV_ROOT/muv.env"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd -P)"

ADMIN_DIRS=("$UV_ROOT" "$UV_ROOT/bin" "$UV_ROOT/lib" "$UV_ROOT/tools" "$UV_ROOT/python" "$UV_ROOT/python-cache")
ALL_DIRS=("${ADMIN_DIRS[@]}" "$UV_ROOT/cache")
TEMP_DIRS=()

MUV_LOG_NAME=install
[ -r "$SCRIPT_DIR/lib/muv.sh" ] || { printf '\033[1;31m[error]\033[0m 缺少共享库: %s/lib/muv.sh\n' "$SCRIPT_DIR" >&2; exit 1; }
. "$SCRIPT_DIR/lib/muv.sh"

cleanup_temp_dirs() {
  [ "${#TEMP_DIRS[@]}" -eq 0 ] || rm -rf "${TEMP_DIRS[@]}"
}
trap cleanup_temp_dirs EXIT

set_uv_root() {
  UV_ROOT="$1"
  ENV_FILE="$UV_ROOT/env.sh"
  CONFIG_FILE="$UV_ROOT/muv.env"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "需要 root 权限，请使用 sudo 运行: sudo $0 ${ORIG_ARGS[*]}"
  fi
}

find_uv_binaries() {
  local src_dir="$SCRIPT_DIR"
  uv_src="" uvx_src=""
  for base in "$src_dir/bin" "$src_dir" "$UV_ROOT/bin"; do
    if [ -x "$base/uv" ] && [ -x "$base/uvx" ]; then uv_src="$base/uv"; uvx_src="$base/uvx"; break; fi
  done
  if [ -z "$uv_src" ]; then
    local tmp; tmp="$(mktemp -d)"; TEMP_DIRS+=("$tmp")
    bootstrap_uv "$tmp"
    uv_src="$tmp/uv"; uvx_src="$tmp/uvx"
  fi
}

setup_dirs() {
  log "创建目录并设置权限"
  mkdir -p "${ALL_DIRS[@]}"
  for d in "${ADMIN_DIRS[@]}"; do
    chown root:"$UV_GROUP" "$d"; chmod 2775 "$d"
  done
  chown root:"$UV_GROUP" "$UV_ROOT/cache"; chmod 3777 "$UV_ROOT/cache"
}

setup_acl() {
  log "设置 default ACL"
  for d in "${ALL_DIRS[@]}"; do
    setfacl -d -m g:"$UV_GROUP":rwx "$d"
  done
  setfacl -d -m o:rwx "$UV_ROOT/cache"
  chmod o+rwx "$UV_ROOT/cache"
}

safe_install() {
  local src="$1" dest="$2"; shift 2
  if [ "$(readlink -f "$src" 2>/dev/null)" = "$(readlink -f "$dest" 2>/dev/null)" ]; then
    chown root:"$UV_GROUP" "$dest" 2>/dev/null || true
    chmod 0775 "$dest" 2>/dev/null || true
  else
    install "$@" "$src" "$dest"
  fi
}

deploy_files() {
  local src_dir="$1" index_url="${2:-}" env_src runtime_src lib_src lib_dest
  env_src="$src_dir/env.sh"
  runtime_src="$src_dir/muv"
  lib_src="$src_dir/lib/muv.sh"
  lib_dest="$UV_ROOT/lib/muv.sh"
  [ -f "$env_src" ] || die "缺少模板: $env_src"
  [ -f "$runtime_src" ] || die "缺少运行期命令模板: $runtime_src"
  [ -f "$lib_src" ] || die "缺少共享库: $lib_src"

  log "部署 uv / uvx / pip / env.sh / lib/muv.sh / muv"
  safe_install "$uv_src"  "$UV_ROOT/bin/uv"  -m 0775 -o root -g "$UV_GROUP"
  safe_install "$uvx_src" "$UV_ROOT/bin/uvx" -m 0775 -o root -g "$UV_GROUP"
  printf '#!/usr/bin/env bash\nexec %s/bin/uv pip "$@"\n' "$(shell_quote "$UV_ROOT")" > "$UV_ROOT/bin/pip"
  chown root:"$UV_GROUP" "$UV_ROOT/bin/pip"
  chmod 0755 "$UV_ROOT/bin/pip"

  if [ "$(readlink -f "$env_src" 2>/dev/null)" != "$(readlink -f "$ENV_FILE" 2>/dev/null)" ]; then
    install -m 0664 "$env_src" "$ENV_FILE"
  fi
  chown root:"$UV_GROUP" "$ENV_FILE" 2>/dev/null || true
  chmod 0664 "$ENV_FILE" 2>/dev/null || true

  mkdir -p "$UV_ROOT/lib"
  chown root:"$UV_GROUP" "$UV_ROOT/lib" 2>/dev/null || true
  chmod 2775 "$UV_ROOT/lib" 2>/dev/null || true
  if [ "$(readlink -f "$lib_src" 2>/dev/null)" != "$(readlink -f "$lib_dest" 2>/dev/null)" ]; then
    install -m 0664 -o root -g "$UV_GROUP" "$lib_src" "$lib_dest"
  fi
  chown root:"$UV_GROUP" "$lib_dest" 2>/dev/null || true
  chmod 0664 "$lib_dest" 2>/dev/null || true

  install -m 0775 -o root -g "$UV_GROUP" "$runtime_src" "$UV_ROOT/bin/muv"
  write_runtime_config "$index_url"
}

setup_python() {
  local ver="$1" pybin
  log "安装默认 Python $ver"
  run_uv python install "$ver"
  pybin="$(run_uv python find "$ver" 2>/dev/null || true)"
  if [ -n "$pybin" ] && [ -x "$pybin" ]; then
    ln -sf "$pybin" "$UV_ROOT/bin/python3.${ver#*.}"
    ln -sf "$pybin" "$UV_ROOT/bin/python3"
    ln -sf "$pybin" "$UV_ROOT/bin/python"
    log "python symlink -> $pybin"
  fi
}

cmd_install() {
  local index_url="" do_mirror=1 default_python="3.12"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix)    set_uv_root "$2"; shift 2 ;;
      --group)     UV_GROUP="$2"; shift 2 ;;
      --index)     index_url="$2"; do_mirror=0; shift 2 ;;
      --no-mirror) do_mirror=0; shift ;;
      --python)    default_python="$2"; shift 2 ;;
      *)           die "install.sh: 未知参数 $1" ;;
    esac
  done
  need_root
  command -v setfacl >/dev/null 2>&1 || die "缺少 setfacl，请先安装 acl 包"

  ADMIN_DIRS=("$UV_ROOT" "$UV_ROOT/bin" "$UV_ROOT/lib" "$UV_ROOT/tools" "$UV_ROOT/python" "$UV_ROOT/python-cache")
  ALL_DIRS=("${ADMIN_DIRS[@]}" "$UV_ROOT/cache")

  find_uv_binaries

  local rfs hfs
  rfs="$(df -P "$(dirname "$UV_ROOT")" 2>/dev/null | awk 'NR==2{print $1}')"
  hfs="$(df -P /home 2>/dev/null | awk 'NR==2{print $1}')"
  [ -n "$rfs" ] && [ -n "$hfs" ] && [ "$rfs" != "$hfs" ] \
    && warn "$UV_ROOT 与 /home 不同分区，hardlink 将退化为 copy"

  getent group "$UV_GROUP" >/dev/null && log "组 $UV_GROUP 已存在" \
    || { log "创建组 $UV_GROUP"; groupadd "$UV_GROUP"; }

  local src_dir="$SCRIPT_DIR"
  setup_dirs
  setup_acl
  deploy_files "$src_dir" "$index_url"

  if [ "$do_mirror" -eq 1 ]; then
    log "使用 cnpip 选择镜像"
    index_url="$(pick_fastest_index)" && log "选择镜像: $index_url" || warn "镜像选择失败，保留当前配置"
  fi
  [ -n "$index_url" ] && write_index "$index_url"

  setup_python "$default_python"
  fix_root_cache
  "$UV_ROOT/bin/muv" doctor

  cat <<EOF

安装完成。请在用户 shell 配置中加入：source $ENV_FILE
管理命令已安装到：$UV_ROOT/bin/muv
EOF
}

cmd_help() { awk 'NR>1 && /^[^#]/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; }

ORIG_ARGS=("$@")
case "${1:-}" in
  help|-h|--help) cmd_help ;;
  install) shift; cmd_install "$@" ;;
  mirror|grant|revoke|update|python|doctor)
    die "源码入口只负责安装；请先执行 install.sh，然后使用 $UV_ROOT/bin/muv $1"
    ;;
  *) cmd_install "$@" ;;
esac

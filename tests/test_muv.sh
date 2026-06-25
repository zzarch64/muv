#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT=""

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

make_runtime_root() {
  TMP_ROOT="$(mktemp -d)"
  mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/cache" "$TMP_ROOT/python" "$TMP_ROOT/python-cache" "$TMP_ROOT/tools"
  chmod +t "$TMP_ROOT/cache"
  printf '# test env\n' > "$TMP_ROOT/env.sh"
  printf "MUV_GROUP='%s'\n" "$(id -gn)" > "$TMP_ROOT/config.env"
  cat > "$TMP_ROOT/bin/uv" <<'UVEOF'
#!/usr/bin/env bash
case "$*" in
  "--version") printf 'uv 0.test\n' ;;
  "python install 3.12") exit 0 ;;
  "python find 3.12") printf '%s\n' "$UV_PYTHON_INSTALL_DIR/cpython-3.12/bin/python3.12" ;;
  "python uninstall 3.12") touch "$UV_ROOT_UNINSTALL_MARKER" ;;
  "python list --only-installed") printf 'cpython-3.12\n' ;;
  "pip install --default-index "*) [ -n "${MUV_TEST_PREWARM_MARKER:-}" ] && touch "$MUV_TEST_PREWARM_MARKER"; exit 0 ;;
  *) printf 'unexpected uv args: %s\n' "$*" >&2; exit 64 ;;
esac
UVEOF
  chmod +x "$TMP_ROOT/bin/uv"
  cp "$TMP_ROOT/bin/uv" "$TMP_ROOT/bin/uvx"
  cp "$ROOT_DIR/muv" "$TMP_ROOT/bin/muv"
  chmod +x "$TMP_ROOT/bin/muv"
}

make_root_fake_path() {
  local fake_path="$TMP_ROOT/fakebin"
  mkdir -p "$fake_path"
  cat > "$fake_path/id" <<'IDEOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then
  printf '0\n'
else
  /usr/bin/id "$@"
fi
IDEOF
  cat > "$fake_path/setfacl" <<'NOOPEOF'
#!/usr/bin/env bash
exit 0
NOOPEOF
  cat > "$fake_path/chown" <<'NOOPEOF'
#!/usr/bin/env bash
exit 0
NOOPEOF
  cat > "$fake_path/getfacl" <<'FACLEOF'
#!/usr/bin/env bash
printf 'default:other::rwx\n'
FACLEOF
  chmod +x "$fake_path/id" "$fake_path/setfacl" "$fake_path/chown" "$fake_path/getfacl"
  printf '%s\n' "$fake_path"
}

cleanup() {
  [ -z "$TMP_ROOT" ] || rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

test_functions_are_inline() {
  for func in run_uv pick_fastest_index bootstrap_uv log warn die shell_quote; do
    grep -Eq "^${func}\(\)" "$ROOT_DIR/muv" \
      || fail "muv should define $func()"
  done
}

test_lock_functions_are_inline() {
  for func in for_each_index_dir lock_index_dir unlock_index_dir prewarm_index; do
    grep -Eq "^${func}\(\)" "$ROOT_DIR/muv" \
      || fail "muv should define $func()"
  done
}

test_version_flag() {
  "$ROOT_DIR/muv" --version >/dev/null || fail "muv --version should succeed"
}

test_python_rm_ignores_piped_confirmation() {
  make_runtime_root
  local marker="$TMP_ROOT/uninstalled"
  if printf 'yes\n' | UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" UV_ROOT_UNINSTALL_MARKER="$marker" \
      "$TMP_ROOT/bin/muv" python rm 3.12 >/dev/null 2>&1; then
    fail "piped confirmation should not authorize python rm"
  fi
  [ ! -e "$marker" ] || fail "python rm should not uninstall after piped confirmation"
}

test_doctor_reports_locked_index() {
  make_runtime_root
  printf "MUV_GROUP='%s'\nMUV_DEFAULT_INDEX='https://example.invalid/simple'\n" "$(id -gn)" \
    > "$TMP_ROOT/config.env"
  mkdir -p "$TMP_ROOT/cache/simple-v21/index" "$TMP_ROOT/cache/wheels-v6/index"
  local fake_path="$TMP_ROOT/locked-fakebin" out="$TMP_ROOT/doctor.out"
  mkdir -p "$fake_path"
  cat > "$fake_path/getfacl" <<'FACLEOF'
#!/usr/bin/env bash
printf 'default:other::rwx\nmask::r-x\nother::r-x\n'
FACLEOF
  cat > "$fake_path/stat" <<'STATEOF'
#!/usr/bin/env bash
# index/ 报为 root 拥有；其余委托真实 stat
if [ "$1" = "-c" ] && [ "$2" = "%U" ]; then printf 'root\n'; else /usr/bin/stat "$@"; fi
STATEOF
  chmod +x "$fake_path/getfacl" "$fake_path/stat"
  PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" \
    "$TMP_ROOT/bin/muv" doctor >"$out" 2>&1 || true
  grep -Fq "index 锁: OK" "$out" \
    || { cat "$out"; fail "doctor should report index lock OK when locked"; }
}

test_doctor_reports_unlocked_index() {
  make_runtime_root
  printf "MUV_GROUP='%s'\nMUV_DEFAULT_INDEX='https://example.invalid/simple'\n" "$(id -gn)" \
    > "$TMP_ROOT/config.env"
  mkdir -p "$TMP_ROOT/cache/simple-v21/index" "$TMP_ROOT/cache/wheels-v6/index"
  local fake_path="$TMP_ROOT/unlocked-fakebin" out="$TMP_ROOT/doctor.out"
  mkdir -p "$fake_path"
  cat > "$fake_path/getfacl" <<'FACLEOF'
#!/usr/bin/env bash
printf 'default:other::rwx\nmask::rwx\nother::rwx\n'
FACLEOF
  chmod +x "$fake_path/getfacl"
  if PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" \
      "$TMP_ROOT/bin/muv" doctor >"$out" 2>&1; then
    fail "doctor should fail when index is configured but not locked"
  fi
  grep -Fq "index 锁: 未锁定" "$out" \
    || { cat "$out"; fail "doctor should report index lock missing when unlocked"; }
}

test_doctor_index_lock_not_applicable_without_config() {
  make_runtime_root
  rm -f "$TMP_ROOT/config.env"
  printf "MUV_GROUP='%s'\n" "$(id -gn)" > "$TMP_ROOT/config.env"
  local fake_path="$TMP_ROOT/noidx-fakebin" out="$TMP_ROOT/doctor.out"
  mkdir -p "$fake_path"
  cat > "$fake_path/getfacl" <<'FACLEOF'
#!/usr/bin/env bash
printf 'default:other::rwx\n'
FACLEOF
  chmod +x "$fake_path/getfacl"
  PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" \
    "$TMP_ROOT/bin/muv" doctor >"$out" 2>&1 || true
  grep -Fq "index 锁: 未启用" "$out" \
    || { cat "$out"; fail "doctor should mark index lock not-applicable without a configured source"; }
}

test_doctor_fails_when_env_missing() {
  make_runtime_root
  rm -f "$TMP_ROOT/env.sh"
  local fake_path="$TMP_ROOT/fakebin"
  mkdir -p "$fake_path"
  cat > "$fake_path/getfacl" <<'FACLEOF'
#!/usr/bin/env bash
printf 'default:other::rwx\n'
FACLEOF
  chmod +x "$fake_path/getfacl"
  if PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" \
      "$TMP_ROOT/bin/muv" doctor >/dev/null 2>&1; then
    fail "doctor should fail when env.sh is missing"
  fi
}

test_doctor_uses_installed_prefix_when_config_missing() {
  make_runtime_root
  rm -f "$TMP_ROOT/config.env"
  local fake_path="$TMP_ROOT/fakebin" out="$TMP_ROOT/doctor.out"
  mkdir -p "$fake_path"
  cat > "$fake_path/getfacl" <<'FACLEOF'
#!/usr/bin/env bash
printf 'default:other::rwx\n'
FACLEOF
  chmod +x "$fake_path/getfacl"
  if PATH="$fake_path:$PATH" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" doctor >"$out" 2>&1; then
    fail "doctor should fail when config.env is missing"
  fi
  grep -Fq "检查 $TMP_ROOT" "$out" \
    || fail "doctor should inspect the installed prefix when config.env is missing"
  grep -Fq "config.env: 缺失" "$out" \
    || fail "doctor should report missing config.env"
  if grep -Fq "/opt/uv" "$out"; then
    fail "doctor should not fall back to /opt/uv when installed env.sh exists"
  fi
}

test_install_sets_pip_group_ownership() {
  make_runtime_root
  local fake_path pip_group pip_mode
  fake_path="$(make_root_fake_path)"
  PATH="$fake_path:$PATH" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" install >/dev/null 2>&1 \
    || fail "install should succeed with fake root helpers"
  pip_group="$(stat -c '%G' "$TMP_ROOT/bin/pip")"
  pip_mode="$(stat -c '%a' "$TMP_ROOT/bin/pip")"
  [ "$pip_group" = "$(id -gn)" ] || fail "pip wrapper should use the configured group"
  [ "$pip_mode" = "755" ] || fail "pip wrapper should be executable"
}

test_install_without_index_does_not_lock() {
  make_runtime_root
  local fake_path marker="$TMP_ROOT/prewarmed"
  fake_path="$(make_root_fake_path)"
  PATH="$fake_path:$PATH" UV_GROUP="$(id -gn)" MUV_TEST_PREWARM_MARKER="$marker" \
    "$TMP_ROOT/bin/muv" install >/dev/null 2>&1 \
    || fail "install without --index should still succeed"
  [ ! -e "$marker" ] || fail "install without --index should not prewarm/lock the cache"
}

test_install_with_index_prewarms_and_locks() {
  make_runtime_root
  local fake_path marker="$TMP_ROOT/prewarmed"
  fake_path="$(make_root_fake_path)"
  PATH="$fake_path:$PATH" UV_GROUP="$(id -gn)" MUV_TEST_PREWARM_MARKER="$marker" \
    "$TMP_ROOT/bin/muv" install --index https://example.invalid/simple >/dev/null 2>&1 \
    || fail "install --index should succeed"
  [ -e "$marker" ] || fail "install --index should prewarm the configured source"
}

test_install_subcommand_in_help() {
  "$ROOT_DIR/muv" help | grep -q "install" \
    || fail "help should mention install subcommand"
}

test_source_mode_blocks_runtime_commands() {
  if "$ROOT_DIR/muv" mirror >/dev/null 2>&1; then
    fail "source mode should block runtime commands like mirror"
  fi
}

test_root_commands_auto_sudo_with_resolved_runtime_path() {
  make_runtime_root
  local fake_path="$TMP_ROOT/nonroot-fakebin" sudo_log="$TMP_ROOT/sudo-args" err="$TMP_ROOT/stderr"
  mkdir -p "$fake_path"
  cat > "$fake_path/id" <<'IDEOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then
  printf '1000\n'
else
  /usr/bin/id "$@"
fi
IDEOF
  cat > "$fake_path/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MUV_TEST_SUDO_LOG"
exit 99
SUDOEOF
  chmod +x "$fake_path/id" "$fake_path/sudo"

  if PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" \
      MUV_TEST_SUDO_LOG="$sudo_log" "$TMP_ROOT/bin/muv" grant alice 2>"$err"; then
    fail "auto sudo should return the sudo exit status for non-root users"
  fi
  [ -f "$sudo_log" ] || fail "muv should invoke sudo automatically"
  grep -Fxq -- "-E" "$sudo_log" || fail "auto sudo should preserve environment with -E"
  grep -Fxq -- "UV_ROOT=$TMP_ROOT" "$sudo_log" || fail "auto sudo should pass UV_ROOT explicitly"
  grep -Fxq -- "UV_GROUP=$(id -gn)" "$sudo_log" || fail "auto sudo should pass UV_GROUP explicitly"
  grep -Fxq -- "$TMP_ROOT/bin/muv" "$sudo_log" || fail "auto sudo should use the resolved runtime path"
  grep -Fxq -- "grant" "$sudo_log" || fail "auto sudo should preserve the original command"
  grep -Fxq -- "alice" "$sudo_log" || fail "auto sudo should preserve the original arguments"
}

test_mirror_requires_root_auto_sudo() {
  make_runtime_root
  local fake_path="$TMP_ROOT/mirror-fakebin" sudo_log="$TMP_ROOT/mirror-sudo-args"
  mkdir -p "$fake_path"
  cat > "$fake_path/id" <<'IDEOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then
  printf '1000\n'
else
  /usr/bin/id "$@"
fi
IDEOF
  cat > "$fake_path/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MUV_TEST_SUDO_LOG"
exit 99
SUDOEOF
  chmod +x "$fake_path/id" "$fake_path/sudo"

  if PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" \
      MUV_TEST_SUDO_LOG="$sudo_log" "$TMP_ROOT/bin/muv" mirror https://example.invalid/simple 2>/dev/null; then
    fail "mirror auto sudo should return the sudo exit status for non-root users"
  fi
  [ -f "$sudo_log" ] || fail "muv mirror should invoke sudo automatically"
  grep -Fxq -- "mirror" "$sudo_log" || fail "mirror auto sudo should preserve the original command"
  grep -Fxq -- "https://example.invalid/simple" "$sudo_log" \
    || fail "mirror auto sudo should preserve the original arguments"
}

test_update_auto_sudo_with_resolved_runtime_path() {
  make_runtime_root
  local fake_path="$TMP_ROOT/nonroot-update-fakebin" sudo_log="$TMP_ROOT/update-sudo-args"
  mkdir -p "$fake_path"
  cat > "$fake_path/id" <<'IDEOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then
  printf '1000\n'
else
  /usr/bin/id "$@"
fi
IDEOF
  cat > "$fake_path/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MUV_TEST_SUDO_LOG"
exit 99
SUDOEOF
  chmod +x "$fake_path/id" "$fake_path/sudo"

  if PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" \
      MUV_TEST_SUDO_LOG="$sudo_log" "$TMP_ROOT/bin/muv" update >/dev/null 2>&1; then
    fail "update auto sudo should return the sudo exit status for non-root users"
  fi
  [ -f "$sudo_log" ] || fail "muv update should invoke sudo automatically"
  grep -Fxq -- "-E" "$sudo_log" || fail "update auto sudo should preserve environment with -E"
  grep -Fxq -- "UV_ROOT=$TMP_ROOT" "$sudo_log" || fail "update auto sudo should pass UV_ROOT explicitly"
  grep -Fxq -- "UV_GROUP=$(id -gn)" "$sudo_log" || fail "update auto sudo should pass UV_GROUP explicitly"
  grep -Fxq -- "$TMP_ROOT/bin/muv" "$sudo_log" || fail "update auto sudo should use the resolved runtime path"
  grep -Fxq -- "update" "$sudo_log" || fail "update auto sudo should preserve the original command"
}

# 让 bootstrap_uv 的 `curl | sh` 落地一份可用的 uv/uvx mock。
make_update_fake_path() {
  local fake_path="$TMP_ROOT/update-run-fakebin"
  cp -r "$(make_root_fake_path)" "$fake_path"
  cat > "$fake_path/curl" <<'CURLEOF'
#!/usr/bin/env bash
cat <<'INSTALLER'
mkdir -p "$UV_INSTALL_DIR"
cat > "$UV_INSTALL_DIR/uv" <<'UVEOF'
#!/usr/bin/env bash
case "$*" in
  "--version") printf 'uv 0.test\n' ;;
  "pip install --default-index "*) [ -n "${MUV_TEST_PREWARM_MARKER:-}" ] && touch "$MUV_TEST_PREWARM_MARKER"; exit 0 ;;
  *) exit 0 ;;
esac
UVEOF
chmod +x "$UV_INSTALL_DIR/uv"
cp "$UV_INSTALL_DIR/uv" "$UV_INSTALL_DIR/uvx"
INSTALLER
CURLEOF
  cp "$fake_path/curl" "$fake_path/wget"
  # install -o root -g 在非 root 下会真正 chown 失败；剥掉属主/权限选项，仅复制。
  cat > "$fake_path/install" <<'INSTEOF'
#!/usr/bin/env bash
args=(); while [ $# -gt 0 ]; do
  case "$1" in
    -m|-o|-g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
INSTEOF
  chmod +x "$fake_path/curl" "$fake_path/wget" "$fake_path/install"
  printf '%s\n' "$fake_path"
}

test_update_relocks_when_index_configured() {
  make_runtime_root
  local fake_path marker="$TMP_ROOT/prewarmed"
  fake_path="$(make_update_fake_path)"
  printf "MUV_GROUP='%s'\nMUV_DEFAULT_INDEX='https://example.invalid/simple'\n" "$(id -gn)" \
    > "$TMP_ROOT/config.env"
  PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" MUV_TEST_PREWARM_MARKER="$marker" \
    "$TMP_ROOT/bin/muv" update >/dev/null 2>&1 \
    || fail "update should succeed when an index is configured"
  [ -e "$marker" ] || fail "update should re-prewarm/lock the configured source"
}

test_update_does_not_lock_without_index() {
  make_runtime_root
  local fake_path marker="$TMP_ROOT/prewarmed"
  fake_path="$(make_update_fake_path)"
  printf "MUV_GROUP='%s'\n" "$(id -gn)" > "$TMP_ROOT/config.env"
  PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" MUV_TEST_PREWARM_MARKER="$marker" \
    "$TMP_ROOT/bin/muv" update >/dev/null 2>&1 \
    || fail "update should succeed without a configured index"
  [ ! -e "$marker" ] || fail "update should not lock when no index is configured"
}

test_installed_muv_can_repair_installation() {
  make_runtime_root
  local fake_path
  fake_path="$(make_root_fake_path)"
  PATH="$fake_path:$PATH" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" install >/dev/null 2>&1 \
    || fail "installed muv should repair installation using its own runtime command"
}

test_config_read_does_not_execute_commands() {
  make_runtime_root
  local marker="$TMP_ROOT/config-was-sourced"
  {
    printf "MUV_GROUP='%s'\n" "$(id -gn)"
    printf "MUV_DEFAULT_INDEX='https://example.invalid/simple/'\n"
    printf "touch '%s'\n" "$marker"
  } > "$TMP_ROOT/config.env"
  UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" doctor >/dev/null 2>&1 || true
  [ ! -e "$marker" ] || fail "reading config.env should not execute commands"
}

test_update_cleans_temp_dir_on_bootstrap_failure() {
  make_runtime_root
  local fake_path="$TMP_ROOT/update-fakebin" update_tmp="$TMP_ROOT/update-download"
  mkdir -p "$fake_path"
  cat > "$fake_path/mktemp" <<'MKTEMPEOF'
#!/usr/bin/env bash
mkdir -p "$MUV_TEST_MKTEMP_DIR"
printf '%s\n' "$MUV_TEST_MKTEMP_DIR"
MKTEMPEOF
  cat > "$fake_path/curl" <<'FAILEOF'
#!/usr/bin/env bash
exit 7
FAILEOF
  cp "$fake_path/curl" "$fake_path/wget"
  chmod +x "$fake_path/mktemp" "$fake_path/curl" "$fake_path/wget"

  if PATH="$fake_path:$PATH" UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" \
      MUV_TEST_MKTEMP_DIR="$update_tmp" "$TMP_ROOT/bin/muv" update >/dev/null 2>&1; then
    fail "muv update should fail when bootstrap download fails"
  fi
  [ ! -d "$update_tmp" ] || fail "muv update should clean temp dir after bootstrap failure"
}

test_install_options_require_values() {
  local opt out
  for opt in --prefix --group --index --python; do
    out="$("$ROOT_DIR/muv" install "$opt" 2>&1 || true)"
    printf '%s\n' "$out" | grep -Fq "install: $opt 需要参数" \
      || fail "install $opt without value should report a stable error"
    if printf '%s\n' "$out" | grep -Fq "unbound variable"; then
      fail "install $opt without value should not expose bash internals"
    fi
  done
}

test_no_mirror_rejected() {
  local out
  out="$("$ROOT_DIR/muv" install --no-mirror 2>&1 || true)"
  printf '%s\n' "$out" | grep -Fq "未知参数" \
    || fail "install --no-mirror should be rejected as unknown argument"
}

test_index_auto_accepted() {
  make_runtime_root
  local fake_path
  fake_path="$(make_root_fake_path)"
  # --index auto should be accepted (mirror selection will fail but that's OK)
  PATH="$fake_path:$PATH" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" install --index auto >/dev/null 2>&1 \
    || fail "install --index auto should be accepted"
}

test_python_list_rejects_extra_arguments() {
  make_runtime_root
  if UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" python list junk >/dev/null 2>&1; then
    fail "python list should reject extra version arguments"
  fi
  if UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" python list --yes >/dev/null 2>&1; then
    fail "python list should reject --yes"
  fi
}

test_python_list_forms_still_work() {
  make_runtime_root
  UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" python list | grep -Fxq 'cpython-3.12' \
    || fail "python list should list installed versions"
  UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" python | grep -Fxq 'cpython-3.12' \
    || fail "python without subcommand should list installed versions"
}

test_functions_are_inline
test_lock_functions_are_inline
test_version_flag
test_python_rm_ignores_piped_confirmation
test_doctor_reports_locked_index
test_doctor_reports_unlocked_index
test_doctor_index_lock_not_applicable_without_config
test_doctor_fails_when_env_missing
test_doctor_uses_installed_prefix_when_config_missing
test_install_sets_pip_group_ownership
test_install_without_index_does_not_lock
test_install_with_index_prewarms_and_locks
test_install_subcommand_in_help
test_source_mode_blocks_runtime_commands
test_root_commands_auto_sudo_with_resolved_runtime_path
test_mirror_requires_root_auto_sudo
test_update_auto_sudo_with_resolved_runtime_path
test_update_relocks_when_index_configured
test_update_does_not_lock_without_index
test_installed_muv_can_repair_installation
test_config_read_does_not_execute_commands
test_update_cleans_temp_dir_on_bootstrap_failure
test_install_options_require_values
test_no_mirror_rejected
test_index_auto_accepted
test_python_list_rejects_extra_arguments
test_python_list_forms_still_work

printf 'ok - muv regression tests\n'

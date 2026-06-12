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
  printf "MUV_GROUP='%s'\n" "$(id -gn)" > "$TMP_ROOT/muv.env"
  cat > "$TMP_ROOT/bin/uv" <<'UVEOF'
#!/usr/bin/env bash
case "$*" in
  "--version") printf 'uv 0.test\n' ;;
  "python install 3.12") exit 0 ;;
  "python find 3.12") printf '%s\n' "$UV_PYTHON_INSTALL_DIR/cpython-3.12/bin/python3.12" ;;
  "python uninstall 3.12") touch "$UV_ROOT_UNINSTALL_MARKER" ;;
  "python list --only-installed") printf 'cpython-3.12\n' ;;
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

test_install_sets_pip_group_ownership() {
  grep -Fq 'chown root:"$UV_GROUP" "$UV_ROOT/bin/pip"' "$ROOT_DIR/muv" \
    || fail "muv should set group ownership for pip wrapper"
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

test_installed_muv_can_repair_installation() {
  make_runtime_root
  local fake_path
  fake_path="$(make_root_fake_path)"
  PATH="$fake_path:$PATH" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" install --no-mirror >/dev/null 2>&1 \
    || fail "installed muv should repair installation using its own runtime command"
}

test_config_read_does_not_execute_commands() {
  make_runtime_root
  local marker="$TMP_ROOT/config-was-sourced"
  {
    printf "MUV_GROUP='%s'\n" "$(id -gn)"
    printf "MUV_DEFAULT_INDEX='https://example.invalid/simple/'\n"
    printf "touch '%s'\n" "$marker"
  } > "$TMP_ROOT/muv.env"
  UV_ROOT="$TMP_ROOT" UV_GROUP="$(id -gn)" "$TMP_ROOT/bin/muv" doctor >/dev/null 2>&1 || true
  [ ! -e "$marker" ] || fail "reading muv.env should not execute commands"
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

test_functions_are_inline
test_version_flag
test_python_rm_ignores_piped_confirmation
test_doctor_fails_when_env_missing
test_install_sets_pip_group_ownership
test_install_subcommand_in_help
test_source_mode_blocks_runtime_commands
test_root_commands_auto_sudo_with_resolved_runtime_path
test_installed_muv_can_repair_installation
test_config_read_does_not_execute_commands
test_update_cleans_temp_dir_on_bootstrap_failure

printf 'ok - muv regression tests\n'

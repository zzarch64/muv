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
  "python find 3.12") printf '%s\n' "$UV_PYTHON_INSTALL_DIR/cpython-3.12/bin/python3.12" ;;
  "python uninstall 3.12") touch "$UV_ROOT_UNINSTALL_MARKER" ;;
  "python list --only-installed") printf 'cpython-3.12\n' ;;
  *) printf 'unexpected uv args: %s\n' "$*" >&2; exit 64 ;;
esac
UVEOF
  chmod +x "$TMP_ROOT/bin/uv"
  mkdir -p "$TMP_ROOT/lib"
  cp "$ROOT_DIR/lib/muv.sh" "$TMP_ROOT/lib/muv.sh"
  cp "$ROOT_DIR/muv" "$TMP_ROOT/bin/muv"
  chmod +x "$TMP_ROOT/bin/muv"
}

cleanup() {
  [ -z "$TMP_ROOT" ] || rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

test_shared_library_is_used() {
  [ -f "$ROOT_DIR/lib/muv.sh" ] || fail "lib/muv.sh should contain shared functions"
  if bash "$ROOT_DIR/lib/muv.sh" >/dev/null 2>&1; then
    fail "lib/muv.sh should be source-only, not a runnable command"
  fi
  ! grep -Eq '^run_uv\(\)|^pick_fastest_index\(\)|^bootstrap_uv\(\)' "$ROOT_DIR/muv" \
    || fail "muv should source shared functions instead of redefining them"
  ! grep -Eq '^run_uv\(\)|^pick_fastest_index\(\)|^bootstrap_uv\(\)' "$ROOT_DIR/install.sh" \
    || fail "install.sh should source shared functions instead of redefining them"
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
  grep -Fq 'chown root:"$UV_GROUP" "$UV_ROOT/bin/pip"' "$ROOT_DIR/install.sh" \
    || fail "install.sh should set group ownership for pip wrapper"
}

test_shared_library_is_used
test_version_flag
test_python_rm_ignores_piped_confirmation
test_doctor_fails_when_env_missing
test_install_sets_pip_group_ownership

printf 'ok - muv regression tests\n'

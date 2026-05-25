#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
target_script="${repo_root}/precision-dr.sh"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

# Load function definitions without executing main().
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/,$d' "${target_script}")


fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}


pass() {
  printf 'PASS: %s\n' "$*"
}


assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"

  [[ "${actual}" == "${expected}" ]] || {
    printf 'Expected:\n%s\n' "${expected}" >&2
    printf 'Actual:\n%s\n' "${actual}" >&2
    fail "${label}"
  }
}


capture_sorted_unique_lines() {
  sort -u | sed '/^$/d'
}


save_function() {
  local fn_name="$1"
  declare -f "${fn_name}" | sed "1s/^${fn_name}/${fn_name}__saved/"
}


restore_function() {
  local fn_name="$1"
  unset -f "${fn_name}"
  eval "$2"
  eval "${fn_name}() { ${fn_name}__saved \"\$@\"; }"
  unset -f "${fn_name}__saved"
}


collect_required_commands_for_mode() {
  local mode="$1"
  local saved_require_command=""

  REQUIRED_COMMANDS=()
  saved_require_command="$(save_function require_command)"
  # shellcheck disable=SC2329
  require_command() {
    REQUIRED_COMMANDS+=("$1")
  }

  # shellcheck disable=SC2034
  MODE="${mode}"
  require_mode_commands
  restore_function require_command "${saved_require_command}"

  printf '%s\n' "${REQUIRED_COMMANDS[@]}" | capture_sorted_unique_lines
}


assert_mode_command_set() {
  local mode="$1"
  local expected="$2"
  local actual=""
  local normalized_expected=""

  actual="$(collect_required_commands_for_mode "${mode}")"
  normalized_expected="$(printf '%s\n' "${expected}" | capture_sorted_unique_lines)"
  assert_equals "${actual}" "${normalized_expected}" "required command set for mode ${mode}"
  pass "required command set for ${mode}"
}


assert_package_mapping_for_commands() {
  local commands_text="$1"
  local cmd=""

  while IFS= read -r cmd; do
    [[ -n "${cmd}" ]] || continue
    package_for_command "${cmd}" >/dev/null || fail "missing package mapping for command ${cmd}"
  done <<< "${commands_text}"

  pass "package mappings exist for command set"
}


test_require_command_install_path_with_fake_apt() {
  local fake_bin_dir="${tmpdir}/fake-bin"
  local saved_package_for_command=""
  local saved_require_debian_family=""
  local saved_warn=""
  local saved_path="${PATH}"
  local fake_cmd="cmd-from-install"
  local fake_package="pkg-${fake_cmd}"
  local fake_apt_log="${tmpdir}/fake-apt.log"

  mkdir -p "${fake_bin_dir}"
  saved_package_for_command="$(save_function package_for_command)"
  saved_require_debian_family="$(save_function require_debian_family)"
  saved_warn="$(save_function warn)"

  cat > "${fake_bin_dir}/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${TEST_FAKE_APT_LOG}"

if [[ "$1" == "update" ]]; then
  exit 0
fi

if [[ "$1" == "-qq" && "$2" == "update" ]]; then
  exit 0
fi

if [[ "$1" == "-qq" && "$2" == "install" && "$3" == "-y" ]]; then
  pkg="$4"
  cmd="${pkg#pkg-}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TEST_FAKE_APT_BIN_DIR}/${cmd}"
  chmod +x "${TEST_FAKE_APT_BIN_DIR}/${cmd}"
  exit 0
fi

if [[ "$1" == "install" && "$2" == "-y" ]]; then
  pkg="$3"
  cmd="${pkg#pkg-}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TEST_FAKE_APT_BIN_DIR}/${cmd}"
  chmod +x "${TEST_FAKE_APT_BIN_DIR}/${cmd}"
  exit 0
fi

exit 1
EOF
  chmod +x "${fake_bin_dir}/apt-get"

  package_for_command() {
    [[ "$1" == "${fake_cmd}" ]] || fail "unexpected command passed to package_for_command: $1"
    printf '%s\n' "${fake_package}"
  }
  require_debian_family() { :; }
  warn() { :; }

  APT_UPDATED=0
  export TEST_FAKE_APT_BIN_DIR="${fake_bin_dir}"
  export TEST_FAKE_APT_LOG="${fake_apt_log}"
  PATH="${fake_bin_dir}:${saved_path}"
  require_command "${fake_cmd}"
  command -v "${fake_cmd}" >/dev/null 2>&1 || fail "install path did not make command available"
  [[ "${APT_UPDATED}" -eq 1 ]] || fail "apt_update_once did not mark package metadata as refreshed"
  assert_equals "$(cat "${fake_apt_log}")" $'-qq update\n-qq install -y '"${fake_package}" "fake apt-get command sequence"

  restore_function package_for_command "${saved_package_for_command}"
  restore_function require_debian_family "${saved_require_debian_family}"
  restore_function warn "${saved_warn}"
  PATH="${saved_path}"
  unset TEST_FAKE_APT_BIN_DIR TEST_FAKE_APT_LOG
  pass "require_command install path with fake apt-get"
}


test_require_recovery_command_paths() {
  local saved_run_in_recovery_chroot=""
  local saved_fatal=""

  saved_run_in_recovery_chroot="$(save_function run_in_recovery_chroot)"
  saved_fatal="$(save_function fatal)"

  TEST_FATAL_MESSAGE=""
  run_in_recovery_chroot() {
    [[ "$1" == *"command -v present-cmd "* ]]
  }
  fatal() {
    TEST_FATAL_MESSAGE="$*"
    return 1
  }

  require_recovery_command present-cmd
  if require_recovery_command missing-cmd; then
    fail "require_recovery_command succeeded for a missing command"
  fi
  [[ "${TEST_FATAL_MESSAGE}" == *"missing-cmd"* ]] || fail "require_recovery_command failure did not mention the missing command"

  restore_function run_in_recovery_chroot "${saved_run_in_recovery_chroot}"
  restore_function fatal "${saved_fatal}"
  pass "require_recovery_command success and failure paths"
}


backup_expected="$(cat <<'EOF'
awk
basename
du
find
grep
mkdir
mount
mount.cifs
mountpoint
paste
readlink
rm
sort
stat
umount
zfs
zpool
zstd
EOF
)"

restore_expected="$(cat <<'EOF'
awk
basename
blkid
find
grep
mkdir
mount
mount.cifs
mountpoint
mdadm
paste
readlink
rm
sfdisk
sort
tail
umount
zfs
zpool
zstd
EOF
)"

repair_expected="$(cat <<'EOF'
apt-get
awk
basename
blkid
chroot
dpkg-query
findmnt
grep
grub-install
mkdir
mdadm
mount
mountpoint
paste
readlink
rm
sort
umount
update-grub
update-initramfs
zfs
zpool
EOF
)"

rebuild_expected="$(cat <<'EOF'
awk
basename
blkdiscard
blkid
grep
mkdir
mdadm
mkfs.ext4
mkfs.vfat
mkswap
paste
partprobe
readlink
rm
sfdisk
sgdisk
sleep
sort
swapoff
udevadm
zfs
zpool
EOF
)"

full_restore_expected="$(printf '%s\n%s\n%s\n%s\n' \
  "${backup_expected}" \
  "${restore_expected}" \
  "${repair_expected}" \
  "${rebuild_expected}" | capture_sorted_unique_lines)"

assert_mode_command_set "backup" "${backup_expected}"
assert_mode_command_set "restore-data" "${restore_expected}"
assert_mode_command_set "repair-boot" "${repair_expected}"
assert_mode_command_set "rebuild-layout" "${rebuild_expected}"
assert_mode_command_set "full-restore" "${full_restore_expected}"

assert_package_mapping_for_commands "${full_restore_expected}"
test_require_command_install_path_with_fake_apt
test_require_recovery_command_paths

pass "all command-check tests"

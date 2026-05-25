#!/usr/bin/env bash

set -euo pipefail

# Unified DR scaffold for the PRECISION laptop.
#
# Design constraints:
# - One script is the eventual end state.
# - Development remains phased.
# - The currently implemented scope is storage-layout verification/rebuild only.
# - The authoritative backup reference is /usr/local/bin/zfs-backup.sh.
# - Layout checks use semantic equivalence, not literal UUID/GUID identity.

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

readonly POOL_NAME="PRECISION"
readonly ROOT_DATASET="${POOL_NAME}/ROOT/kubuntu"
readonly RECOVERY_ROOT="/mnt/recovery"
readonly BACKUP_NAS="rackstation"
readonly BACKUP_SHARE="/Backup"
readonly BACKUP_MOUNT="/mnt/synology"
readonly BACKUP_CREDENTIALS="/etc/sysbackup/nas.cred"
readonly BACKUP_KEEP_COUNT=4
readonly BACKUP_FILE_GLOB="precision-*.zfs.zst"
readonly CLOUD_SYNC_TARGET="gdrive:precision-backups/"

readonly DEFAULT_DISK1="/dev/disk/by-id/nvme-eui.0025384331408197"
readonly DEFAULT_DISK2="/dev/disk/by-id/nvme-eui.002538433140818a"
readonly DEFAULT_DISK3="/dev/disk/by-id/nvme-eui.002538433140819d"

readonly TYPE_EFI="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
readonly TYPE_LINUX_RAID="A19D880F-05FC-4D3B-A006-743F0F84911E"
readonly TYPE_ZFS="6A85CF4D-1DD2-11B2-99A6-080020736631"

readonly DATASET_SPECS=(
  "${POOL_NAME}|mountpoint|none"
  "${POOL_NAME}|canmount|off"
  "${POOL_NAME}|compression|zstd"
  "${POOL_NAME}|acltype|posix"
  "${POOL_NAME}|xattr|sa"
  "${POOL_NAME}|dnodesize|auto"
  "${POOL_NAME}|normalization|formD"
  "${POOL_NAME}|relatime|on"
  "${POOL_NAME}/ROOT|mountpoint|none"
  "${POOL_NAME}/ROOT|canmount|off"
  "${POOL_NAME}/ROOT/kubuntu|mountpoint|/"
  "${POOL_NAME}/ROOT/kubuntu|canmount|noauto"
  "${POOL_NAME}/home|mountpoint|/home"
  "${POOL_NAME}/home/Downloads|mountpoint|/home/me/Downloads"
  "${POOL_NAME}/home/Downloads|compression|off"
  "${POOL_NAME}/srv|mountpoint|/srv"
  "${POOL_NAME}/var|mountpoint|none"
  "${POOL_NAME}/var|canmount|off"
  "${POOL_NAME}/var/cache|mountpoint|/var/cache"
  "${POOL_NAME}/var/cache|com.sun:auto-snapshot|false"
  "${POOL_NAME}/var/lib|mountpoint|none"
  "${POOL_NAME}/var/lib|canmount|off"
  "${POOL_NAME}/var/lib/docker|mountpoint|none"
  "${POOL_NAME}/var/lib/docker|canmount|on"
  "${POOL_NAME}/var/log|mountpoint|/var/log"
  "${POOL_NAME}/var/tmp|mountpoint|/var/tmp"
  "${POOL_NAME}/var/tmp|com.sun:auto-snapshot|false"
)

MODE=""
DISK1="${DEFAULT_DISK1}"
DISK2="${DEFAULT_DISK2}"
DISK3="${DEFAULT_DISK3}"
ASSUME_YES=0
CHECK_FAILED=0
BACKUP_MOUNTED_BY_SCRIPT=0
APT_UPDATED=0


info() {
  printf '[INFO] %s\n' "$*"
}


warn() {
  printf '[WARN] %s\n' "$*" >&2
}


error() {
  printf '[ERROR] %s\n' "$*" >&2
}


fatal() {
  error "$*"
  exit 1
}


usage() {
  cat <<EOF
Usage:
  sudo ./${SCRIPT_NAME} <mode> [options]

Implemented modes:
  backup           Create a recursive compressed ZFS backup on the NAS and
                   apply retention.
  check-layout     Verify that the target storage layout already matches the
                   expected restore-ready scaffold.
  rebuild-layout   Destructively recreate that scaffold in a live OS.
  restore-data     Mount the NAS, let the user choose a backup archive, and
                   receive it into the recovery pool.
  repair-boot      Rebuild /boot and EFI bootability inside the restored
                   system.
  full-restore     Run rebuild-layout, restore-data, and repair-boot as one
                   recovery flow.

Compatibility aliases:
  check            Alias for check-layout
  apply            Alias for rebuild-layout

Options:
  --disk1 <by-id>  Override disk 1 path. Default: ${DEFAULT_DISK1}
  --disk2 <by-id>  Override disk 2 path. Default: ${DEFAULT_DISK2}
  --disk3 <by-id>  Override disk 3 path. Default: ${DEFAULT_DISK3}
  --yes            Skip destructive confirmation for rebuild-layout.
  -h, --help       Show this help text.

Scope notes:
  - This script is the unified DR scaffold for the project.
  - Current implementation covers backup, storage verification/rebuild, data restore, and boot repair.
  - Semantic equivalence is the contract; exact UUID/GUID recreation is not.
EOF
}


require_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "Run this script as root."
}


require_live_environment() {
  if [[ ! -d /cdrom ]] && [[ ! -d /run/live ]]; then
    fatal "${MODE} must be run from a live OS environment."
  fi
}


require_command() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi

  warn "${cmd} is required but was not found; attempting installation..."
  install_package_for_command "${cmd}"

  command -v "${cmd}" >/dev/null 2>&1 || fatal "Required command still not found after installation attempt: ${cmd}"
}


load_os_release() {
  [[ -r /etc/os-release ]] || fatal "Cannot detect operating system: /etc/os-release is missing."
  # shellcheck disable=SC1091
  . /etc/os-release
}


require_debian_family() {
  local os_id=""
  local os_like=""

  load_os_release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"

  if [[ "${os_id}" == "debian" || "${os_id}" == "ubuntu" || "${os_like}" == *debian* ]]; then
    return 0
  fi

  fatal "Automatic package installation is only supported on Debian/Ubuntu-based systems. Detected ID='${os_id}' ID_LIKE='${os_like}'."
}


package_for_command() {
  local cmd="$1"

  case "${cmd}" in
    awk)
      printf 'gawk\n'
      ;;
    apt-get)
      printf 'apt\n'
      ;;
    basename|chroot|du|mkdir|paste|readlink|rm|sleep|sort|stat|tail)
      printf 'coreutils\n'
      ;;
    blkdiscard|blkid|findmnt|mount|mountpoint|mkswap|sfdisk|swapoff|umount|wipefs)
      printf 'util-linux\n'
      ;;
    dpkg-query)
      printf 'dpkg\n'
      ;;
    find)
      printf 'findutils\n'
      ;;
    grep)
      printf 'grep\n'
      ;;
    mount.cifs)
      printf 'cifs-utils\n'
      ;;
    grub-install|update-grub)
      printf 'grub2-common\n'
      ;;
    update-initramfs)
      printf 'initramfs-tools\n'
      ;;
    mdadm)
      printf 'mdadm\n'
      ;;
    mkfs.ext4)
      printf 'e2fsprogs\n'
      ;;
    mkfs.vfat)
      printf 'dosfstools\n'
      ;;
    partprobe)
      printf 'parted\n'
      ;;
    sgdisk)
      printf 'gdisk\n'
      ;;
    udevadm)
      printf 'udev\n'
      ;;
    zfs|zpool)
      printf 'zfsutils-linux\n'
      ;;
    zstd)
      printf 'zstd\n'
      ;;
    *)
      return 1
      ;;
  esac
}


apt_update_once() {
  if (( APT_UPDATED == 1 )); then
    return 0
  fi

  DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null 2>&1 || \
    fatal "Failed to refresh apt package metadata."
  APT_UPDATED=1
}


install_package_for_command() {
  local cmd="$1"
  local package_name=""

  require_debian_family
  package_name="$(package_for_command "${cmd}")" || fatal "No package mapping is defined for required command: ${cmd}"

  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${package_name}" >/dev/null 2>&1 || \
    fatal "Failed to install package '${package_name}' for required command '${cmd}'."
}


validate_by_id_disk() {
  local disk="$1"
  [[ "${disk}" == /dev/disk/by-id/* ]] || fatal "Disk must be a /dev/disk/by-id path: ${disk}"
  [[ -b "${disk}" ]] || fatal "Disk is not a block device: ${disk}"
}


validate_distinct_disks() {
  [[ "${DISK1}" != "${DISK2}" ]] || fatal "disk1 and disk2 must be different devices."
  [[ "${DISK1}" != "${DISK3}" ]] || fatal "disk1 and disk3 must be different devices."
  [[ "${DISK2}" != "${DISK3}" ]] || fatal "disk2 and disk3 must be different devices."
}


real_disk_path() {
  readlink -f "$1"
}


part_path() {
  local disk_real="$1"
  local part_num="$2"
  printf '%sp%s\n' "${disk_real}" "${part_num}"
}


report_mismatch() {
  CHECK_FAILED=1
  printf '[MISMATCH] %s\n' "$*" >&2
}


expect_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    report_mismatch "${label}: expected '${expected}', got '${actual}'"
  fi
}


expect_line_present() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fqx "${needle}" <<<"${haystack}"; then
    report_mismatch "${label}: missing '${needle}'"
  fi
}


blkid_value() {
  local device="$1"
  local field="$2"
  blkid -s "${field}" -o value "${device}" 2>/dev/null || true
}


check_partition_dump() {
  local disk_real="$1"
  shift
  local disk_real_re="${disk_real//./\\.}"
  local dump=""
  local expected_partition_count="$#"
  local actual_partition_count=0
  local spec=""
  local spec_line=""
  local fragment=""
  local -a fragments=()
  local matched=0

  dump="$(sfdisk -d "${disk_real}")"
  expect_line_present "${dump}" "label: gpt" "${disk_real} partition label"
  expect_line_present "${dump}" "device: ${disk_real}" "${disk_real} device path"
  actual_partition_count="$(grep -c "^${disk_real_re}p[0-9]" <<<"${dump}" || true)"
  expect_equal "${actual_partition_count}" "${expected_partition_count}" "${disk_real} partition count"

  for spec in "$@"; do
    matched=0
    while IFS= read -r spec_line; do
      [[ -n "${spec_line}" ]] || continue
      matched=1
      IFS='|' read -ra fragments <<<"${spec}"
      for fragment in "${fragments[@]}"; do
        if [[ "${spec_line}" != *"${fragment}"* ]]; then
          matched=0
          break
        fi
      done
      if (( matched == 1 )); then
        break
      fi
    done < <(grep "^${disk_real_re}p[0-9]" <<<"${dump}" || true)

    if (( matched == 0 )); then
      report_mismatch "${disk_real} partition layout: missing semantic match for '${spec}'"
    fi
  done
}


check_mdadm_array() {
  local md_device="$1"
  local md_version="$2"
  local raid_level="$3"
  local raid_devices="$4"
  local expected_name="$5"
  shift 5
  local expected_members=("$@")
  local detail=""
  local scan=""
  local actual_members=""
  local expected_members_joined=""
  local actual_name=""

  [[ -e "${md_device}" ]] || {
    report_mismatch "${md_device} is missing"
    return
  }

  detail="$(mdadm --detail "${md_device}")"
  expect_line_present "${detail}" "           Version : ${md_version}" "${md_device} md version"
  expect_line_present "${detail}" "        Raid Level : ${raid_level}" "${md_device} raid level"
  expect_line_present "${detail}" "      Raid Devices : ${raid_devices}" "${md_device} raid devices"

  actual_name="$(awk -F': ' '/^[[:space:]]+Name : / {print $2}' <<<"${detail}")"
  expect_equal "${actual_name}" "${expected_name}" "${md_device} md name"

  actual_members="$(awk '/active sync/ {print $NF}' <<<"${detail}" | sorted_join_lines)"
  expected_members_joined="$(printf '%s\n' "${expected_members[@]}" | sorted_join_lines)"
  expect_equal "${actual_members}" "${expected_members_joined}" "${md_device} member devices"

  scan="$(mdadm --detail --scan)"
  if ! grep -Fq "ARRAY ${md_device} metadata=${md_version}" <<<"${scan}"; then
    report_mismatch "${md_device} missing from mdadm --detail --scan"
  fi
}


check_filesystem_signature() {
  local device="$1"
  local expected_type="$2"
  local expected_label="$3"
  local actual_type=""
  local actual_label=""

  actual_type="$(blkid_value "${device}" TYPE)"
  actual_label="$(blkid_value "${device}" LABEL)"

  expect_equal "${actual_type}" "${expected_type}" "${device} filesystem type"
  expect_equal "${actual_label}" "${expected_label}" "${device} filesystem label"
}


check_zpool_members() {
  local status=""
  local actual_members=""
  local expected_members_joined=""

  if ! zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    report_mismatch "zpool ${POOL_NAME} is missing"
    return
  fi

  status="$(zpool status -P "${POOL_NAME}")"
  expect_line_present "${status}" "  pool: ${POOL_NAME}" "${POOL_NAME} pool name"

  actual_members="$(awk '
    /^config:/ {in_config=1; next}
    /^errors:/ {in_config=0}
    in_config && $1 ~ /^\/dev\/disk\/by-id\// {print $1}
  ' <<<"${status}" | sorted_join_lines)"
  expected_members_joined="$(printf '%s\n' \
    "${DISK1}-part4" \
    "${DISK2}-part4" \
    "${DISK3}-part2" | sorted_join_lines)"
  expect_equal "${actual_members}" "${expected_members_joined}" "${POOL_NAME} vdev member paths"
}


check_zpool_property() {
  local property="$1"
  local expected="$2"
  local actual=""

  actual="$(zpool get -H -o value "${property}" "${POOL_NAME}" 2>/dev/null || true)"
  expect_equal "${actual}" "${expected}" "zpool ${POOL_NAME} property ${property}"
}


check_zfs_property() {
  local dataset="$1"
  local property="$2"
  local expected="$3"
  local actual=""

  if ! zfs list -H -o name "${dataset}" >/dev/null 2>&1; then
    report_mismatch "dataset ${dataset} is missing"
    return
  fi

  actual="$(zfs get -H -o value "${property}" "${dataset}" 2>/dev/null || true)"
  expect_equal "${actual}" "${expected}" "dataset ${dataset} property ${property}"
}


check_dataset_scaffold() {
  local spec=""
  local dataset=""
  local property=""
  local expected=""

  for spec in "${DATASET_SPECS[@]}"; do
    IFS='|' read -r dataset property expected <<<"${spec}"
    check_zfs_property "${dataset}" "${property}" "${expected}"
  done
}


zfs_dataset_value() {
  local dataset="$1"
  local property="$2"

  zfs get -H -o value "${property}" "${dataset}" 2>/dev/null || true
}


sorted_join_lines() {
  sort | paste -sd',' -
}


cleanup_backup_mount() {
  if (( BACKUP_MOUNTED_BY_SCRIPT == 1 )) && mountpoint -q "${BACKUP_MOUNT}"; then
    umount "${BACKUP_MOUNT}" 2>/dev/null || true
  fi
}


mount_backup_target() {
  mkdir -p "${BACKUP_MOUNT}"

  if mountpoint -q "${BACKUP_MOUNT}"; then
    info "Backup target already mounted at ${BACKUP_MOUNT}."
    return 0
  fi

  info "Mounting backup target at ${BACKUP_MOUNT}..."
  mount -t cifs "//${BACKUP_NAS}${BACKUP_SHARE}" "${BACKUP_MOUNT}" -o credentials="${BACKUP_CREDENTIALS}"
  BACKUP_MOUNTED_BY_SCRIPT=1
}


prune_old_backup_snapshots() {
  local snapshots=()
  local remove_count=0
  local snapshot=""

  mapfile -t snapshots < <(zfs list -H -t snapshot -o name -s creation | grep "^${POOL_NAME}@backup-" || true)
  remove_count=$(( ${#snapshots[@]} - BACKUP_KEEP_COUNT ))
  if (( remove_count <= 0 )); then
    return 0
  fi

  for snapshot in "${snapshots[@]:0:remove_count}"; do
    info "Pruning old snapshot ${snapshot}..."
    zfs destroy -r "${snapshot}"
  done
}


prune_old_backup_files() {
  local entries=()
  local remove_count=0
  local entry=""
  local file_path=""

  mapfile -t entries < <(find "${BACKUP_MOUNT}" -maxdepth 1 -name "${BACKUP_FILE_GLOB}" -type f -printf '%T@\t%p\n' 2>/dev/null | sort -n)
  remove_count=$(( ${#entries[@]} - BACKUP_KEEP_COUNT ))
  if (( remove_count <= 0 )); then
    return 0
  fi

  for entry in "${entries[@]:0:remove_count}"; do
    file_path="${entry#*$'\t'}"
    info "Pruning old backup file ${file_path}..."
    rm -f -- "${file_path}"
  done
}


sync_backup_to_cloud() {
  local backup_file="$1"
  local sync_start=0
  local sync_end=0
  local sync_duration=0
  local sync_size=0
  local sync_speed=""

  if ! command -v rclone >/dev/null 2>&1; then
    warn "rclone not found; skipping cloud sync."
    return 0
  fi

  sync_start="$(date +%s)"
  if rclone sync "${BACKUP_MOUNT}/" "${CLOUD_SYNC_TARGET}" --include "${BACKUP_FILE_GLOB}"; then
    sync_end="$(date +%s)"
    sync_duration=$(( sync_end - sync_start ))
    sync_size="$(stat -c '%s' "${backup_file}")"
    if (( sync_duration > 0 )); then
      sync_speed="$(awk -v size="${sync_size}" -v dur="${sync_duration}" 'BEGIN {printf "%.2f", (size * 8) / dur / 1000000000}')"
      info "Cloud sync complete: ${sync_duration}s @ ${sync_speed} Gbps"
    else
      info "Cloud sync complete."
    fi
    return 0
  fi

  warn "Cloud sync failed."
}


run_backup() {
  local timestamp=""
  local snapshot=""
  local backup_file=""
  local backup_size=""

  trap cleanup_backup_mount EXIT
  mount_backup_target

  timestamp="$(date +%Y%m%d-%H%M%S)"
  snapshot="${POOL_NAME}@backup-${timestamp}"
  backup_file="${BACKUP_MOUNT}/precision-${timestamp}.zfs.zst"

  info "Creating recursive snapshot ${snapshot}..."
  zfs snapshot -r "${snapshot}"

  info "Writing compressed backup stream to ${backup_file}..."
  zfs send -R "${snapshot}" | zstd -T0 > "${backup_file}"

  [[ -s "${backup_file}" ]] || fatal "Backup file was created but is empty: ${backup_file}"
  zstd -t "${backup_file}"
  backup_size="$(du -h "${backup_file}" | awk '{print $1}')"
  info "Backup archive verified: ${backup_size}"

  prune_old_backup_snapshots
  prune_old_backup_files
  # Intentionally mirror the retained NAS backup window to the cloud target.
  sync_backup_to_cloud "${backup_file}"
  cleanup_backup_mount
  trap - EXIT
}


backup_timestamp_from_path() {
  local backup_path="$1"
  local backup_name=""

  backup_name="$(basename -- "${backup_path}")"
  [[ "${backup_name}" == precision-*.zfs.zst ]] || fatal "Backup file name does not match expected pattern: ${backup_name}"
  backup_name="${backup_name#precision-}"
  printf '%s\n' "${backup_name%.zfs.zst}"
}


verify_backup_archive() {
  local backup_path="$1"

  [[ -f "${backup_path}" ]] || fatal "Backup archive does not exist: ${backup_path}"
  [[ -s "${backup_path}" ]] || fatal "Backup archive is empty: ${backup_path}"

  info "Verifying backup archive ${backup_path}..."
  zstd -t "${backup_path}"
}


choose_backup_archive() {
  local entries=()
  local entry=""
  local choice=""
  local choice_index=0
  local display_index=0
  local backup_name=""
  local backup_path=""

  mapfile -t entries < <(find "${BACKUP_MOUNT}" -maxdepth 1 -name "${BACKUP_FILE_GLOB}" -type f -printf '%f\t%p\n' 2>/dev/null | sort -r)
  (( ${#entries[@]} > 0 )) || fatal "No backup archives were found under ${BACKUP_MOUNT}."

  printf 'Available backups (newest first):\n' >&2
  for entry in "${entries[@]}"; do
    backup_name="${entry%%$'\t'*}"
    display_index=$(( display_index + 1 ))
    printf '  %d) %s\n' "${display_index}" "${backup_name}" >&2
  done

  while true; do
    printf 'Select backup number to restore: ' >&2
    read -r choice
    [[ "${choice}" =~ ^[0-9]+$ ]] || {
      warn "Enter a numeric selection."
      continue
    }

    choice_index=$(( choice - 1 ))
    if (( choice_index < 0 || choice_index >= ${#entries[@]} )); then
      warn "Selection out of range."
      continue
    fi

    backup_path="${entries[choice_index]#*$'\t'}"
    printf '%s\n' "${backup_path}"
    return 0
  done
}


confirm_restore_data() {
  local backup_path="$1"

  if (( ASSUME_YES == 1 )); then
    return 0
  fi

  printf 'This will overwrite the contents of pool %s using:\n' "${POOL_NAME}"
  printf '  %s\n' "${backup_path}"
  printf "Type 'restore' to continue: "
  local answer=""
  read -r answer
  [[ "${answer}" == "restore" ]] || fatal "Aborted."
}


import_pool_for_recovery() {
  local current_altroot=""

  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    current_altroot="$(zpool get -H -o value altroot "${POOL_NAME}" 2>/dev/null || true)"
    [[ "${current_altroot}" == "${RECOVERY_ROOT}" ]] || \
      fatal "Pool ${POOL_NAME} is already imported without altroot ${RECOVERY_ROOT}. Export it first or re-import it for recovery."
    return 0
  fi

  info "Importing pool ${POOL_NAME} for recovery..."
  zpool import -N -R "${RECOVERY_ROOT}" -d /dev/disk/by-id "${POOL_NAME}"
}


destroy_existing_pool_datasets() {
  local datasets=()
  local index=0

  mapfile -t datasets < <(zfs list -H -o name -r "${POOL_NAME}" 2>/dev/null | tail -n +2 || true)
  if (( ${#datasets[@]} == 0 )); then
    return 0
  fi

  info "Destroying existing datasets in ${POOL_NAME} before restore..."
  for (( index=${#datasets[@]} - 1; index>=0; index-- )); do
    zfs destroy -r "${datasets[index]}"
  done
}


destroy_existing_pool_snapshots() {
  local snapshots=()
  local index=0

  mapfile -t snapshots < <(zfs list -H -t snapshot -o name -s creation -r "${POOL_NAME}" 2>/dev/null || true)
  if (( ${#snapshots[@]} == 0 )); then
    return 0
  fi

  info "Destroying existing snapshots in ${POOL_NAME} before restore..."
  for (( index=${#snapshots[@]} - 1; index>=0; index-- )); do
    zfs destroy "${snapshots[index]}"
  done
}


verify_restored_snapshot() {
  local backup_path="$1"
  local expected_snapshot=""
  local timestamp=""

  timestamp="$(backup_timestamp_from_path "${backup_path}")"
  expected_snapshot="${POOL_NAME}@backup-${timestamp}"
  zfs list -H -t snapshot -o name "${expected_snapshot}" >/dev/null 2>&1 || fatal "Expected restored snapshot is missing: ${expected_snapshot}"
}


run_restore_data() {
  local backup_path=""

  require_live_environment
  # Trap covers NAS unmount only. If dataset destruction fails mid-loop, the pool
  # is left partially destroyed; zfs receive -F on retry handles that correctly.
  trap cleanup_backup_mount EXIT

  mount_backup_target
  backup_path="$(choose_backup_archive)"
  confirm_restore_data "${backup_path}"
  verify_backup_archive "${backup_path}"

  import_pool_for_recovery
  destroy_existing_pool_snapshots
  destroy_existing_pool_datasets

  info "Receiving backup stream from ${backup_path} into ${POOL_NAME}..."
  zstd -d -c "${backup_path}" | zfs receive -u -F "${POOL_NAME}"

  verify_restored_snapshot "${backup_path}"
  run_check_layout || fatal "Restore completed, but verification still reports mismatches."
  cleanup_backup_mount
  trap - EXIT
  info "Restore data completed and verified."
}


mount_recovery_root_dataset() {
  local mounted_source=""
  local datasets=()
  local dataset=""
  local canmount=""
  local mountpoint_value=""
  local mounted_value=""

  import_pool_for_recovery
  mkdir -p "${RECOVERY_ROOT}"
  mounted_source="$(findmnt -rn -o SOURCE --target "${RECOVERY_ROOT}" 2>/dev/null || true)"
  if [[ "${mounted_source}" != "${ROOT_DATASET}" ]]; then
    info "Mounting restored root dataset at ${RECOVERY_ROOT}..."
    zfs mount "${ROOT_DATASET}"
  fi

  mapfile -t datasets < <(zfs list -H -o name -r "${POOL_NAME}" 2>/dev/null || true)
  for dataset in "${datasets[@]}"; do
    [[ "${dataset}" == "${POOL_NAME}" || "${dataset}" == "${ROOT_DATASET}" ]] && continue
    canmount="$(zfs_dataset_value "${dataset}" canmount)"
    mountpoint_value="$(zfs_dataset_value "${dataset}" mountpoint)"
    mounted_value="$(zfs_dataset_value "${dataset}" mounted)"
    [[ "${canmount}" == "off" ]] && continue
    [[ "${mountpoint_value}" == "none" || "${mountpoint_value}" == "legacy" ]] && continue
    [[ "${mounted_value}" == "yes" ]] && continue
    zfs mount "${dataset}"
  done
}


mount_recovery_boot_filesystems() {
  mkdir -p "${RECOVERY_ROOT}/boot/efi"

  if ! mountpoint -q "${RECOVERY_ROOT}/boot"; then
    info "Mounting /boot recovery filesystem..."
    mount /dev/md/boot "${RECOVERY_ROOT}/boot"
  fi

  if ! mountpoint -q "${RECOVERY_ROOT}/boot/efi"; then
    info "Mounting /boot/efi recovery filesystem..."
    mount /dev/md/efi "${RECOVERY_ROOT}/boot/efi"
  fi
}


mount_recovery_chroot_support() {
  mkdir -p \
    "${RECOVERY_ROOT}/dev" \
    "${RECOVERY_ROOT}/dev/pts" \
    "${RECOVERY_ROOT}/proc" \
    "${RECOVERY_ROOT}/sys" \
    "${RECOVERY_ROOT}/run"

  mountpoint -q "${RECOVERY_ROOT}/dev" || mount --bind /dev "${RECOVERY_ROOT}/dev"
  mountpoint -q "${RECOVERY_ROOT}/dev/pts" || mount --bind /dev/pts "${RECOVERY_ROOT}/dev/pts"
  mountpoint -q "${RECOVERY_ROOT}/proc" || mount --bind /proc "${RECOVERY_ROOT}/proc"
  mountpoint -q "${RECOVERY_ROOT}/sys" || mount --bind /sys "${RECOVERY_ROOT}/sys"
  mountpoint -q "${RECOVERY_ROOT}/run" || mount --bind /run "${RECOVERY_ROOT}/run"
}


cleanup_recovery_chroot_mounts() {
  umount "${RECOVERY_ROOT}/run" 2>/dev/null || true
  umount "${RECOVERY_ROOT}/sys" 2>/dev/null || true
  umount "${RECOVERY_ROOT}/proc" 2>/dev/null || true
  umount "${RECOVERY_ROOT}/dev/pts" 2>/dev/null || true
  umount "${RECOVERY_ROOT}/dev" 2>/dev/null || true
  umount "${RECOVERY_ROOT}/boot/efi" 2>/dev/null || true
  umount "${RECOVERY_ROOT}/boot" 2>/dev/null || true
}


cleanup_recovery_pool_mounts() {
  local datasets=()
  local dataset=""
  local mounted_value=""
  local index=0

  mapfile -t datasets < <(zfs list -H -o name -r "${POOL_NAME}" 2>/dev/null || true)
  if (( ${#datasets[@]} == 0 )); then
    return 0
  fi

  for (( index=${#datasets[@]} - 1; index>=0; index-- )); do
    dataset="${datasets[index]}"
    mounted_value="$(zfs_dataset_value "${dataset}" mounted)"
    [[ "${mounted_value}" == "yes" ]] || continue
    zfs unmount -f "${dataset}" 2>/dev/null || true
  done
}


export_recovery_pool() {
  info "Exporting pool ${POOL_NAME}..."
  zpool export -f "${POOL_NAME}"
}


run_in_recovery_chroot() {
  chroot "${RECOVERY_ROOT}" /usr/bin/env bash -lc "$*"
}


write_recovery_fstab() {
  local boot_uuid=""
  local efi_uuid=""
  local swap_uuid=""

  boot_uuid="$(blkid_value /dev/md/boot UUID)"
  efi_uuid="$(blkid_value /dev/md/efi UUID)"
  swap_uuid="$(blkid_value /dev/md/swap UUID)"

  [[ -n "${boot_uuid}" ]] || fatal "Unable to determine UUID for /dev/md/boot"
  [[ -n "${efi_uuid}" ]] || fatal "Unable to determine UUID for /dev/md/efi"
  [[ -n "${swap_uuid}" ]] || fatal "Unable to determine UUID for /dev/md/swap"

  cat > "${RECOVERY_ROOT}/etc/fstab" <<EOF
# /etc/fstab - static file system information
# Rewritten by ${SCRIPT_NAME} during repair-boot

# Boot partition (mdadm RAID1 + ext4)
UUID=${boot_uuid}  /boot      ext4  defaults,noatime,nofail  0  1

# EFI partition (mdadm RAID1 + FAT32)
UUID=${efi_uuid}   /boot/efi  vfat  defaults,noatime,nofail,umask=0077  0  1

# Swap (mdadm RAID0)
UUID=${swap_uuid}  none       swap  sw,nofail  0  0
EOF
}


write_recovery_mdadm_conf() {
  local md_scan=""
  local filtered_md_scan=""

  md_scan="$(mdadm --detail --scan)"
  filtered_md_scan="$(grep -E '^ARRAY /dev/md/(efi|boot|swap) ' <<<"${md_scan}" || true)"
  [[ -n "${filtered_md_scan}" ]] || fatal "Expected md arrays were not found in mdadm --detail --scan output."
  cat > "${RECOVERY_ROOT}/etc/mdadm/mdadm.conf" <<EOF
# mdadm.conf - Configuration for mdadm RAID arrays
# Rewritten by ${SCRIPT_NAME} during repair-boot

HOMEHOST <system>
MAILADDR root

# RAID array definitions
${filtered_md_scan}
EOF
}


set_recovery_zpool_cachefile() {
  mkdir -p "${RECOVERY_ROOT}/etc/zfs"
  run_in_recovery_chroot "zpool set cachefile=/etc/zfs/zpool.cache ${POOL_NAME}"
}


require_recovery_command() {
  local cmd="$1"

  run_in_recovery_chroot "command -v $(printf '%q' "${cmd}") >/dev/null 2>&1" || fatal "Required command is missing inside the restored system: ${cmd}"
}


list_installed_recovery_kernel_packages() {
  # dpkg-query emits "<package>\t<want> <error> <status>"; the awk filter
  # selects only fully installed linux-image packages.
  # shellcheck disable=SC2016
  local dpkg_format='${binary:Package}\t${Status}\n'

  chroot "${RECOVERY_ROOT}" dpkg-query -W -f="${dpkg_format}" 'linux-image-[0-9]*' 2>/dev/null | \
    awk '$2 == "install" && $3 == "ok" && $4 == "installed" {print $1}'
}


reinstall_recovery_kernel_packages() {
  local kernel_packages=()
  local cached_kernel_debs=()
  local package_name=""
  local package_version=""
  local package_arch=""
  local expected_deb=""
  local all_cached=1
  local dpkg_format=""

  mapfile -t kernel_packages < <(list_installed_recovery_kernel_packages)
  (( ${#kernel_packages[@]} > 0 )) || fatal "No installed linux-image packages were found in the restored system."

  # shellcheck disable=SC2016
  dpkg_format='${Version}\t${Architecture}\n'

  for package_name in "${kernel_packages[@]}"; do
    read -r package_version package_arch < <(
      chroot "${RECOVERY_ROOT}" dpkg-query -W -f="${dpkg_format}" "${package_name}" 2>/dev/null
    )
    [[ -n "${package_version}" && -n "${package_arch}" ]] || fatal "Unable to determine version/architecture for restored package ${package_name}."
    local encoded_version="${package_version//:/%3a}"
    expected_deb="${RECOVERY_ROOT}/var/cache/apt/archives/${package_name}_${encoded_version}_${package_arch}.deb"
    if [[ -f "${expected_deb}" ]]; then
      cached_kernel_debs+=("/var/cache/apt/archives/${package_name}_${encoded_version}_${package_arch}.deb")
    else
      all_cached=0
      break
    fi
  done

  if (( all_cached == 1 )); then
    info "Reinstalling restored kernel packages from local apt cache to repopulate /boot..."
    chroot "${RECOVERY_ROOT}" dpkg -i "${cached_kernel_debs[@]}"
    return 0
  fi

  info "Refreshing apt metadata inside the restored system..."
  chroot "${RECOVERY_ROOT}" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update || \
    fatal "Unable to refresh apt metadata inside the restored system, and required kernel packages were not present in the local apt cache."

  info "Reinstalling restored kernel packages to repopulate /boot..."
  chroot "${RECOVERY_ROOT}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --reinstall "${kernel_packages[@]}"
}


rebuild_recovery_boot_configuration() {
  info "Rebuilding initramfs for all installed kernels..."
  run_in_recovery_chroot "update-initramfs -u -k all"

  info "Regenerating GRUB configuration..."
  run_in_recovery_chroot "update-grub"

  info "Installing GRUB EFI files into the mirrored EFI filesystem..."
  run_in_recovery_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck"
  run_in_recovery_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --removable --recheck"
}


verify_recovery_boot_artifacts() {
  [[ -L "${RECOVERY_ROOT}/boot/vmlinuz" ]] || fatal "Missing /boot/vmlinuz symlink after repair."
  [[ -L "${RECOVERY_ROOT}/boot/initrd.img" ]] || fatal "Missing /boot/initrd.img symlink after repair."
  [[ -s "${RECOVERY_ROOT}/boot/grub/grub.cfg" ]] || fatal "Missing /boot/grub/grub.cfg after repair."
  [[ -s "${RECOVERY_ROOT}/boot/efi/EFI/ubuntu/shimx64.efi" ]] || fatal "Missing EFI ubuntu shim after repair."
  [[ -s "${RECOVERY_ROOT}/boot/efi/EFI/BOOT/BOOTX64.EFI" ]] || fatal "Missing fallback EFI bootloader after repair."
}


run_repair_boot() {
  require_live_environment
  trap 'cleanup_recovery_chroot_mounts; cleanup_recovery_pool_mounts' EXIT

  import_pool_for_recovery
  run_check_layout || fatal "repair-boot requires a valid rebuilt/restored layout first."
  mount_recovery_root_dataset
  mount_recovery_boot_filesystems
  mount_recovery_chroot_support

  info "Rewriting restored system fstab and mdadm.conf..."
  write_recovery_fstab
  write_recovery_mdadm_conf

  require_recovery_command bash
  require_recovery_command zpool
  require_recovery_command apt-get
  require_recovery_command dpkg-query
  require_recovery_command dpkg
  require_recovery_command update-initramfs
  require_recovery_command update-grub
  require_recovery_command grub-install

  info "Refreshing zpool cache inside the restored system..."
  set_recovery_zpool_cachefile

  reinstall_recovery_kernel_packages
  rebuild_recovery_boot_configuration
  verify_recovery_boot_artifacts

  cleanup_recovery_chroot_mounts
  cleanup_recovery_pool_mounts
  export_recovery_pool
  trap - EXIT
  info "Boot repair completed and verified."
}


run_full_restore() {
  require_live_environment

  if check_layout; then
    info "Storage layout already matches the expected semantic scaffold. Skipping rebuild."
  else
    run_rebuild_layout
  fi

  run_restore_data
  run_repair_boot
  info "Full restore completed."
}


check_layout() {
  local disk1_real=""
  local disk2_real=""
  local disk3_real=""

  CHECK_FAILED=0
  disk1_real="$(real_disk_path "${DISK1}")"
  disk2_real="$(real_disk_path "${DISK2}")"
  disk3_real="$(real_disk_path "${DISK3}")"

  check_partition_dump "${disk1_real}" \
    "$(part_path "${disk1_real}" 1)|start=        2048|size=     1048576|type=${TYPE_EFI}|name=\"EFI1\"" \
    "$(part_path "${disk1_real}" 2)|start=     1050624|size=     4194304|type=${TYPE_LINUX_RAID}|name=\"BOOT1\"" \
    "$(part_path "${disk1_real}" 3)|start=     5244928|size=     8388608|type=${TYPE_LINUX_RAID}|name=\"SWAP1\"" \
    "$(part_path "${disk1_real}" 4)|start=    13633536|type=${TYPE_ZFS}|name=\"ZFS1\""

  check_partition_dump "${disk2_real}" \
    "$(part_path "${disk2_real}" 1)|start=        2048|size=     1048576|type=${TYPE_EFI}|name=\"EFI2\"" \
    "$(part_path "${disk2_real}" 2)|start=     1050624|size=     4194304|type=${TYPE_LINUX_RAID}|name=\"BOOT2\"" \
    "$(part_path "${disk2_real}" 3)|start=     5244928|size=     8388608|type=${TYPE_LINUX_RAID}|name=\"SWAP2\"" \
    "$(part_path "${disk2_real}" 4)|start=    13633536|type=${TYPE_ZFS}|name=\"ZFS2\""

  check_partition_dump "${disk3_real}" \
    "$(part_path "${disk3_real}" 1)|start=        2048|size=     8388608|type=${TYPE_LINUX_RAID}|name=\"SWAP3\"" \
    "$(part_path "${disk3_real}" 2)|start=     8390656|type=${TYPE_ZFS}|name=\"ZFS3\""

  check_mdadm_array "/dev/md/efi" "1.0" "raid1" "2" "any:efi" \
    "$(part_path "${disk1_real}" 1)" "$(part_path "${disk2_real}" 1)"
  check_mdadm_array "/dev/md/boot" "1.0" "raid1" "2" "any:boot" \
    "$(part_path "${disk1_real}" 2)" "$(part_path "${disk2_real}" 2)"
  check_mdadm_array "/dev/md/swap" "1.2" "raid0" "3" "any:swap" \
    "$(part_path "${disk1_real}" 3)" "$(part_path "${disk2_real}" 3)" "$(part_path "${disk3_real}" 1)"

  check_filesystem_signature "/dev/md/efi" "vfat" "EFI"
  check_filesystem_signature "/dev/md/boot" "ext4" "boot"
  check_filesystem_signature "/dev/md/swap" "swap" "swap"

  check_zpool_members
  check_zpool_property "bootfs" "${ROOT_DATASET}"
  check_zpool_property "autotrim" "on"
  check_zpool_property "ashift" "12"

  check_dataset_scaffold

  return "${CHECK_FAILED}"
}


destroy_or_export_pool() {
  if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
    zpool export -f "${POOL_NAME}" 2>/dev/null || zpool destroy -f "${POOL_NAME}" 2>/dev/null || true
  fi
}


stop_existing_arrays() {
  local md_device=""
  local md_detail=""
  local md_name=""

  swapoff /dev/md/swap 2>/dev/null || true
  mdadm --stop /dev/md/efi 2>/dev/null || true
  mdadm --stop /dev/md/boot 2>/dev/null || true
  mdadm --stop /dev/md/swap 2>/dev/null || true
  mdadm --remove /dev/md/efi 2>/dev/null || true
  mdadm --remove /dev/md/boot 2>/dev/null || true
  mdadm --remove /dev/md/swap 2>/dev/null || true

  for md_device in /dev/md[0-9]*; do
    [[ -b "${md_device}" ]] || continue
    md_detail="$(mdadm --detail "${md_device}" 2>/dev/null || true)"
    [[ -n "${md_detail}" ]] || continue
    md_name="$(awk -F': ' '/^[[:space:]]+Name : / {print $2}' <<<"${md_detail}")"
    if grep -qF "${DISK1}" <<<"${md_detail}" || \
       grep -qF "${DISK2}" <<<"${md_detail}" || \
       grep -qF "${DISK3}" <<<"${md_detail}" || \
       [[ "${md_name}" =~ ^any:(efi|boot|swap)$ ]]; then
      mdadm --stop "${md_device}" 2>/dev/null || true
      mdadm --remove "${md_device}" 2>/dev/null || true
    fi
  done
}


wait_for_block_devices() {
  local expected_devices=("$@")
  local device=""
  local remaining_checks=20
  local missing_device=0

  udevadm settle
  while (( remaining_checks > 0 )); do
    missing_device=0
    for device in "${expected_devices[@]}"; do
      if [[ ! -b "${device}" ]]; then
        missing_device=1
        break
      fi
    done
    if (( missing_device == 0 )); then
      return 0
    fi
    sleep 0.2
    ((remaining_checks-=1))
  done

  fatal "Timed out waiting for expected block devices: ${expected_devices[*]}"
}


zero_superblocks() {
  local member=""
  for member in \
    "${DISK1}-part1" "${DISK1}-part2" "${DISK1}-part3" \
    "${DISK2}-part1" "${DISK2}-part2" "${DISK2}-part3" \
    "${DISK3}-part1"
  do
    mdadm --zero-superblock "${member}" 2>/dev/null || true
  done
}


wipe_target_disks() {
  local disk=""
  for disk in "${DISK1}" "${DISK2}" "${DISK3}"; do
    wipefs -af "${disk}" 2>/dev/null || true
    sgdisk --zap-all "${disk}"
    blkdiscard -f "${disk}" 2>/dev/null || true
  done
}


partition_target_disks() {
  sgdisk \
    -n1:1M:+512M -t1:EF00 -c1:EFI1 \
    -n2:0:+2G    -t2:FD00 -c2:BOOT1 \
    -n3:0:+4G    -t3:FD00 -c3:SWAP1 \
    -n4:0:0      -t4:BF00 -c4:ZFS1 \
    "${DISK1}"

  sgdisk \
    -n1:1M:+512M -t1:EF00 -c1:EFI2 \
    -n2:0:+2G    -t2:FD00 -c2:BOOT2 \
    -n3:0:+4G    -t3:FD00 -c3:SWAP2 \
    -n4:0:0      -t4:BF00 -c4:ZFS2 \
    "${DISK2}"

  sgdisk \
    -n1:1M:+4G -t1:FD00 -c1:SWAP3 \
    -n2:0:0    -t2:BF00 -c2:ZFS3 \
    "${DISK3}"

  partprobe "${DISK1}" "${DISK2}" "${DISK3}"
  wait_for_block_devices \
    "${DISK1}-part1" "${DISK1}-part2" "${DISK1}-part3" "${DISK1}-part4" \
    "${DISK2}-part1" "${DISK2}-part2" "${DISK2}-part3" "${DISK2}-part4" \
    "${DISK3}-part1" "${DISK3}-part2"
}


create_arrays() {
  mdadm --create /dev/md/efi \
    --level=1 \
    --raid-devices=2 \
    --metadata=1.0 \
    --bitmap=internal \
    --homehost=any \
    --name=efi \
    --run \
    "${DISK1}-part1" "${DISK2}-part1"

  mdadm --create /dev/md/boot \
    --level=1 \
    --raid-devices=2 \
    --metadata=1.0 \
    --bitmap=internal \
    --homehost=any \
    --name=boot \
    --run \
    "${DISK1}-part2" "${DISK2}-part2"

  mdadm --create /dev/md/swap \
    --level=0 \
    --raid-devices=3 \
    --metadata=1.2 \
    --chunk=512 \
    --homehost=any \
    --name=swap \
    --run \
    "${DISK1}-part3" "${DISK2}-part3" "${DISK3}-part1"

  wait_for_block_devices /dev/md/efi /dev/md/boot /dev/md/swap
}


format_arrays() {
  mkfs.vfat -F 32 -n EFI /dev/md/efi
  mkfs.ext4 -F -L boot /dev/md/boot
  mkswap -L swap /dev/md/swap
}


create_pool_and_datasets() {
  mkdir -p "${RECOVERY_ROOT}"

  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posix \
    -O xattr=sa \
    -O dnodesize=auto \
    -O compression=zstd \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=none \
    -R "${RECOVERY_ROOT}" \
    "${POOL_NAME}" \
    raidz1 \
    "${DISK1}-part4" "${DISK2}-part4" "${DISK3}-part2"

  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/ROOT"
  zfs create -o canmount=noauto -o mountpoint=/ "${ROOT_DATASET}"
  zfs create -o mountpoint=/home "${POOL_NAME}/home"
  zfs create -o mountpoint=/home/me/Downloads -o compression=off "${POOL_NAME}/home/Downloads"
  zfs create -o mountpoint=/srv "${POOL_NAME}/srv"
  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/var"
  zfs create -o mountpoint=/var/cache -o com.sun:auto-snapshot=false "${POOL_NAME}/var/cache"
  zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/var/lib"
  zfs create -o mountpoint=none "${POOL_NAME}/var/lib/docker"
  zfs create -o mountpoint=/var/log "${POOL_NAME}/var/log"
  zfs create -o mountpoint=/var/tmp -o com.sun:auto-snapshot=false "${POOL_NAME}/var/tmp"

  zpool set bootfs="${ROOT_DATASET}" "${POOL_NAME}"
}


confirm_rebuild() {
  if (( ASSUME_YES == 1 )); then
    return 0
  fi

  printf 'This will destroy and recreate the target storage layout on:\n'
  printf '  %s\n' "${DISK1}" "${DISK2}" "${DISK3}"
  printf "Type 'rebuild' to continue: "
  local answer=""
  read -r answer
  [[ "${answer}" == "rebuild" ]] || fatal "Aborted."
}


run_check_layout() {
  if check_layout; then
    info "Storage layout already matches the expected semantic scaffold."
    return 0
  fi

  error "Storage layout does not match the expected semantic scaffold."
  return 1
}


run_rebuild_layout() {
  require_live_environment
  confirm_rebuild

  info "Destroying any existing imported pool and md arrays..."
  destroy_or_export_pool
  stop_existing_arrays
  zero_superblocks

  info "Wiping target disks..."
  wipe_target_disks

  info "Partitioning target disks..."
  partition_target_disks

  info "Creating mdraid arrays..."
  create_arrays

  info "Formatting mdraid arrays..."
  format_arrays

  info "Creating ZFS pool and dataset scaffold..."
  create_pool_and_datasets

  run_check_layout || fatal "Rebuild completed, but verification still reports mismatches."
  info "Storage layout rebuilt and verified."
}


parse_args() {
  [[ $# -gt 0 ]] || {
    usage
    exit 1
  }

  case "$1" in
    check-layout|check)
      MODE="check-layout"
      ;;
    rebuild-layout|apply)
      MODE="rebuild-layout"
      ;;
    backup|restore-data|repair-boot|full-restore)
      MODE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fatal "Unknown mode: $1"
      ;;
  esac
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk1)
        shift
        [[ $# -gt 0 ]] || fatal "--disk1 requires a value"
        DISK1="$1"
        ;;
      --disk2)
        shift
        [[ $# -gt 0 ]] || fatal "--disk2 requires a value"
        DISK2="$1"
        ;;
      --disk3)
        shift
        [[ $# -gt 0 ]] || fatal "--disk3 requires a value"
        DISK3="$1"
        ;;
      --yes)
        ASSUME_YES=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fatal "Unknown argument: $1"
        ;;
    esac
    shift
  done
}


require_mode_commands() {
  require_command awk
  require_command basename
  require_command grep
  require_command mkdir
  require_command paste
  require_command readlink
  require_command rm
  require_command sort

  require_command zpool
  require_command zfs

  if [[ "${MODE}" == "backup" || "${MODE}" == "full-restore" ]]; then
    require_command du
    require_command mount
    require_command mount.cifs
    require_command mountpoint
    require_command stat
    require_command umount
    require_command zstd
    require_command find
  fi

  if [[ "${MODE}" == "restore-data" || "${MODE}" == "full-restore" ]]; then
    require_command mount
    require_command mount.cifs
    require_command mountpoint
    require_command umount
    require_command zstd
    require_command find
    require_command sfdisk
    require_command mdadm
    require_command blkid
    require_command tail
  fi

  if [[ "${MODE}" == "repair-boot" || "${MODE}" == "full-restore" ]]; then
    require_command apt-get
    require_command blkid
    require_command chroot
    require_command dpkg-query
    require_command findmnt
    require_command mdadm
    require_command mount
    require_command mountpoint
    require_command umount
    require_command update-initramfs
    require_command update-grub
    require_command grub-install
  fi

  if [[ "${MODE}" == "check-layout" || "${MODE}" == "rebuild-layout" || "${MODE}" == "full-restore" ]]; then
    require_command sfdisk
    require_command mdadm
    require_command blkid
  fi

  if [[ "${MODE}" == "rebuild-layout" || "${MODE}" == "full-restore" ]]; then
    require_command blkdiscard
    require_command sgdisk
    require_command mkfs.vfat
    require_command mkfs.ext4
    require_command mkswap
    require_command partprobe
    require_command sleep
    require_command swapoff
    require_command udevadm
  fi
}


dispatch_mode() {
  case "${MODE}" in
    backup)
      run_backup
      ;;
    check-layout)
      run_check_layout
      ;;
    rebuild-layout)
      if check_layout; then
        info "Storage layout already matches the expected semantic scaffold."
        return 0
      fi
      run_rebuild_layout
      ;;
    restore-data)
      run_restore_data
      ;;
    repair-boot)
      run_repair_boot
      ;;
    full-restore)
      run_full_restore
      ;;
    *)
      fatal "Unhandled mode: ${MODE}"
      ;;
  esac
}


main() {
  parse_args "$@"
  require_root
  validate_by_id_disk "${DISK1}"
  validate_by_id_disk "${DISK2}"
  validate_by_id_disk "${DISK3}"
  validate_distinct_disks
  require_mode_commands
  dispatch_mode
}


main "$@"

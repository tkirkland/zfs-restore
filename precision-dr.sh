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


not_implemented() {
  fatal "${MODE} is scaffolded but not implemented yet."
}


usage() {
  cat <<EOF
Usage:
  sudo ./${SCRIPT_NAME} <mode> [options]

Implemented modes:
  check-layout     Verify that the target storage layout already matches the
                   expected restore-ready scaffold.
  rebuild-layout   Destructively recreate that scaffold in a live OS.

Planned modes:
  backup
  restore-data
  repair-boot
  full-restore

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
  - Current implementation covers storage verification/rebuild only.
  - It does not currently restore ZFS data.
  - It does not currently restore or repair bootability.
  - Semantic equivalence is the contract; exact UUID/GUID recreation is not.
EOF
}


require_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "Run this script as root."
}


require_live_environment() {
  if [[ ! -d /cdrom ]] && [[ ! -d /run/live ]]; then
    fatal "rebuild-layout is restricted to a live OS environment."
  fi
}


require_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fatal "Required command not found: ${cmd}"
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
  local dump=""
  local expected_partition_count="$#"
  local actual_partition_count=0
  local spec=""
  local spec_line=""
  local fragment=""
  local matched=0

  dump="$(sfdisk -d "${disk_real}")"
  expect_line_present "${dump}" "label: gpt" "${disk_real} partition label"
  expect_line_present "${dump}" "device: ${disk_real}" "${disk_real} device path"
  actual_partition_count="$(grep -c "^${disk_real}p[0-9]" <<<"${dump}" || true)"
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
    done < <(grep "^${disk_real}p[0-9]" <<<"${dump}" || true)

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

  if [[ "${raid_level}" == "raid0" ]]; then
    actual_members="$(awk '/active sync/ {print $NF}' <<<"${detail}" | sort | paste -sd',' -)"
    expected_members_joined="$(printf '%s\n' "${expected_members[@]}" | sort | paste -sd',' -)"
  else
    actual_members="$(awk '/active sync/ {print $NF}' <<<"${detail}" | paste -sd',' -)"
    expected_members_joined="$(printf '%s\n' "${expected_members[@]}" | paste -sd',' -)"
  fi
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

  actual_members="$(awk '/\/dev\/disk\/by-id\// {print $1}' <<<"${status}" | paste -sd',' -)"
  expected_members_joined="$(printf '%s\n' \
    "${DISK1}-part4" \
    "${DISK2}-part4" \
    "${DISK3}-part2" | paste -sd',' -)"
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
  swapoff /dev/md/swap 2>/dev/null || true
  mdadm --stop /dev/md/efi 2>/dev/null || true
  mdadm --stop /dev/md/boot 2>/dev/null || true
  mdadm --stop /dev/md/swap 2>/dev/null || true
  mdadm --stop /dev/md125 2>/dev/null || true
  mdadm --stop /dev/md126 2>/dev/null || true
  mdadm --stop /dev/md127 2>/dev/null || true
  mdadm --remove /dev/md/efi 2>/dev/null || true
  mdadm --remove /dev/md/boot 2>/dev/null || true
  mdadm --remove /dev/md/swap 2>/dev/null || true
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
  udevadm settle
  sleep 2
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

  udevadm settle
  sleep 2
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
  require_command sfdisk
  require_command mdadm
  require_command blkid
  require_command zpool
  require_command zfs

  if [[ "${MODE}" == "rebuild-layout" ]]; then
    require_command sgdisk
    require_command mkfs.vfat
    require_command mkfs.ext4
    require_command mkswap
    require_command partprobe
    require_command udevadm
  fi
}


dispatch_mode() {
  case "${MODE}" in
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
    backup|restore-data|repair-boot|full-restore)
      not_implemented
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

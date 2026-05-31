# Project Index: precision-zfs-dr

Generated: 2026-05-24

## Project Structure

```
rebuild-drv-layout/
├── precision-zfs-dr.sh     # Unified DR script (entry point)
├── tests/
│   └── test-command-checks.sh
├── README.md               # Architecture and design decisions
├── AGENTS.md               # AI agent rules for this repo
└── PURPOSE.md              # Project purpose note
```

## Entry Point

**`precision-zfs-dr.sh`** — 1,546 lines, 79 functions, requires root

```
sudo ./precision-zfs-dr.sh <mode> [options]
```

### Modes

| Mode | Description |
|---|---|
| `backup` | Recursive ZFS snapshot → compressed stream → NAS; retention; cloud sync |
| `check-layout` | Verify storage scaffold (alias: `check`) |
| `rebuild-layout` | Destructively recreate storage scaffold (alias: `apply`) |
| `restore-data` | Mount NAS, choose archive, receive ZFS stream into pool |
| `repair-boot` | Chroot into restored system; rebuild initramfs, GRUB, EFI |
| `full-restore` | Orchestrates: rebuild-layout → restore-data → repair-boot |

### Options

| Flag | Default | Description |
|---|---|---|
| `--disk1 <by-id>` | nvme-eui.0025384331408197 | Override disk 1 |
| `--disk2 <by-id>` | nvme-eui.002538433140818a | Override disk 2 |
| `--disk3 <by-id>` | nvme-eui.002538433140819d | Override disk 3 |
| `--yes` | off | Skip destructive confirmation prompts |

## Configuration Constants

| Constant | Value |
|---|---|
| `POOL_NAME` | `PRECISION` |
| `ROOT_DATASET` | `PRECISION/ROOT/kubuntu` |
| `RECOVERY_ROOT` | `/mnt/recovery` |
| `BACKUP_NAS` | `rackstation` |
| `BACKUP_SHARE` | `/Backup` |
| `BACKUP_MOUNT` | `/mnt/synology` |
| `BACKUP_CREDENTIALS` | `/etc/sysbackup/nas.cred` |
| `BACKUP_KEEP_COUNT` | `4` |
| `BACKUP_FILE_GLOB` | `precision-*.zfs.zst` |
| `CLOUD_SYNC_TARGET` | `gdrive:precision-backups/` |

## Function Map

### Logging / Control Flow
`info` `warn` `error` `fatal` `usage`

### Validation
`require_root` `require_live_environment` `require_command`
`require_mode_commands` `validate_by_id_disk` `validate_distinct_disks`
`require_debian_family` `load_os_release`

### Package Auto-install
`package_for_command` `apt_update_once` `install_package_for_command`

### Layout Check
`check_layout` `run_check_layout` `check_partition_dump`
`check_mdadm_array` `check_filesystem_signature`
`check_zpool_members` `check_zpool_property`
`check_zfs_property` `check_dataset_scaffold`
`expect_equal` `expect_line_present` `report_mismatch`
`blkid_value` `zfs_dataset_value` `sorted_join_lines`
`real_disk_path` `part_path`

### Layout Rebuild
`run_rebuild_layout` `confirm_rebuild` `destroy_or_export_pool`
`stop_existing_arrays` `zero_superblocks` `wipe_target_disks`
`partition_target_disks` `create_arrays` `format_arrays`
`create_pool_and_datasets` `wait_for_block_devices`

### Backup
`run_backup` `mount_backup_target` `cleanup_backup_mount`
`prune_old_backup_snapshots` `prune_old_backup_files`
`sync_backup_to_cloud`

### Restore Data
`run_restore_data` `choose_backup_archive` `confirm_restore_data`
`verify_backup_archive` `backup_timestamp_from_path`
`import_pool_for_recovery` `destroy_existing_pool_datasets`
`destroy_existing_pool_snapshots` `verify_restored_snapshot`

### Boot Repair
`run_repair_boot` `mount_recovery_root_dataset`
`mount_recovery_boot_filesystems` `mount_recovery_chroot_support`
`cleanup_recovery_chroot_mounts` `cleanup_recovery_pool_mounts`
`export_recovery_pool` `run_in_recovery_chroot`
`write_recovery_fstab` `write_recovery_mdadm_conf`
`set_recovery_zpool_cachefile` `require_recovery_command`
`recovery_os_release_field` `apt_source_uses_install_media`
`disable_recovery_install_media_apt_sources`
`write_recovery_online_apt_sources`
`configure_recovery_online_apt_sources`
`list_installed_recovery_kernel_packages`
`reinstall_recovery_kernel_packages`
`rebuild_recovery_boot_configuration` `verify_recovery_boot_artifacts`

### Orchestration
`run_full_restore` `parse_args` `dispatch_mode` `main`

## Storage Layout This Script Models

- **Pool**: `PRECISION` (raidz1)
- **Disks**: 3× NVMe by-id paths
- **disk1/disk2**: EFI (RAID1), boot (RAID1), swap (member), ZFS (member)
- **disk3**: swap (member), ZFS (member)
- **md arrays**: `/dev/md/efi` RAID1, `/dev/md/boot` RAID1, `/dev/md/swap` RAID0×3
- **ZFS datasets**: ROOT/kubuntu, home, home/Downloads, srv, var/cache, var/lib/docker, var/log, var/tmp

## Tests

**`tests/test-command-checks.sh`** — 326 lines, plain Bash (no framework)

Tests covered:
- `assert_mode_command_set` — verifies required commands per mode (backup, restore-data, repair-boot, rebuild-layout, full-restore)
- `assert_package_mapping_for_commands` — verifies every required command has a package mapping
- `test_require_command_install_path_with_fake_apt` — exercises apt install path with a fake apt-get
- `test_require_recovery_command_paths` — exercises chroot command check paths
- `test_configure_recovery_online_apt_sources_ubuntu` — verifies local install-media apt sources are disabled and Ubuntu online sources are written
- `test_configure_recovery_online_apt_sources_debian` — verifies Debian online sources are written

Run: `sudo bash tests/test-command-checks.sh`

## Key Design Decisions

- Semantic equivalence contract: UUIDs/GUIDs are not reproduced, only roles and topology
- `/boot` and `/boot/efi` are not in the ZFS backup; boot repair reinstalls kernel packages
- NAS credentials passed via `/etc/sysbackup/nas.cred` (never on command line)
- Auto-installs missing tools via apt on Debian-family systems only
- `rclone sync` mirrors the local 4-file retention window to cloud (intentional)
- Layout check runs as final verification step after both rebuild and restore
- Pool import for recovery always enforces altroot `/mnt/recovery`

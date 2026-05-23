# `precision-dr`

This directory contains the unified disaster recovery scaffold for the `PRECISION` laptop.

The project goal is a single script that can eventually handle the full live-boot recovery path with minimal user input while still being developed in explicit phases.

## Authoritative Inputs

Future sessions should treat the following as authoritative unless the user says otherwise:

- the live storage layout of the current running OS
- `/usr/local/bin/zfs-backup.sh`
- the files in this directory

Nearby abandoned or experimental scripts elsewhere on the machine are not part of this project unless the user explicitly promotes them into scope.

## Current Architecture

Implementation is unified.

Responsibility is phased.

The intended operational end state is also unified:

- one monolithic script for backup and recovery workflow
- no split between a "real" backup script and a separate restore script once implementation is complete

The authoritative script is:

- [precision-dr.sh](/home/me/code/rebuild-drv-layout/precision-dr.sh)

Compatibility wrapper:

- [rebuild-storage-layout.sh](/home/me/code/rebuild-drv-layout/rebuild-storage-layout.sh)

## Phase Model

The intended end state is one script with these modes:

- `backup`
- `check-layout`
- `rebuild-layout`
- `restore-data`
- `repair-boot`
- `full-restore`

Current implementation status:

- `check-layout`: implemented
- `rebuild-layout`: implemented
- `backup`: scaffold only
- `restore-data`: scaffold only
- `repair-boot`: scaffold only
- `full-restore`: scaffold only

## Scope Boundary

The currently implemented scope is storage-layout reconstruction only.

That means the script currently does:

- verify whether the expected storage scaffold already exists
- rebuild the storage scaffold when requested
- recreate mdraid EFI/boot/swap structure
- recreate the ZFS pool and base dataset scaffold

That means the script currently does not:

- create or verify backup archives
- receive ZFS backup data into the rebuilt pool
- restore `/boot` contents
- restore `/boot/efi` contents
- install or repair GRUB
- guarantee bootability

## Semantic Contract

Layout verification is based on semantic equivalence, not literal UUID/GUID identity.

A matching layout means:

- three specific disks are addressed by `/dev/disk/by-id/*`
- partition roles and geometry match the expected scheme
- `mdadm` arrays exist with the expected levels, membership, and labels
- EFI, boot, and swap filesystems exist with the expected types and labels
- the ZFS pool is named `PRECISION`
- the ZFS vdev topology is `raidz1`
- ZFS member devices are referenced by `/dev/disk/by-id/*`
- the expected base dataset tree and properties exist

Exact reproduction of disk GUIDs, partition GUIDs, md UUIDs, or filesystem UUIDs is not required.

## Relationship To `zfs-backup.sh`

The backup script at `/usr/local/bin/zfs-backup.sh` is the active backup reference for this project.

Its current behavior:

- creates recursive pool snapshots
- sends a full recursive ZFS stream for pool `PRECISION`
- writes the compressed stream to the NAS
- mounts `//rackstation/Backup` at `/mnt/synology`
- stores backups as `/mnt/synology/precision-<timestamp>.zfs.zst`

Important implication:

- because the current backup script does not back up `/boot` or `/boot/efi`, end-to-end bootability cannot yet be guaranteed by this project in its current phase

Design decisions now settled for this project:

- the existing `.zfs.zst` archives produced by `/usr/local/bin/zfs-backup.sh` are valid restore sources
- restore should consume those archives as-is
- restore should not introduce remapping, rename logic, alternate dataset targets, manifests, or a new backup format
- the monolithic project script should eventually absorb backup behavior so backup and restore live in one script
- the NAS path used by the current backup script is the authoritative restore source location
- restore should mount the NAS and present available backups to the user newest-first as a numbered menu

Current design direction for the unresolved boot gap:

- do not start by adding `/boot` or `/boot/efi` into the backup archive format
- instead, restore ZFS data into the rebuilt layout and then automate boot repair
- the restore flow must complete in a bootable state; it should not stop at data restore and expect the user to repair boot manually

## Live Layout This Scaffold Models

The current scaffold is based on the storage layout of the running system:

- pool name: `PRECISION`
- root dataset: `PRECISION/ROOT/kubuntu`
- disk1: `/dev/disk/by-id/nvme-eui.0025384331408197`
- disk2: `/dev/disk/by-id/nvme-eui.002538433140818a`
- disk3: `/dev/disk/by-id/nvme-eui.002538433140819d`

Partition roles:

- disk1: `EFI1`, `BOOT1`, `SWAP1`, `ZFS1`
- disk2: `EFI2`, `BOOT2`, `SWAP2`, `ZFS2`
- disk3: `SWAP3`, `ZFS3`

mdraid roles:

- EFI: RAID1 across disk1-part1 and disk2-part1
- boot: RAID1 across disk1-part2 and disk2-part2
- swap: RAID0 across disk1-part3, disk2-part3, and disk3-part1

ZFS topology:

- `raidz1`
- members:
  - disk1-part4
  - disk2-part4
  - disk3-part2

Base dataset scaffold:

- `PRECISION/ROOT`
- `PRECISION/ROOT/kubuntu`
- `PRECISION/home`
- `PRECISION/home/Downloads`
- `PRECISION/srv`
- `PRECISION/var`
- `PRECISION/var/cache`
- `PRECISION/var/lib`
- `PRECISION/var/lib/docker`
- `PRECISION/var/log`
- `PRECISION/var/tmp`

## Intended End-State Recovery Flow

The intended automated flow is:

1. `rebuild-layout` recreates the empty storage scaffold:
   - GPT partitioning
   - mdraid EFI/boot/swap arrays
   - EFI/boot/swap filesystems
   - ZFS pool and base dataset tree
2. `restore-data` mounts the NAS backup location and presents available
   `precision-*.zfs.zst` archives newest-first as a numbered choice list
3. `restore-data` receives the chosen archive back into pool `PRECISION`
   exactly as stored, with no remapping
4. `repair-boot` mounts the restored system, mounts `/dev/md/boot` and
   `/dev/md/efi`, enters a chroot, rebuilds boot artifacts/configuration,
   and reinstalls GRUB as needed
5. `full-restore` orchestrates the full chain so that if the machine is
   rebooted after completion, the restored OS should boot

## Boot-Repair Design Direction

The expected automated `repair-boot` behavior is:

- mount the restored root dataset under the recovery root
- mount `/dev/md/boot` at `/boot`
- mount `/dev/md/efi` at `/boot/efi`
- bind-mount runtime filesystems needed for chroot work such as `dev`,
  `proc`, `sys`, and likely `run`
- chroot into the restored system
- ensure boot-critical configuration is correct for the rebuilt layout
- regenerate initramfs and GRUB configuration
- install the EFI bootloader for both EFI-backed disks
- verify boot-critical files exist before reporting success

This boot-repair automation is the preferred first path.

For now, separate backup/restore of `/boot` or `/boot/efi` is not the
planned starting design unless later testing shows regeneration is not
reliable enough.

## Phase Testing

Phase testing should be part of the project.

It is feasible, but the testing model must match the nature of the work:

- this project is destructive
- it is tied to a specific storage layout
- some phases can be validated with command/output checks
- some phases ultimately require a real recovery drill and reboot test

Testing direction by phase:

- `check-layout`:
  - highly testable
  - semantic checks can be validated against captured command output and
    against the live system
- `rebuild-layout`:
  - partially testable
  - safety gates, argument handling, and verification logic can be tested
  - true validation requires a sacrificial target or equivalent lab setup
- `restore-data`:
  - feasible to test with a known-good `.zfs.zst` archive and a rebuilt
    empty target pool
  - success criteria should include dataset/pool verification after receive
- `repair-boot`:
  - feasible to test, but this must include end-to-end recovery validation
  - command success alone is not enough; the restored system must be shown
    to boot
- `full-restore`:
  - feasible only as an integration/recovery-drill path
  - its value is proving the full chain, not isolated sub-steps

Project testing principle:

- phase-level verification should be implemented wherever practical
- non-destructive validation should be preferred when sufficient
- destructive actions should always be followed by explicit verification of
  the state they were intended to create or modify
- bootability must be proven by actual reboot testing, not inferred only
  from successful command execution

## Development Rule For Future Sessions

Inference is allowed as discussion.

Inference is not allowed to become action unless the user explicitly directs it.

In practical terms:

- do not pull abandoned nearby scripts into scope without explicit user instruction
- do not treat analysis as authority
- if a design choice affects behavior, present it to the user before implementing it

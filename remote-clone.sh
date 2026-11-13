#!/bin/bash
# Runs as root on the helper instance via SSM. Driven by ebs-shrink.sh.
#
#   remote-clone.sh inspect <src-volume-id>
#   remote-clone.sh clone   <src-volume-id> <dst-volume-id>
#
# <src-volume-id> is a volume created from the snapshot of the source root.
# <dst-volume-id> is the new, smaller, empty volume.
# Machine-readable results are printed as "RESULT KEY=VALUE" lines.
set -euo pipefail

SRC_MNT=/mnt/ebs-shrink-src
DST_MNT=/mnt/ebs-shrink-dst
BIOS_BOOT_GUID=21686148-6449-6E6F-744E-656564454649

log() { echo "[remote] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }
result() { echo "RESULT $1=$2"; }

# A volume shows up in the guest a few seconds after the attach API reports in-use, so poll.
dev_for_volume() {
  local serial=${1//-/} d
  for _ in $(seq 1 30); do
    for d in /sys/class/block/*; do
      [[ -f $d/device/serial && $(tr -d ' ' < "$d/device/serial") == "$serial" ]] && { echo "/dev/${d##*/}"; return; }
    done
    sleep 2; udevadm settle
  done
  die "no block device with serial $serial (devices: $(ls /sys/class/block | tr '\n' ' '))"
}

part_numbers() { cat /sys/class/block/"${1##*/}"/*/partition 2>/dev/null; }

part_dev() { # disk partition-number
  local p
  for p in /sys/class/block/"${1##*/}"/*/partition; do
    [[ $(cat "$p") == "$2" ]] && { echo "/dev/$(basename "$(dirname "$p")")"; return; }
  done
  die "no partition $2 on $1"
}

# The root filesystem lives on the largest partition. inspect confirms /etc/fstab is there.
root_partn() {
  local p dir best=0 bestn=
  for p in /sys/class/block/"${1##*/}"/*/partition; do
    dir=$(dirname "$p")
    (( $(cat "$dir/size") > best )) && { best=$(cat "$dir/size"); bestn=$(cat "$p"); }
  done
  [[ -n $bestn ]] || die "no partitions on $1"
  echo "$bestn"
}

part_bytes() { echo $(( $(cat /sys/class/block/"${1##*/}"/size) * 512 )); }

part_geometry() { cat /sys/class/block/"${1##*/}"/start /sys/class/block/"${1##*/}"/size | tr '\n' ' '; }

mount_opts() { # $1 = fstype, $2 = ro|rw. nouuid lets an xfs clone of the helper's own AMI mount.
  local o=$2
  [[ $1 == xfs ]] && o="$o,nouuid"
  echo "$o"
}

ensure_mounted() { # dev mountpoint fstype ro|rw
  mkdir -p "$2"
  mountpoint -q "$2" || mount -o "$(mount_opts "$3" "$4")" "$1" "$2"
}

unmount_all() {
  for m in "$DST_MNT/dev" "$DST_MNT/proc" "$DST_MNT/sys" "$DST_MNT" "$SRC_MNT"; do
    mountpoint -q "$m" 2>/dev/null && umount -R "$m"
  done
  sync
}

settle() { partprobe "$1" 2>/dev/null || true; udevadm settle; }

cmd_inspect() {
  local src n rootp fstype uuid label used other disk_bytes
  src=$(dev_for_volume "$1"); settle "$src"
  n=$(root_partn "$src"); rootp=$(part_dev "$src" "$n")
  [[ -n $rootp ]] || die "no partitions found on $src"
  fstype=$(blkid -s TYPE -o value "$rootp"); uuid=$(blkid -s UUID -o value "$rootp")
  label=$(blkid -s LABEL -o value "$rootp" || true)
  case $fstype in xfs|ext4) ;; *) die "unsupported root filesystem '$fstype' on $rootp" ;; esac
  ensure_mounted "$rootp" "$SRC_MNT" "$fstype" ro
  [[ -f $SRC_MNT/etc/fstab ]] || die "$rootp has no /etc/fstab; it is not a Linux root"
  used=$(df -B1 --output=used "$SRC_MNT" | tail -1 | tr -d ' ')
  other=0
  for p in $(part_numbers "$src"); do
    [[ $p == "$n" ]] && continue
    other=$(( other + $(part_bytes "$(part_dev "$src" "$p")") ))
  done
  disk_bytes=$(part_bytes "$src")
  log "root partition $rootp ($fstype, UUID=$uuid): $used bytes used; other partitions $other bytes"
  result FSTYPE "$fstype"; result FSUUID "$uuid"; result FSLABEL "$label"
  result ROOT_PARTN "$n"; result USED_BYTES "$used"; result OTHER_PARTS_BYTES "$other"
  result DISK_BYTES "$disk_bytes"; result PRETTY_NAME "$(. "$SRC_MNT/etc/os-release" && echo "$PRETTY_NAME")"
  umount "$SRC_MNT"
}

write_partition_table() { # src dst root-partition-number
  local src=$1 dst=$2 n=$3 srcroot
  srcroot=$(part_dev "$src" "$n")
  # Same partition starts, types, GUIDs and names; the root partition grows to fill the smaller disk.
  sfdisk -d "$src" \
    | sed -E -e '/^(device|last-lba):/d' \
             -e "\#^${srcroot} :# s/ size= *[0-9]+,//" \
             -e "s#^${src}#${dst}#" \
    | sfdisk --quiet --wipe always --wipe-partitions always "$dst"
  settle "$dst"
  for p in $(part_numbers "$src"); do
    [[ $p == "$n" ]] && continue
    [[ $(part_geometry "$(part_dev "$src" "$p")") == $(part_geometry "$(part_dev "$dst" "$p")") ]] \
      || die "partition $p geometry differs between $src and $dst"
  done
}

copy_small_partitions() { # src dst root-partition-number: EFI, BIOS boot, etc. are byte-identical copies
  local src=$1 dst=$2 n=$3
  for p in $(part_numbers "$src"); do
    [[ $p == "$n" ]] && continue
    log "copying partition $p verbatim"
    dd if="$(part_dev "$src" "$p")" of="$(part_dev "$dst" "$p")" bs=1M conv=fsync status=none
  done
  # MBR boot code (grub boot.img) without touching the protective partition table.
  dd if="$src" of="$dst" bs=440 count=1 conv=notrunc,fsync status=none
}

make_root_fs() { # dstroot fstype uuid label
  local dev=$1 fstype=$2 uuid=$3 label=$4
  case $fstype in
    xfs)  mkfs.xfs -f -q -m uuid="$uuid" ${label:+-L "$label"} "$dev" ;;
    ext4) mkfs.ext4 -F -q -U "$uuid" ${label:+-L "$label"} "$dev" ;;
  esac
  [[ $(blkid -s UUID -o value "$dev") == "$uuid" ]] || die "UUID on $dev does not match $uuid"
}

has_bios_boot_partition() { sfdisk -d "$1" | grep -qi "type=$BIOS_BOOT_GUID" || sfdisk -d "$1" | grep -q '^label: dos'; }

reinstall_grub() { # dst. core.img was already dd-copied; grub-install from the target's own packages is the belt and braces.
  local dst=$1 tool
  has_bios_boot_partition "$dst" || { log "no BIOS boot partition; UEFI-only, nothing to install"; return; }
  tool=$(chroot "$DST_MNT" sh -c 'command -v grub2-install || command -v grub-install' || true)
  if [[ -z $tool || ! -d $DST_MNT/usr/lib/grub/i386-pc ]]; then
    log "target has no grub i386-pc install tooling; keeping the copied core.img"; return
  fi
  for d in dev proc sys; do mountpoint -q "$DST_MNT/$d" || mount --bind "/$d" "$DST_MNT/$d"; done
  if chroot "$DST_MNT" "$tool" --target=i386-pc "$dst" >&2; then
    log "grub installed to $dst via $tool"
  else
    log "WARNING: $tool failed; restoring the copied BIOS boot partition and MBR"
    copy_small_partitions "$SRC" "$dst" "$ROOT_N"
  fi
  for d in sys proc dev; do umount "$DST_MNT/$d"; done
}

check_fs() { # dev fstype
  case $2 in
    xfs)  xfs_repair -n "$1" >/dev/null 2>&1 || die "xfs_repair -n reports problems on $1" ;;
    ext4) e2fsck -fn "$1" >/dev/null 2>&1 || die "e2fsck -fn reports problems on $1" ;;
  esac
}

cmd_clone() {
  local dst dstroot fstype uuid label src_count dst_count
  SRC=$(dev_for_volume "$1"); dst=$(dev_for_volume "$2")
  [[ $SRC != "$dst" ]] || die "source and destination resolve to the same device"
  unmount_all
  settle "$SRC"
  ROOT_N=$(root_partn "$SRC")
  fstype=$(blkid -s TYPE -o value "$(part_dev "$SRC" "$ROOT_N")")
  uuid=$(blkid -s UUID -o value "$(part_dev "$SRC" "$ROOT_N")")
  label=$(blkid -s LABEL -o value "$(part_dev "$SRC" "$ROOT_N")" || true)

  log "partitioning $dst like $SRC"
  write_partition_table "$SRC" "$dst" "$ROOT_N"
  copy_small_partitions "$SRC" "$dst" "$ROOT_N"
  dstroot=$(part_dev "$dst" "$ROOT_N")
  log "creating $fstype on $dstroot with UUID $uuid"
  make_root_fs "$dstroot" "$fstype" "$uuid" "$label"

  ensure_mounted "$(part_dev "$SRC" "$ROOT_N")" "$SRC_MNT" "$fstype" ro
  ensure_mounted "$dstroot" "$DST_MNT" "$fstype" rw
  log "rsync $SRC_MNT -> $DST_MNT"
  rsync -aAXH --numeric-ids --info=stats1 "$SRC_MNT/" "$DST_MNT/" >&2

  src_count=$(find "$SRC_MNT" -xdev | wc -l); dst_count=$(find "$DST_MNT" -xdev | wc -l)
  [[ $src_count == "$dst_count" ]] || die "entry count mismatch: source $src_count, clone $dst_count"
  [[ -f $DST_MNT/etc/fstab && -d $DST_MNT/boot ]] || die "clone is missing /etc/fstab or /boot"
  grep -q "$uuid" "$DST_MNT/etc/fstab" || log "WARNING: /etc/fstab does not reference UUID $uuid"

  reinstall_grub "$dst"
  unmount_all
  check_fs "$dstroot" "$fstype"
  result ENTRIES "$src_count"; result DST_ROOT_UUID "$(blkid -s UUID -o value "$dstroot")"
  result DST_SIZE_BYTES "$(part_bytes "$dst")"
  log "clone complete"
}

case ${1:-} in
  inspect) cmd_inspect "$2" ;;
  clone)   cmd_clone "$2" "$3" ;;
  *) die "usage: $0 inspect <vol> | clone <src-vol> <dst-vol>" ;;
esac

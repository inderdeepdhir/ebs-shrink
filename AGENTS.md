# ebs-shrink

Clone the root EBS volume of a Linux EC2 instance onto a smaller volume, swap it in, and verify the instance boots from it. Driven entirely by the AWS CLI; the Linux-side work runs on a temporary helper instance through SSM.

## Why a clone and not a resize

EBS only grows volumes. `modify-volume` rejects a smaller size, and `create-volume --snapshot-id` rejects a size below the snapshot's. EC2's root-volume replacement feature has the same floor. The only way down is a new volume with a fresh partition table and filesystem, the files copied over, and the bootloader reinstalled.

Options considered:

| Approach | Verdict |
|---|---|
| `resize2fs` + `dd` of the shrunken filesystem into a smaller volume | ext4 only. XFS, the default on Amazon Linux 2 and 2023, cannot shrink. Rejected. |
| Build an AMI with a smaller root mapping | Same floor: the mapping size cannot be below the snapshot size. Rejected. |
| New volume, replicate partition table, `mkfs` with the original UUID and label, `rsync`, reinstall grub | Works for xfs and ext4, BIOS and UEFI. Chosen. |

Keeping the filesystem UUID and label means `/etc/fstab`, the grub config, and the kernel `root=UUID=` arguments all keep working without edits. Small partitions (EFI system partition, BIOS boot partition) are copied byte for byte into partitions at identical offsets, so the MBR boot code's pointer to grub's `core.img` stays valid. grub is then reinstalled from inside a chroot of the new root as a second line of defence.

## What the script does

`ebs-shrink.sh shrink -i <instance-id>` runs these phases, checkpointing each in `.ebs-shrink/<instance-id>.state` so a failed run resumes where it stopped:

1. **inspect** the instance: AZ, root device name, architecture, AMI, subnet, security groups, root volume, encryption, DeleteOnTermination.
2. **stop_source** so the snapshot is consistent and no writes are lost. `--live` skips this and snapshots the running instance; anything written after the snapshot will not be on the clone.
3. **snapshot** the root volume. Kept afterwards as a rollback point.
4. **helper**: launch a small instance in the same subnet from the source's own AMI (same architecture, same kernel, same filesystem tooling), with an instance profile for SSM. Install rsync if missing.
5. **src_copy**: create a volume from the snapshot and attach it to the helper.
6. **inspect_remote**: find the root partition, its filesystem type, UUID, label, and used bytes.
7. **new_volume**: create the smaller gp3 volume (encrypted with the same KMS key if the source was) and attach it. Default size is used space plus 20 percent plus the other partitions, rounded up to a GiB.
8. **clone** on the helper: replicate the partition table with the root partition filling the smaller disk, dd the small partitions and MBR boot code, `mkfs` with the original UUID, `rsync -aAXH`, reinstall grub in a chroot, compare entry counts, run `xfs_repair -n` or `e2fsck -fn`.
9. **detach_from_helper**.
10. **swap**: stop the instance if running, detach the old root, attach the new volume at the recorded root device name, restore the DeleteOnTermination flag, start.
11. **verify**: wait for EC2 status checks, then confirm from inside over SSM that `/` is mounted from a filesystem no larger than the requested size. Without SSM on the instance, it falls back to watching the serial console for a login prompt.
12. **cleanup**: terminate the helper and delete the snapshot copy. The old root volume and the snapshot are kept and the rollback command is printed.

Other commands: `status`, `rollback` (puts the original volume back and verifies the boot), `cleanup` (helper and temporary volume only), `purge` (deletes the original volume and snapshot once you are satisfied), `profile` (creates the IAM instance profile `ebs-shrink-helper` if missing).

## Usage

```
./ebs-shrink.sh shrink -i i-0123456789abcdef0 [--profile NAME] [--region REGION] [-s GIB] [--live]
./ebs-shrink.sh status   -i i-0123456789abcdef0
./ebs-shrink.sh rollback -i i-0123456789abcdef0
./ebs-shrink.sh purge    -i i-0123456789abcdef0
```

Requirements: AWS CLI v2, `gzip`, `base64`. The caller needs EC2, SSM `SendCommand`/`GetCommandInvocation`/`DescribeInstanceInformation`, and IAM rights to create the helper role the first time. The helper needs outbound HTTPS to the SSM endpoints (a public subnet or VPC endpoints). The source instance is stopped and started, so its public IP changes unless it has an Elastic IP.

Verified end to end on Amazon Linux 2023 x86_64 (xfs, GPT with BIOS boot and EFI partitions, UEFI boot, account-default EBS encryption): 16 GiB root shrunk to 2 GiB, data checksum intact, rollback verified. Untested paths: BIOS-only boot, ext4, MBR partition tables, other distros, `--live`, and the serial-console fallback when the instance has no SSM.

The default size (used space plus 20 percent) leaves little headroom. Pass `-s` for anything that will keep writing.

## Test

`./test-throwaway.sh` launches a t3.micro with a 16 GiB root, writes 50 MiB of random data and its checksum, shrinks the root, proves the checksum survives on the new root, rolls back, proves the original root is back, and deletes everything it created. `./test-throwaway.sh destroy` tears down a failed run.

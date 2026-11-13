#!/usr/bin/env bash
# End-to-end test of ebs-shrink.sh on a throwaway Amazon Linux 2023 instance.
#
# Launches a t3.micro with a 16 GiB root, writes 50 MiB of random data and its checksum, shrinks the
# root with ebs-shrink.sh, proves the checksum survives on the new root, rolls back, proves the original
# root is back, then terminates the instance and deletes the new volume and the snapshot.
#
#   ./test-throwaway.sh            run the whole test
#   ./test-throwaway.sh destroy    tear down a previous run's resources (reads .ebs-shrink/test-instance)
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ebs-shrink.sh
source "$DIR/ebs-shrink.sh"
INSTANCE_FILE=$STATE_DIR/test-instance
ROOT_GIB=16

launch_instance() {
  local ami
  ami=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  ensure_instance_profile
  [[ $(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text) != None ]] \
    || die "no default VPC in this region; the test launches into the default VPC"
  log "launching test instance from $ami with a ${ROOT_GIB} GiB root"
  for attempt in 1 2 3 4 5 6; do
    INSTANCE=$(aws ec2 run-instances --image-id "$ami" --instance-type t3.micro --iam-instance-profile "Name=$PROFILE_NAME" \
      --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$ROOT_GIB,\"VolumeType\":\"gp3\"}}]" \
      --metadata-options HttpTokens=required \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ebs-shrink-test}]' \
      --query 'Instances[0].InstanceId' --output text) && break
    log "run-instances failed (attempt $attempt); retrying in 10s"; sleep 10
  done
  [[ -n ${INSTANCE:-} ]] || die "could not launch test instance"
  mkdir -p "$STATE_DIR"; echo "$INSTANCE" > "$INSTANCE_FILE"; STATE_FILE=$STATE_DIR/$INSTANCE.state
  wait_for instance-status-ok --instance-ids "$INSTANCE"
  wait_ssm_online "$INSTANCE" 600 || die "test instance never came online in SSM"
}

recorded_instance_alive() {
  INSTANCE=$(cat "$INSTANCE_FILE" 2>/dev/null) || return 1
  STATE_FILE=$STATE_DIR/$INSTANCE.state
  [[ $(instance_field State.Name 2>/dev/null) =~ ^(running|stopped)$ ]]
}

run_test() {
  local sha before after
  if recorded_instance_alive; then
    log "resuming with test instance $INSTANCE"
  else
    launch_instance
    log "writing marker data on $INSTANCE"
    sha=$(ssm_run "$INSTANCE" 300 "head -c 50M /dev/urandom > /var/tmp/marker.bin && sha256sum /var/tmp/marker.bin | tee /var/tmp/marker.sha | cut -d' ' -f1")
    log "marker sha256 $sha"
  fi
  before=$(st_get OLD_VOL)
  [[ -n $before ]] || before=$(aws ec2 describe-instances --instance-ids "$INSTANCE" --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
  log "original root volume $before"

  "$DIR/ebs-shrink.sh" shrink -i "$INSTANCE"

  log "checking marker on the new root"
  ssm_run "$INSTANCE" 120 "cd /var/tmp && sha256sum -c marker.sha && findmnt -no SOURCE,SIZE /"
  after=$(aws ec2 describe-instances --instance-ids "$INSTANCE" --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
  [[ $after == "$(st_get NEW_VOL)" && $after != "$before" ]] || die "root is $after, expected $(st_get NEW_VOL)"
  log "PASS: $INSTANCE runs from $after ($(st_get NEW_SIZE) GiB) with the marker intact"

  "$DIR/ebs-shrink.sh" rollback -i "$INSTANCE"
  ssm_run "$INSTANCE" 120 "cd /var/tmp && sha256sum -c marker.sha && findmnt -no SOURCE,SIZE /"
  [[ $(aws ec2 describe-instances --instance-ids "$INSTANCE" --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text) == "$before" ]] || die "rollback did not restore $before"
  log "PASS: rollback restored $before"
  destroy
}

destroy() {
  local v
  INSTANCE=${INSTANCE:-$(cat "$INSTANCE_FILE" 2>/dev/null || true)}
  [[ -n $INSTANCE ]] || die "no test instance recorded"
  STATE_FILE=$STATE_DIR/$INSTANCE.state
  cmd_cleanup
  log "terminating $INSTANCE (its current root volume is deleted with it)"
  aws ec2 terminate-instances --instance-ids "$INSTANCE" >/dev/null
  wait_for instance-terminated --instance-ids "$INSTANCE"
  for v in $(st_get NEW_VOL) $(st_get OLD_VOL); do
    [[ $(aws ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].State' --output text 2>/dev/null) == available ]] \
      && { log "deleting volume $v"; aws ec2 delete-volume --volume-id "$v"; }
  done
  v=$(st_get SNAPSHOT); [[ -n $v ]] && { log "deleting snapshot $v"; aws ec2 delete-snapshot --snapshot-id "$v"; }
  rm -f "$STATE_FILE" "$INSTANCE_FILE"
  log "all test resources removed"
}

case ${1:-run} in
  run) run_test ;;
  destroy) destroy ;;
  *) echo "usage: $0 [run|destroy]"; exit 1 ;;
esac

#!/usr/bin/env bash
# ebs-shrink.sh: clone the root EBS volume of a Linux EC2 instance onto a smaller volume and swap it in.
#
# EBS cannot shrink a volume, so the script builds a new one: it snapshots the root, launches a helper
# instance in the same AZ, and (over SSM) partitions the new volume like the old one, recreates the root
# filesystem with the same UUID and label, rsyncs the files, reinstalls grub, then stops the instance,
# swaps the root volume, starts it and verifies the boot. The old volume and the snapshot are kept.
#
# Progress is checkpointed in .ebs-shrink/<instance-id>.state, so a failed run resumes where it stopped.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REMOTE_SCRIPT=$SCRIPT_DIR/remote-clone.sh
STATE_DIR=$SCRIPT_DIR/.ebs-shrink
PROFILE_NAME=ebs-shrink-helper
TAG_KEY=ebs-shrink:source

PHASES=(inspect stop_source snapshot helper src_copy inspect_remote new_volume clone detach_from_helper swap verify cleanup)

usage() {
  cat <<EOF
usage: $0 <command> -i <instance-id> [options]

commands
  shrink     clone the root volume onto a smaller one, swap it in, verify the boot (resumable)
  status     print the recorded state for the instance
  rollback   stop, put the original root volume back, start, verify
  cleanup    terminate the helper instance and delete the temporary snapshot copy
  purge      delete the original root volume and the snapshot (after you are satisfied)
  profile    create the IAM instance profile the helper uses for SSM, if missing

options
  -i, --instance-id ID    source instance (required)
  -s, --size GIB          new root size; default: used space + 20%, rounded up to GiB
  --live                  snapshot while the instance runs (writes after the snapshot are lost)
  --helper-type TYPE      helper instance type (default: t3.micro, or t4g.micro for arm64)
  --helper-ami AMI        helper AMI (default: the source's own AMI, else latest Amazon Linux 2023)
  --volume-type TYPE      new volume type (default: gp3)
  --region REGION         AWS region (else AWS_DEFAULT_REGION / profile config)
  --profile PROFILE       AWS CLI profile
EOF
  exit 1
}

log() { printf '%s [ebs-shrink] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---- state file: one KEY=VALUE per line, keyed by the source instance id
st_get() { [[ -f $STATE_FILE ]] && grep -m1 "^$1=" "$STATE_FILE" | cut -d= -f2- || true; }
st_set() {
  mkdir -p "$STATE_DIR"; touch "$STATE_FILE"
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE.tmp"; mv "$STATE_FILE.tmp" "$STATE_FILE"
}
st_del() { [[ -f $STATE_FILE ]] && { grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" || true; mv "$STATE_FILE.tmp" "$STATE_FILE"; }; }

ec2() { aws ec2 "$@"; }
tags() { echo "ResourceType=$1,Tags=[{Key=$TAG_KEY,Value=$INSTANCE},{Key=Name,Value=ebs-shrink-$2}]"; }

# AWS CLI waiters give up after ~10 minutes; retry them for long operations.
wait_for() { # waiter-name args...
  local tries=0
  until aws ec2 wait "$@" 2>/dev/null; do
    (( ++tries < 12 )) || die "timed out waiting for: $*"
    log "still waiting for $1 ..."
  done
}

instance_field() { ec2 describe-instances --instance-ids "$INSTANCE" --query "Reservations[0].Instances[0].$1" --output text; }
root_volume_of_instance() { instance_field "BlockDeviceMappings[?DeviceName=='$(st_get ROOT_DEV)'].Ebs.VolumeId | [0]"; }
volume_state() { ec2 describe-volumes --volume-ids "$1" --query 'Volumes[0].State' --output text; }
volume_attachment_instance() { ec2 describe-volumes --volume-ids "$1" --query 'Volumes[0].Attachments[0].InstanceId' --output text; }

ensure_stopped() {
  local s; s=$(instance_field State.Name)
  case $s in
    stopped) ;;
    running|pending|stopping) log "stopping $INSTANCE"; ec2 stop-instances --instance-ids "$INSTANCE" >/dev/null; wait_for instance-stopped --instance-ids "$INSTANCE" ;;
    *) die "$INSTANCE is $s" ;;
  esac
}

ensure_running() {
  local s; s=$(instance_field State.Name)
  case $s in
    running) ;;
    stopped|stopping) log "starting $INSTANCE"; [[ $s == stopping ]] && wait_for instance-stopped --instance-ids "$INSTANCE"
             ec2 start-instances --instance-ids "$INSTANCE" >/dev/null; wait_for instance-running --instance-ids "$INSTANCE" ;;
    *) die "$INSTANCE is $s" ;;
  esac
}

# Set the instance's root device to the given volume (stop, detach whatever is there, attach, start).
set_root_volume() { # volume-id
  local want=$1 root_dev current
  root_dev=$(st_get ROOT_DEV)
  ensure_stopped
  current=$(root_volume_of_instance)
  if [[ $current != "$want" ]]; then
    if [[ $current != None && -n $current ]]; then
      log "detaching $current from $root_dev"
      ec2 detach-volume --volume-id "$current" >/dev/null; wait_for volume-available --volume-ids "$current"
    fi
    log "attaching $want as $root_dev"
    ec2 attach-volume --volume-id "$want" --instance-id "$INSTANCE" --device "$root_dev" >/dev/null
    wait_for volume-in-use --volume-ids "$want"
    ec2 modify-instance-attribute --instance-id "$INSTANCE" \
      --block-device-mappings "[{\"DeviceName\":\"$root_dev\",\"Ebs\":{\"VolumeId\":\"$want\",\"DeleteOnTermination\":$(st_get DELETE_ON_TERMINATION)}}]"
  fi
  ensure_running
}

# ---- SSM
ssm_online() { aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null; }

wait_ssm_online() { # instance-id timeout-seconds
  local deadline=$(( SECONDS + $2 ))
  until [[ $(ssm_online "$1") == Online ]]; do
    (( SECONDS < deadline )) || return 1
    sleep 10
  done
}

# Run a shell command on an instance via SSM, print its stdout, fail on non-Success.
ssm_run() { # instance-id timeout-seconds command
  local iid=$1 timeout=$2 cmd=$3 cid status params
  params=$(mktemp); printf '{"commands":["%s"],"executionTimeout":["%s"]}' "$cmd" "$timeout" > "$params"
  cid=$(aws ssm send-command --instance-ids "$iid" --document-name AWS-RunShellScript --comment "ebs-shrink" \
        --parameters "file://$params" --query Command.CommandId --output text)
  rm -f "$params"
  while :; do
    status=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query Status --output text 2>/dev/null || echo Pending)
    case $status in Pending|InProgress|Delayed) sleep 10 ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query StandardErrorContent --output text >&2
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" --query StandardOutputContent --output text
  [[ $status == Success ]] || die "SSM command $cid on $iid ended with status $status"
}

# Ship remote-clone.sh inline (gzip+base64 keeps it under the SSM parameter limit) and run a subcommand.
remote() { # subcommand args...
  local payload
  payload=$(gzip -9c "$REMOTE_SCRIPT" | base64 | tr -d '\n')
  ssm_run "$(st_get HELPER)" 7200 "echo $payload | base64 -d | gunzip > /root/remote-clone.sh && bash /root/remote-clone.sh $*"
}

# ---- IAM instance profile for the helper (SSM access)
ensure_instance_profile() {
  aws iam get-instance-profile --instance-profile-name $PROFILE_NAME >/dev/null 2>&1 && return
  log "creating IAM role and instance profile $PROFILE_NAME"
  aws iam create-role --role-name $PROFILE_NAME --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name $PROFILE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name $PROFILE_NAME >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name $PROFILE_NAME --role-name $PROFILE_NAME
  sleep 15
}

# ---- phases. Each is convergent: safe to rerun after a crash.
phase_inspect() {
  local az root_dev arch image subnet state sgs old_vol dot size enc kms vtype
  read -r az root_dev arch image subnet state <<<"$(instance_field '[Placement.AvailabilityZone,RootDeviceName,Architecture,ImageId,SubnetId,State.Name]')"
  [[ $state == running || $state == stopped ]] || die "$INSTANCE is $state"
  sgs=$(instance_field 'SecurityGroups[].GroupId' | tr '\t' ',')
  read -r old_vol dot <<<"$(instance_field "BlockDeviceMappings[?DeviceName=='$root_dev'].Ebs.[VolumeId,DeleteOnTermination] | [0]")"
  read -r size enc kms vtype <<<"$(ec2 describe-volumes --volume-ids "$old_vol" --query 'Volumes[0].[Size,Encrypted,KmsKeyId,VolumeType]' --output text)"
  [[ $arch == arm64 ]] && HELPER_TYPE=${HELPER_TYPE:-t4g.micro}
  st_set AZ "$az"; st_set ROOT_DEV "$root_dev"; st_set ARCH "$arch"; st_set IMAGE "$image"; st_set SUBNET "$subnet"
  st_set SGS "$sgs"; st_set OLD_VOL "$old_vol"; st_set DELETE_ON_TERMINATION "$(tr "[:upper:]" "[:lower:]" <<<"$dot")"; st_set OLD_SIZE "$size"
  st_set ENCRYPTED "$(tr "[:upper:]" "[:lower:]" <<<"$enc")"; st_set KMS "$kms"; st_set OLD_VOLUME_TYPE "$vtype"; st_set HELPER_TYPE "${HELPER_TYPE:-t3.micro}"
  log "$INSTANCE: root $root_dev = $old_vol (${size} GiB $vtype, encrypted=$enc) in $az, $arch, image $image"
}

phase_stop_source() {
  if [[ $LIVE == true ]]; then log "--live: snapshotting while $INSTANCE runs; writes after the snapshot will not be on the clone"; return; fi
  ensure_stopped
}

phase_snapshot() {
  local snap; snap=$(st_get SNAPSHOT)
  if [[ -z $snap ]]; then
    snap=$(ec2 create-snapshot --volume-id "$(st_get OLD_VOL)" --description "ebs-shrink source $INSTANCE" \
           --tag-specifications "$(tags snapshot snapshot)" --query SnapshotId --output text)
    st_set SNAPSHOT "$snap"
  fi
  log "waiting for snapshot $snap"
  wait_for snapshot-completed --snapshot-ids "$snap"
}

helper_ami() {
  if [[ -n $HELPER_AMI ]]; then echo "$HELPER_AMI"; return; fi
  local img; img=$(st_get IMAGE)
  if [[ $(ec2 describe-images --image-ids "$img" --query 'Images[0].State' --output text 2>/dev/null) == available ]]; then
    echo "$img"; return
  fi
  log "source AMI $img is unavailable; helper uses latest Amazon Linux 2023"
  aws ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$(st_get ARCH)" --query Parameter.Value --output text
}

phase_helper() {
  local helper ami sgs; helper=$(st_get HELPER)
  IFS=',' read -ra sgs <<<"$(st_get SGS)"
  ensure_instance_profile
  if [[ -z $helper ]]; then
    ami=$(helper_ami)
    log "launching helper $(st_get HELPER_TYPE) from $ami in $(st_get SUBNET)"
    for attempt in 1 2 3 4 5 6; do
      helper=$(ec2 run-instances --image-id "$ami" --instance-type "$(st_get HELPER_TYPE)" --subnet-id "$(st_get SUBNET)" \
        --security-group-ids "${sgs[@]}" --associate-public-ip-address --iam-instance-profile "Name=$PROFILE_NAME" \
        --metadata-options HttpTokens=required --tag-specifications "$(tags instance helper)" \
        --query 'Instances[0].InstanceId' --output text 2>/dev/null) && break
      log "run-instances failed (attempt $attempt); retrying in 10s (IAM propagation?)"; sleep 10
    done
    [[ -n $helper ]] || die "could not launch helper"
    st_set HELPER "$helper"
  fi
  wait_for instance-running --instance-ids "$helper"
  log "waiting for SSM agent on helper $helper"
  wait_ssm_online "$helper" 600 || die "helper $helper never registered with SSM (needs outbound HTTPS to SSM endpoints)"
  ssm_run "$helper" 600 "command -v rsync >/dev/null || (command -v dnf && dnf -q install -y rsync) || (command -v apt-get && apt-get -qq install -y rsync); command -v rsync" >/dev/null
}

attach_to_helper() { # volume-id device
  local state; state=$(volume_state "$1")
  if [[ $state == in-use ]]; then
    [[ $(volume_attachment_instance "$1") == "$(st_get HELPER)" ]] || die "$1 is attached elsewhere"
    return
  fi
  wait_for volume-available --volume-ids "$1"
  ec2 attach-volume --volume-id "$1" --instance-id "$(st_get HELPER)" --device "$2" >/dev/null
  wait_for volume-in-use --volume-ids "$1"
}

phase_src_copy() {
  local vol; vol=$(st_get SRC_COPY)
  if [[ -z $vol ]]; then
    vol=$(ec2 create-volume --snapshot-id "$(st_get SNAPSHOT)" --availability-zone "$(st_get AZ)" --volume-type gp3 \
          --tag-specifications "$(tags volume source-copy)" --query VolumeId --output text)
    st_set SRC_COPY "$vol"
  fi
  attach_to_helper "$vol" /dev/sdf
}

phase_inspect_remote() {
  local out
  out=$(remote inspect "$(st_get SRC_COPY)" | sed -n 's/^RESULT //p')
  [[ -n $out ]] || die "remote inspect returned nothing"
  while IFS='=' read -r k v; do st_set "SRC_$k" "$v"; done <<<"$out"
  log "source root: $(st_get SRC_PRETTY_NAME), $(st_get SRC_FSTYPE), UUID $(st_get SRC_FSUUID), used $(( $(st_get SRC_USED_BYTES) / 1048576 )) MiB"
}

compute_size() {
  local used other floor; used=$(st_get SRC_USED_BYTES); other=$(st_get SRC_OTHER_PARTS_BYTES)
  floor=$(( (used * 12 / 10 + other + 64 * 1048576 + 1073741823) / 1073741824 ))
  (( floor >= 2 )) || floor=2
  if [[ -z $SIZE ]]; then SIZE=$floor; fi
  (( SIZE >= floor )) || die "requested ${SIZE} GiB is below the floor of ${floor} GiB (used + 20% + other partitions)"
  (( SIZE < $(st_get OLD_SIZE) )) || die "requested ${SIZE} GiB is not smaller than the current $(st_get OLD_SIZE) GiB"
  st_set NEW_SIZE "$SIZE"
}

phase_new_volume() {
  local vol args; vol=$(st_get NEW_VOL)
  if [[ -z $vol ]]; then
    compute_size
    args=(--availability-zone "$(st_get AZ)" --size "$SIZE" --volume-type "$VOLUME_TYPE" --tag-specifications "$(tags volume new-root)")
    [[ $(st_get ENCRYPTED) == true ]] && args+=(--encrypted --kms-key-id "$(st_get KMS)")
    log "creating ${SIZE} GiB $VOLUME_TYPE volume"
    vol=$(ec2 create-volume "${args[@]}" --query VolumeId --output text)
    st_set NEW_VOL "$vol"
  fi
  attach_to_helper "$vol" /dev/sdg
}

phase_clone() {
  local out
  out=$(remote clone "$(st_get SRC_COPY)" "$(st_get NEW_VOL)" | sed -n 's/^RESULT //p')
  while IFS='=' read -r k v; do st_set "CLONE_$k" "$v"; done <<<"$out"
  [[ $(st_get CLONE_DST_ROOT_UUID) == "$(st_get SRC_FSUUID)" ]] || die "clone root UUID mismatch"
  log "cloned $(st_get CLONE_ENTRIES) entries onto $(st_get NEW_VOL)"
}

detach_from_helper() { # volume-id
  [[ -n $1 && $(volume_state "$1") == in-use && $(volume_attachment_instance "$1") == "$(st_get HELPER)" ]] || return 0
  ec2 detach-volume --volume-id "$1" >/dev/null
  wait_for volume-available --volume-ids "$1"
}

phase_detach_from_helper() {
  detach_from_helper "$(st_get NEW_VOL)"
  detach_from_helper "$(st_get SRC_COPY)"
}

phase_swap() {
  set_root_volume "$(st_get NEW_VOL)"
}

verify_boot() { # expected-root-volume-id expected-max-size-gib
  local want=$1 got ok=false deadline out root_bytes
  got=$(root_volume_of_instance)
  [[ $got == "$want" ]] || die "root device holds $got, expected $want"
  log "waiting for instance status checks"
  wait_for instance-status-ok --instance-ids "$INSTANCE"
  if wait_ssm_online "$INSTANCE" 180; then
    log "SSM is online on $INSTANCE; checking the root filesystem from inside"
    out=$(ssm_run "$INSTANCE" 120 "findmnt -no SOURCE,FSTYPE,SIZE,UUID / ; df -h / ; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT ; cat /proc/cmdline ; echo ROOT_BYTES=\$(findmnt -nbo SIZE /)")
    echo "$out" >&2
    root_bytes=$(sed -n 's/^ROOT_BYTES=//p' <<<"$out")
    (( root_bytes > 0 && root_bytes <= $2 * 1073741824 )) || die "root filesystem is $root_bytes bytes, expected at most $2 GiB"
    ok=true
  else
    log "no SSM on $INSTANCE; checking the serial console for a login prompt instead"
    deadline=$(( SECONDS + 300 ))
    until ec2 get-console-output --instance-id "$INSTANCE" --latest --output text 2>/dev/null | grep -Eq 'login:|Cloud-init .* finished'; do
      (( SECONDS < deadline )) || break
      sleep 15
    done
    (( SECONDS < deadline )) && ok=true
  fi
  [[ $ok == true ]] || die "instance passed EC2 status checks but neither SSM nor the console confirmed the OS is up"
  log "$INSTANCE booted from $want"
}

phase_verify() {
  verify_boot "$(st_get NEW_VOL)" "$(st_get NEW_SIZE)"
}

delete_helper() {
  local helper; helper=$(st_get HELPER)
  [[ -n $helper ]] || return 0
  detach_from_helper "$(st_get NEW_VOL)"; detach_from_helper "$(st_get SRC_COPY)"
  log "terminating helper $helper"
  ec2 terminate-instances --instance-ids "$helper" >/dev/null
  wait_for instance-terminated --instance-ids "$helper"
  st_del HELPER
}

delete_src_copy() {
  local vol; vol=$(st_get SRC_COPY)
  [[ -n $vol ]] || return 0
  log "deleting temporary volume $vol"
  ec2 delete-volume --volume-id "$vol"; st_del SRC_COPY
}

phase_cleanup() {
  delete_helper; delete_src_copy
  cat >&2 <<EOF

$INSTANCE now boots from $(st_get NEW_VOL) ($(st_get NEW_SIZE) GiB). Kept for rollback:
  original root volume  $(st_get OLD_VOL) ($(st_get OLD_SIZE) GiB)
  snapshot              $(st_get SNAPSHOT)
Roll back with:  $0 rollback -i $INSTANCE
Delete both with: $0 purge -i $INSTANCE
EOF
}

cmd_shrink() {
  local p
  for p in "${PHASES[@]}"; do
    if [[ $(st_get "done_$p") == 1 ]]; then log "phase $p already done"; continue; fi
    log "=== phase $p"
    "phase_$p"
    st_set "done_$p" 1
  done
}

cmd_status() { [[ -f $STATE_FILE ]] || die "no state for $INSTANCE"; sort "$STATE_FILE"; }

cmd_rollback() {
  [[ -n $(st_get OLD_VOL) ]] || die "no recorded original volume for $INSTANCE"
  set_root_volume "$(st_get OLD_VOL)"
  verify_boot "$(st_get OLD_VOL)" "$(st_get OLD_SIZE)"
  st_set ROLLED_BACK 1
}

cmd_cleanup() { delete_helper; delete_src_copy; }

cmd_purge() {
  local v
  [[ $(root_volume_of_instance) != "$(st_get OLD_VOL)" ]] || die "$(st_get OLD_VOL) is the current root; refusing to delete it"
  v=$(st_get OLD_VOL); [[ -n $v ]] && { log "deleting original volume $v"; ec2 delete-volume --volume-id "$v"; st_del OLD_VOL; }
  v=$(st_get SNAPSHOT); [[ -n $v ]] && { log "deleting snapshot $v"; ec2 delete-snapshot --snapshot-id "$v"; st_del SNAPSHOT; }
}

main() {
COMMAND=${1:-}; shift || true
INSTANCE=; SIZE=; LIVE=false; HELPER_TYPE=; HELPER_AMI=; VOLUME_TYPE=gp3
while [[ $# -gt 0 ]]; do
  case $1 in
    -i|--instance-id) INSTANCE=$2; shift 2 ;;
    -s|--size) SIZE=$2; shift 2 ;;
    --live) LIVE=true; shift ;;
    --helper-type) HELPER_TYPE=$2; shift 2 ;;
    --helper-ami) HELPER_AMI=$2; shift 2 ;;
    --volume-type) VOLUME_TYPE=$2; shift 2 ;;
    --region) export AWS_DEFAULT_REGION=$2; shift 2 ;;
    --profile) export AWS_PROFILE=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ $COMMAND == profile ]] && { ensure_instance_profile; echo $PROFILE_NAME; return; }
[[ -n $INSTANCE ]] || usage
[[ -f $REMOTE_SCRIPT ]] || die "missing $REMOTE_SCRIPT"
STATE_FILE=$STATE_DIR/$INSTANCE.state

case $COMMAND in
  shrink)   cmd_shrink ;;
  status)   cmd_status ;;
  rollback) cmd_rollback ;;
  cleanup)  cmd_cleanup ;;
  purge)    cmd_purge ;;
  *) usage ;;
esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

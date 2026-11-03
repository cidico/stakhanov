#!/usr/bin/env bash
# Machine slots (see "Machine slots" in .agentic/README.md): how many rounds of a ticket and final validations run at
# once on this machine, for every campaign and repository of this user. Sourced by bin/campaign and bin/offload after
# lib/common.sh; it defines functions and variables and runs nothing.
#
# The slots live in <state>/slots: one flock file per slot (slot.0 ... slot.N-1) and a FIFO queue of waiting requests
# (queue/<nanoseconds>.<pid>, one file per request). Only the request at the head of the queue tries the slots, so they
# go in the order they were asked for.
#
# slot_take KIND LABEL takes one (KIND is provider or validation) and exports AGENTIC_SLOT=<n>; slot_release gives it
# back. The lock is never held by the caller itself: a guard process of its own (slot_guard) keeps it, closes every other
# descriptor and ends with its owner, so no command the caller starts inherits the slot, a build server left running
# after it (MSBuild node reuse, VBCSCompiler, an ssh ControlPersist master) never holds it, and the slot comes back when
# the owner dies, even by SIGKILL.
#
# Fixed rules: whoever sees AGENTIC_SLOT already holds one, and never asks for another (nobody waits for a slot with a
# slot in hand); and nobody asks for a slot while holding another lock.
#
# The hooks slot_waiting, slot_taken and slot_stopping report the wait and may end it; bin/campaign replaces them (events
# of the campaign, a stop request).

SLOT_GUARD=''

slot_dir() { printf '%s/slots\n' "${AGENTIC_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agentic}"; }

# This machine's slots: AGENTIC_SLOTS, else machines.<this machine>.slots of the fleet file. Prints nothing when neither
# is set (or AGENTIC_SLOTS is 0): no limit.
slot_capacity() {
  local slots=${AGENTIC_SLOTS:-} self file
  if [[ -z $slots ]]; then
    self=$(fleet_self_name)
    [[ -n $self ]] || return 0
    file=${AGENTIC_FLEET:-${XDG_CONFIG_HOME:-$HOME/.config}/agentic/fleet.json}
    slots=$(jq -r --arg self "$self" '.machines[$self].slots // "" | tostring' "$file" 2>/dev/null) || slots=''
    [[ -z $slots || $slots =~ ^[1-9][0-9]*$ ]] || die "machines.$self.slots in $file must be a positive integer"
  else
    [[ $slots =~ ^[0-9]+$ ]] || die 'AGENTIC_SLOTS must be a non-negative integer (0: no limit)'
    ((10#$slots > 0)) || return 0
  fi
  [[ -z $slots ]] || printf '%s\n' "$((10#$slots))"
}

# slot_start_of PID: sets SLOT_STARTED to the start time of PID (field 22 of /proc/PID/stat), which tells it from a later
# process of the same pid; empty when PID is gone. It starts no process: a waiting request looks at the whole queue.
slot_start_of() {
  local stat
  local -a fields
  SLOT_STARTED=''
  IFS= read -r stat 2>/dev/null <"/proc/$1/stat" || return 1
  IFS=' ' read -r -a fields <<<"${stat##*) }"
  SLOT_STARTED=${fields[19]}
}

# slot_position REQUEST: sets SLOT_POSITION to the 1-based place of REQUEST in the queue, after removing the requests of
# processes that are gone. It starts no process while the queue is alive.
slot_position() {
  local request=$1 file pid kind label started position=0
  for file in "${request%/*}"/[0-9]*.[0-9]*; do
    [[ -f $file ]] || continue
    if [[ $file != "$request" ]]; then
      pid=${file##*.}; pid=$((10#$pid))
      IFS=$'\t' read -r kind label started 2>/dev/null <"$file" || started=''
      slot_start_of "$pid" || true
      if [[ -z $started || $SLOT_STARTED != "$started" ]]; then
        rm -f -- "$file"
        continue
      fi
    fi
    position=$((position + 1))
    [[ $file != "$request" ]] || break
  done
  SLOT_POSITION=$position
}

# slot_queue_length DIR: the requests waiting in the queue of DIR.
slot_queue_length() {
  local file count=0
  for file in "$1"/queue/[0-9]*.[0-9]*; do [[ ! -f $file ]] || count=$((count + 1)); done
  printf '%s\n' "$count"
}

# slot_guard FD: keeps the lock open on FD in a process of its own that ends with this one (tail --pid), with every
# other descriptor closed; its pid in SLOT_GUARD.
slot_guard() {
  local fd=$1 owner=$BASHPID
  (
    for entry in /proc/"$BASHPID"/fd/*; do
      number=${entry##*/}
      ((number <= 2 || number == fd)) || eval "exec $number>&-"
    done
    exec tail --pid="$owner" -f /dev/null </dev/null >/dev/null 2>&1
  ) &
  SLOT_GUARD=$!
}

# Default hooks, for bin/offload: the wait is said on stderr, and it never ends but with a slot.
slot_waiting() { printf 'offload: waiting for a machine slot (%s of %s in the queue, %s slots)\n' "$2" "$3" "$4" >&2; }
slot_taken() { :; }
slot_stopping() { return 1; }

# slot_holders: the slots occupied now, as a JSON list of {slot, kind, label, since} ordered by slot. A slot is occupied
# by whoever has its flock (probed with a shared lock, released at once); its file names the holder, and only then. A
# holder that has the lock but has not written the file yet is listed with null kind, label and since. It changes nothing.
slot_holders() {
  local dir file index fd holders='[]' content
  dir=$(slot_dir)
  for file in "$dir"/slot.[0-9]*; do
    [[ -f $file ]] || continue
    index=${file##*.}
    [[ $index =~ ^[0-9]+$ ]] || continue
    exec {fd}<"$file" || continue
    if flock -n -s "$fd"; then
      exec {fd}<&-
      continue
    fi
    content=$(cat -- "$file" 2>/dev/null) || content=''
    exec {fd}<&-
    holders=$(jq -c --argjson slot "$((10#$index))" --arg content "$content" '
      . + [{slot: $slot} + (($content | try fromjson catch null) as $held
        | if ($held | type) == "object" then {kind: ($held.kind // null), label: ($held.label // null), since: ($held.since // null)}
          else {kind: null, label: null, since: null} end)]' <<<"$holders")
  done
  jq -c 'sort_by(.slot)' <<<"$holders"
}

# slot_sweep CAPACITY TAKEN: empties the slot files that are free (not TAKEN, which this process holds), so that a holder
# that died without releasing (SIGKILL, a die) does not stay named. A slot is occupied by whoever has the flock; the file
# is only information.
slot_sweep() {
  local dir index fd
  dir=$(slot_dir)
  for ((index = 0; index < $1; index++)); do
    ((index != $2)) || continue
    exec {fd}>>"$dir/slot.$index"
    ! flock -n "$fd" || : >"$dir/slot.$index"
    exec {fd}>&-
  done
}

# slot_take KIND LABEL: waits for a slot of this machine in the FIFO queue and holds it (AGENTIC_SLOT=<n>, exported)
# until slot_release or the end of this process. Nothing to do when this process already sees AGENTIC_SLOT or the
# machine has no limit. Fails with 1 when slot_stopping ends the wait, and with 2 when the capacity is misconfigured
# (said on stderr): never with the limit silently off. Never call it in a command substitution: the slot belongs to the
# process that called it.
#
# Only the head of the queue looks at the slots and at the queue every AGENTIC_SLOT_POLL_SECONDS (1); the requests behind
# it look when the queue changes or every AGENTIC_SLOT_CHECK_SECONDS (5, whole seconds), the same pace at which the
# stop request is read.
slot_take() {
  local kind=$1 label=$2 me=$BASHPID capacity dir request entry position=0 said='' index fd
  local check=${AGENTIC_SLOT_CHECK_SECONDS:-5} scanned=$SECONDS stop_checked=$SECONDS seen='-'
  local -a queued
  [[ -z ${AGENTIC_SLOT:-} ]] || return 0
  case $kind in provider | validation) ;; *) die "invalid slot kind: $kind" ;; esac
  capacity=$(slot_capacity) || return 2
  [[ -n $capacity ]] || return 0
  dir=$(slot_dir)
  mkdir -p -- "$dir/queue"
  chmod 700 "$dir" "$dir/queue"
  # The request carries the start time of this process, so a later process with the same pid is not taken for it.
  slot_start_of "$me" || true
  printf -v request '%s/queue/%s.%010d' "$dir" "$(date +%s%N)" "$me"
  entry=$(printf '%s\t%s\t%s' "$kind" "$label" "$SLOT_STARTED")
  printf '%s\n' "$entry" >"$dir/queue/.new.$me"
  mv -f -- "$dir/queue/.new.$me" "$request"
  while :; do
    queued=("$dir"/queue/[0-9]*)
    if ((position == 1)) || [[ ${queued[*]} != "$seen" ]] || ((SECONDS - scanned >= check)); then
      seen=${queued[*]}
      scanned=$SECONDS
      [[ -f $request ]] || printf '%s\n' "$entry" >"$request"
      slot_position "$request"
      position=$SLOT_POSITION
      if ((position == 1)); then
        for ((index = 0; index < capacity; index++)); do
          exec {fd}>>"$dir/slot.$index"
          if flock -n "$fd"; then
            slot_guard "$fd"
            exec {fd}>&-
            export AGENTIC_SLOT=$index
            jq -cn --argjson pid "$me" --arg kind "$kind" --arg label "$label" --arg since "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '{pid:$pid,kind:$kind,label:$label,since:$since}' >"$dir/slot.$index"
            slot_sweep "$capacity" "$index"
            slot_taken "$kind" "$index" "$capacity"
            # Only now does the next request become the head of the queue.
            rm -f -- "$request"
            return 0
          fi
          exec {fd}>&-
        done
      fi
      if [[ $position != "$said" ]]; then
        slot_waiting "$kind" "$position" "$(slot_queue_length "$dir")" "$capacity"
        said=$position
      fi
    fi
    if ((SECONDS - stop_checked >= check)); then
      stop_checked=$SECONDS
      if slot_stopping "$kind"; then
        rm -f -- "$request"
        return 1
      fi
    fi
    sleep "${AGENTIC_SLOT_POLL_SECONDS:-1}"
  done
}

# slot_release: gives back the slot this process took (nothing when it took none).
slot_release() {
  [[ -n $SLOT_GUARD ]] || return 0
  : >"$(slot_dir)/slot.$AGENTIC_SLOT"
  kill "$SLOT_GUARD" 2>/dev/null || true
  wait "$SLOT_GUARD" 2>/dev/null || true
  SLOT_GUARD=''
  unset AGENTIC_SLOT
}

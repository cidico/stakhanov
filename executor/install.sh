#!/usr/bin/env bash
# install.sh DEST [--config FILE] [--dry-run]: installs or updates the executor package on the host DEST (an ssh
# destination that logs in as root, for example root@build-box), from the controlling machine; see README.md. Running it
# again is safe. It copies the package to /usr/local/lib/agentic-executor and FILE to /etc/agentic/executor.conf
# (without --config the host keeps its settings), then, as root there: creates the run user and group; the mirror root,
# the state, account and bound folders (setgid, group-writable, with default ACLs); the systemd slice with the
# configured caps and, when EXECUTOR_NETNS is set, agentic-executor-netns.service; links the commands into
# /usr/local/bin. It touches nothing else. Last it prints the executors entry to paste into the project's
# .agentic/project.json. --dry-run checks the settings and prints the plan and the entry, changing nothing (it reads the
# host's settings when --config is not given). AGENTIC_SSH replaces the ssh command, as for the engine.
set -euo pipefail

package=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)
LIB=/usr/local/lib/agentic-executor
CONF=/etc/agentic/executor.conf
COMMANDS=(agentic-executor-run agentic-executor-admit agentic-executor-status agentic-executor-netns)

usage() {
  printf 'usage: install.sh DEST [--config FILE] [--dry-run]\n' >&2
  exit 64
}
die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

dest='' config='' dry_run=false
while (($#)); do
  case $1 in
    --config) (($# >= 2)) || usage; config=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -*) usage ;;
    *) [[ -z $dest ]] || usage; dest=$1; shift ;;
  esac
done
[[ -n $dest ]] || usage
[[ $dest =~ ^[^-[:space:]][^[:space:]]*$ ]] || die "not an ssh destination: $dest"
[[ -z $config || -r $config ]] || die "cannot read $config"
command -v jq >/dev/null 2>&1 || die 'jq is required on this machine'
IFS=' ' read -r -a ssh_command <<<"${AGENTIC_SSH:-ssh}"
remote() { "${ssh_command[@]}" -o BatchMode=yes "$dest" "$@"; }
# remote_bash SCRIPT ARG...: SCRIPT run by bash as root on DEST, with ARG... as its positional parameters; this
# script's stdin goes to it.
remote_bash() {
  local command
  command=$(printf '%q ' bash -c "$1" agentic-install "${@:2}")
  remote "${command% }"
}

temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

# 1. The settings, checked here before anything changes there.
if [[ -n $config ]]; then
  cp -- "$config" "$temporary/executor.conf"
else
  remote cat "$CONF" </dev/null >"$temporary/executor.conf" 2>/dev/null \
    || die "$dest has no $CONF yet: pass --config FILE (start from $package/executor.conf.example)"
fi
mapfile -t settings < <(AGENTIC_EXECUTOR_CONF="$temporary/executor.conf" bash -c '. "$1/lib/config.sh" && executor_config_load \
  && printf "%s\n" "$EXECUTOR_ROOT" "$EXECUTOR_UNITS" "$EXECUTOR_WORKER_UNITS" "$EXECUTOR_USER" "$EXECUTOR_GROUP" \
     "$EXECUTOR_STATE_DIR" "$EXECUTOR_ACCOUNTS_DIR" "$EXECUTOR_SLICE" "${EXECUTOR_CPU_QUOTA:-none}" \
     "${EXECUTOR_MEMORY_MAX:-none}" "${EXECUTOR_NETNS:-}" "$EXECUTOR_BIND_PATHS"' install.sh "$package")
((${#settings[@]} == 12)) || die 'fix the settings first'
root=${settings[0]} units=${settings[1]} worker_units=${settings[2]}

# The executors entry for the project, named after the host.
entry() {
  local host name
  host=${dest##*@}
  name=$(tr '[:upper:]' '[:lower:]' <<<"$host" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')
  jq -n --arg name "${name:-executor}" --arg ssh "$dest" --argjson workers "$((units / worker_units))" --arg root "$root" \
    --argjson worker_units "$worker_units" \
    '{name: $name, ssh: $ssh, workers: $workers, root: $root, run: ["/usr/local/bin/agentic-executor-run"],
      admit: ["/usr/local/bin/agentic-executor-admit"], worker_units: $worker_units, rsync_options: ["--chmod=g+rwX"],
      exclude: [], requires: [], env: {}}'
}

if $dry_run; then
  printf 'install.sh: dry run; nothing changes on %s. It would:\n' "$dest"
  printf '  - copy the package (bin, lib, accounts) to %s and link %s into /usr/local/bin\n' "$LIB" "${COMMANDS[*]}"
  if [[ -n $config ]]; then printf '  - install %s as %s\n' "$config" "$CONF"; else printf '  - keep %s\n' "$CONF"; fi
  printf '  - create the user %s and the group %s when missing\n' "${settings[3]}" "${settings[4]}"
  printf '  - create %s, %s (units, runs, accounts) and %s, and present %s from %s\n' "$root" "${settings[5]}" \
    "${settings[6]}" "${settings[11]}" "$root"
  printf '  - write %s (CPUQuota %s, MemoryMax %s)\n' "${settings[7]}" "${settings[8]}" "${settings[9]}"
  if [[ -n ${settings[10]} ]]; then
    printf '  - enable agentic-executor-netns.service (namespace %s)\n' "${settings[10]}"
  else
    printf '  - leave the runs on the host network (no EXECUTOR_NETNS)\n'
  fi
  printf 'The executors entry for the project:\n'
  entry
  exit 0
fi

# 2. The package, replaced in one rename (a run that already started keeps reading its files), and the settings.
read -r -d '' UNPACK <<'SCRIPT' || true
set -eu
lib=$1
rm -rf "$lib.new" "$lib.old"
mkdir -p "$lib.new"
tar -C "$lib.new" --no-same-owner -xf -
chown -R root:root "$lib.new"
chmod -R go-w,a+rX "$lib.new"
if [ -e "$lib" ]; then mv "$lib" "$lib.old"; fi
mv "$lib.new" "$lib"
rm -rf "$lib.old"
SCRIPT
read -r -d '' PUT_CONF <<'SCRIPT' || true
set -eu
conf=$1
install -d -m 755 "$(dirname "$conf")"
umask 022
cat >"$conf.new"
mv -f "$conf.new" "$conf"
SCRIPT
tar -C "$package" -cf - bin lib accounts README.md executor.conf.example | remote_bash "$UNPACK" "$LIB" \
  || die "could not copy the package to $dest (it must log in as root)"
if [[ -n $config ]]; then
  remote_bash "$PUT_CONF" "$CONF" <"$temporary/executor.conf" || die "could not install the settings on $dest"
fi

# 3. The host, as root.
read -r -d '' SETUP <<'SCRIPT' || true
set -euo pipefail
lib=$1 dest=$2
say() { printf 'install.sh: %s\n' "$*"; }
[ "$(id -u)" = 0 ] || { say "log in as root on the executor (this is $(id -un))" >&2; exit 2; }
[ -d /run/systemd/system ] || { say 'the executor must run systemd' >&2; exit 2; }
. "$lib/lib/config.sh"
executor_config_load
missing=()
for command in bash git rsync setsid flock ps systemd-run systemctl setpriv unshare mount install useradd groupadd usermod setfacl; do
  command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
[[ -z $EXECUTOR_NETNS ]] || command -v ip >/dev/null 2>&1 || missing+=(ip)
((${#missing[@]} == 0)) || { say "install the missing commands first: ${missing[*]}" >&2; exit 2; }

# The run user and its group.
getent group "$EXECUTOR_GROUP" >/dev/null || { groupadd --system "$EXECUTOR_GROUP"; say "created the group $EXECUTOR_GROUP"; }
if ! id -u "$EXECUTOR_USER" >/dev/null 2>&1; then
  useradd --system --gid "$EXECUTOR_GROUP" --no-create-home --home-dir "${EXECUTOR_BINDS[0]}" --shell /usr/sbin/nologin \
    "$EXECUTOR_USER"
  say "created the user $EXECUTOR_USER"
fi
for group in $EXECUTOR_USER_GROUPS; do
  if getent group "$group" >/dev/null; then usermod -a -G "$group" "$EXECUTOR_USER"; else say "no group $group here; $EXECUTOR_USER is not in it"; fi
done

# Folders. The ssh login (root) writes the mirrored files and the run user changes them: the shared ones are setgid to
# the run group and group-writable, closed to every other user, and default ACLs keep what root creates there
# writable by the group.
shared=("$EXECUTOR_ROOT" "$EXECUTOR_STATE_DIR" "$EXECUTOR_STATE_DIR/units" "$EXECUTOR_STATE_DIR/runs")
for path in "${EXECUTOR_BINDS[@]}"; do shared+=("$EXECUTOR_ROOT$path"); done
install -d -- "${shared[@]}"
chown root:"$EXECUTOR_GROUP" -- "${shared[@]}"
chmod 2770 -- "${shared[@]}"
install -d -m 2770 -o "$EXECUTOR_USER" -g "$EXECUTOR_GROUP" -- "$EXECUTOR_STATE_DIR/accounts"
install -d -m 700 -o "$EXECUTOR_USER" -g "$EXECUTOR_GROUP" -- "$EXECUTOR_ACCOUNTS_DIR"
for account in "${EXECUTOR_ACCOUNT_NAMES[@]}"; do
  install -d -m 700 -o "$EXECUTOR_USER" -g "$EXECUTOR_GROUP" -- "$EXECUTOR_ACCOUNTS_DIR/$account"
done
# The mount points of the bound paths; an existing folder (a real home) is left as it is.
for path in "${EXECUTOR_BINDS[@]}"; do [ -d "$path" ] || install -d -m 755 -- "$path"; done
# Required: the synced files arrive owned by root (owners never travel), and the run user changes them through this
# group entry.
for path in "$EXECUTOR_ROOT" "${EXECUTOR_BINDS[@]/#/$EXECUTOR_ROOT}"; do
  setfacl -m "g:$EXECUTOR_GROUP:rwX,d:g:$EXECUTOR_GROUP:rwX" -- "$path"
done

# systemd units, rewritten only when they change.
reload=false
write_unit() { # FILE CONTENT: true when FILE changed
  printf '%s\n' "$2" >"$1.new"
  if cmp -s "$1.new" "$1"; then rm -f "$1.new"; return 1; fi
  mv -f "$1.new" "$1"
  reload=true
}
slice=$(printf '[Unit]\nDescription=Stakhanov executor runs (agentic-executor-run)\n\n[Slice]\nCPUWeight=20\nIOWeight=20')
[[ -z $EXECUTOR_CPU_QUOTA ]] || slice+=$'\n'"CPUQuota=$EXECUTOR_CPU_QUOTA"
[[ -z $EXECUTOR_MEMORY_MAX ]] || slice+=$'\n'"MemoryMax=$EXECUTOR_MEMORY_MAX"
slice_changed=false
write_unit "/etc/systemd/system/$EXECUTOR_SLICE" "$slice" && slice_changed=true
netns_unit=/etc/systemd/system/agentic-executor-netns.service
netns_changed=false
if [[ -n $EXECUTOR_NETNS ]]; then
  after=${EXECUTOR_NETNS_AFTER:+ $EXECUTOR_NETNS_AFTER}
  unit="[Unit]
Description=Network namespace $EXECUTOR_NETNS of the Stakhanov executor runs
Wants=network-online.target
After=network-online.target$after${EXECUTOR_NETNS_AFTER:+
BindsTo=$EXECUTOR_NETNS_AFTER}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/agentic-executor-netns up
ExecStop=/usr/local/bin/agentic-executor-netns down

[Install]
WantedBy=multi-user.target$after"
  write_unit "$netns_unit" "$unit" && netns_changed=true
elif [ -e "$netns_unit" ]; then
  systemctl disable --now agentic-executor-netns.service >/dev/null 2>&1 || true
  rm -f "$netns_unit"
  reload=true
  say 'removed agentic-executor-netns.service (EXECUTOR_NETNS is empty)'
fi

for command in agentic-executor-run agentic-executor-admit agentic-executor-status agentic-executor-netns; do
  ln -sfn "$lib/bin/$command" "/usr/local/bin/$command"
done
if $reload; then systemctl daemon-reload; fi
if $slice_changed; then say "wrote $EXECUTOR_SLICE"; fi
if [[ -n $EXECUTOR_NETNS ]]; then
  systemctl enable agentic-executor-netns.service >/dev/null 2>&1
  if $netns_changed; then systemctl restart agentic-executor-netns.service; else systemctl start agentic-executor-netns.service; fi
fi

[ -x "$EXECUTOR_CLAUDE" ] || say "note: no claude at $EXECUTOR_CLAUDE yet; install it there (README.md) before sending workers"
for account in "${EXECUTOR_ACCOUNT_NAMES[@]}"; do
  [ -s "$EXECUTOR_ACCOUNTS_DIR/$account/token" ] || say "note: account $account has no token yet: executor/token.sh $dest $account"
done
say "the package is installed in $lib"
SCRIPT
remote_bash "$SETUP" "$LIB" "$dest" </dev/null || die "setting up $dest failed"

printf 'The executors entry for the project (.agentic/project.json; add its exclude, requires and env):\n'
entry

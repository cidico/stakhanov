#!/usr/bin/env bash
# Tests of the executor package without root or a host: stub systemd-run, systemctl, ip, setpriv, unshare, mount, ssh
# and claude on PATH, and settings of temporary folders (AGENTIC_EXECUTOR_CONF). Real-host behavior (user switch, mount
# and network namespaces, the slice) is proven on a real executor.
#   bash executor/tests/executor.sh
set -uo pipefail

PACKAGE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
log=$work/log

n=0
failures=0
ok() { n=$((n + 1)); printf 'ok %d - %s\n' "$n" "$1"; }
not_ok() { n=$((n + 1)); failures=$((failures + 1)); printf 'not ok %d - %s\n' "$n" "$1"; }
# t DESCRIPTION COMMAND...: the test passes when the command succeeds.
t() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else not_ok "$description"; fi
}
not() { ! "$@"; }
has() { grep -Fq -- "$2" <<<"$1"; }
has_line() { grep -Fxq -- "$2" <<<"$1"; }
lacks() { ! grep -Fq -- "$2" <<<"$1"; }
# wait_for FILE: true once FILE exists (up to 10 seconds).
wait_for() { local _; for _ in $(seq 100); do [[ -e $1 ]] && return 0; sleep 0.1; done; return 1; }

# --- Stubs: they log their arguments and run the command they wrap, without privileges.
stubs=$work/stubs
mkdir -p "$stubs"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$stubs/$1"; chmod +x "$stubs/$1"; }
stub systemd-run "printf 'systemd-run %s\n' \"\$*\" >>'$log'; while [ \"\$1\" != -- ]; do shift; done; shift; exec \"\$@\""
# Stopping a scope kills the process the test recorded as its run.
stub systemctl "printf 'systemctl %s\n' \"\$*\" >>'$log'; if [ \"\$1\" = stop ] && [ -s '$work/scope-pid' ]; then kill \"\$(cat '$work/scope-pid')\" 2>/dev/null; fi"
stub ip "printf 'ip %s\n' \"\$*\" >>'$log'; if [ \"\$1 \$2\" = 'netns exec' ]; then shift 3; exec \"\$@\"; fi"
stub setpriv "printf 'setpriv %s\n' \"\$*\" >>'$log'; while [ \"\${1#--}\" != \"\$1\" ]; do shift; done; exec \"\$@\""
stub unshare "printf 'unshare %s\n' \"\$*\" >>'$log'; while [ \"\$1\" != -- ]; do shift; done; shift; exec \"\$@\""
stub mount "printf 'mount %s\n' \"\$*\" >>'$log'"
stub ssh "printf 'ssh %s\n' \"\$*\" >>'$log'; cat >'$work/ssh-stdin'; case \"\$*\" in *'cat /etc/agentic/executor.conf'*) cat '$work/executor.conf' ;; esac"
stub claude "printf 'claude %s\n' \"\$*\" >>'$log'; echo 'Your token is shown above.'"
export PATH="$stubs:$PATH"

# --- Settings of temporary folders.
accounts=$work/accounts
cat >"$work/executor.conf" <<EOF
EXECUTOR_USER=agentic-test
EXECUTOR_ROOT=$work/root
EXECUTOR_BIND_PATHS="$work/home $work/data"
EXECUTOR_STATE_DIR=$work/state
EXECUTOR_UNITS=3
EXECUTOR_WORKER_UNITS=1
EXECUTOR_SLICE=agentic-test.slice
EXECUTOR_NETNS=agentic-test
EXECUTOR_NETNS_BRIDGE=br-test
EXECUTOR_NETNS_ADDRESS=10.9.0.2/24
EXECUTOR_PROXY=http://10.9.0.1:3128
EXECUTOR_NO_PROXY=localhost,10.9.0.0/24
EXECUTOR_ACCOUNTS_DIR=$accounts
EXECUTOR_ACCOUNTS="work personal"
EXECUTOR_CLAUDE=$work/real-claude
EXECUTOR_ENV_FILE=$work/executor.env
EXECUTOR_PATH=/opt/tools/bin
EXECUTOR_UNITS_POLL_SECONDS=0.1
EOF
export AGENTIC_EXECUTOR_CONF=$work/executor.conf
mkdir -p "$work/state/units" "$work/state/runs"
printf '# comment\nFROM_FILE=1\nAGENTIC_FORWARDED=from-file\nnot a variable\n' >"$work/executor.env"

hook=$PACKAGE/accounts/agentic-executor-accounts
admit=$PACKAGE/bin/agentic-executor-admit
run=$PACKAGE/bin/agentic-executor-run
status=$PACKAGE/bin/agentic-executor-status
# units FUNCTION ARG...: a function of lib/units.sh in a shell of its own; holding SCRIPT: SCRIPT there.
units() { bash -c '. "$1/lib/config.sh" && executor_config_load && . "$1/lib/units.sh" && shift && "$@"' units "$PACKAGE" "$@"; }
holding() { bash -c '. "$1/lib/config.sh" && executor_config_load && . "$1/lib/units.sh" && eval "$2"' units "$PACKAGE" "$1"; }

# --- Settings.
t 'settings: the test settings load' bash -c '. "$1/lib/config.sh" && executor_config_load' _ "$PACKAGE"
t 'settings: the example is complete but for EXECUTOR_BIND_PATHS' bash -c \
  'out=$(AGENTIC_EXECUTOR_CONF=$1/executor.conf.example bash -c ". $1/lib/config.sh && executor_config_load" 2>&1); [[ $? -ne 0 && $out == *EXECUTOR_BIND_PATHS* ]]' _ "$PACKAGE"
printf 'EXECUTOR_BIND_PATHS=/home/x\nEXECUTOR_UNITS=2\nEXECUTOR_WORKER_UNITS=3\n' >"$work/bad.conf"
t 'settings: worker units above the total are refused' bash -c \
  '! AGENTIC_EXECUTOR_CONF=$2 bash -c ". $1/lib/config.sh && executor_config_load"' _ "$PACKAGE" "$work/bad.conf"

# --- The account hook.
t 'accounts: disabled while no account has a token' bash -c '! "$1" account enabled' _ "$hook"
mkdir -p "$accounts/work" "$accounts/personal"
printf 'sk-ant-work-token\n' >"$accounts/work/token"
printf 'sk-ant-personal-token' >"$accounts/personal/token"
t 'accounts: enabled once an account has a token' "$hook" account enabled
OUT=$(CLAUDE_CONFIG_DIR=$accounts/personal "$hook" account current)
t 'accounts: current is CLAUDE_CONFIG_DIR while it is available' [ "$OUT" = "$accounts/personal" ]
OUT=$(env -u CLAUDE_CONFIG_DIR "$hook" account current)
t 'accounts: current without CLAUDE_CONFIG_DIR is the first account' [ "$OUT" = "$accounts/work" ]
OUT=$("$hook" account env "$accounts/work")
t 'accounts: env prints the env prefix of the account' [ "$OUT" = "env CLAUDE_CONFIG_DIR=$(printf '%q' "$accounts/work")" ]
t 'accounts: pick gives the first available account' [ "$("$hook" account pick)" = "$accounts/work" ]
t 'accounts: pick skips the excluded ones' [ "$("$hook" account pick "$accounts/work")" = "$accounts/personal" ]
t 'accounts: a failure that is no usage limit exits 1 and marks nothing' bash -c \
  '! "$1" account limit "$2/work" <<<"Error: network unreachable" && [ ! -e "$3/state/accounts/work.out-until" ]' _ "$hook" "$accounts" "$work"
expected=$(python3 -c '
import datetime, zoneinfo
zone = zoneinfo.ZoneInfo("UTC"); now = datetime.datetime.now(zone)
when = now.replace(hour=15, minute=30, second=0, microsecond=0)
print(int((when if when > now else when + datetime.timedelta(days=1)).timestamp()))')
OUT=$("$hook" account limit "$accounts/work" <<<"You've hit your limit · resets 3:30pm (UTC)")
t 'accounts: a usage limit prints the next account' [ "$OUT" = "$accounts/personal" ]
t 'accounts: the account is out until the reset its message names' [ "$(cat "$work/state/accounts/work.out-until")" = "$expected" ]
OUT=$(CLAUDE_CONFIG_DIR=$accounts/work "$hook" account current)
t 'accounts: current moves past an account that is out' [ "$OUT" = "$accounts/personal" ]
OUT=$("$hook" account next)
t 'accounts: next is now while an account is available' bash -c '(( $1 >= $(date +%s) - 2 && $1 <= $(date +%s) ))' _ "$OUT"
before=$(date +%s)
"$hook" account limit "$accounts/personal" <<<"Claude AI usage limit reached" >/dev/null
t 'accounts: no account left exits 75' [ $? -eq 75 ]
OUT=$(cat "$work/state/accounts/personal.out-until")
t 'accounts: a limit without a reset time is out for an hour' bash -c '(( $1 >= $2 + 3600 && $1 <= $2 + 3602 ))' _ "$OUT" "$before"
t 'accounts: next is the earliest reset when every account is out' [ "$("$hook" account next)" = "$((expected < OUT ? expected : OUT))" ]
OUT=$(CLAUDE_CONFIG_DIR=$accounts/work "$hook" account current)
t 'accounts: current keeps CLAUDE_CONFIG_DIR when every account is out' [ "$OUT" = "$accounts/work" ]
expected=$(python3 -c '
import datetime, zoneinfo
zone = zoneinfo.ZoneInfo("Europe/Lisbon"); now = datetime.datetime.now(zone)
when = now.replace(month=1, day=5, hour=9, minute=0, second=0, microsecond=0)
print(int((when if when > now else when.replace(year=now.year + 1)).timestamp()))')
"$hook" account limit "$accounts/work" <<<"5-hour limit reached ∙ hit your limit · resets Jan 5, 9am (Europe/Lisbon)" >/dev/null
t 'accounts: a reset with a date is read in its zone' [ "$(cat "$work/state/accounts/work.out-until")" = "$expected" ]
rm -f "$work/state/accounts/"*.out-until

# --- The claude wrapper.
cat >"$work/real-claude" <<EOF
#!/usr/bin/env bash
printf 'token=%s config=%s autoupdater=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN:-}" "\${CLAUDE_CONFIG_DIR:-}" "\${DISABLE_AUTOUPDATER:-}"
printf '%s\n' "\$@" >'$work/claude-argv'
EOF
chmod +x "$work/real-claude"
OUT=$(CLAUDE_CONFIG_DIR=$accounts/personal "$PACKAGE/accounts/claude" --print 'a prompt')
t 'claude: the token of CLAUDE_CONFIG_DIR is in the environment' [ "$OUT" = "token=sk-ant-personal-token config=$accounts/personal autoupdater=1" ]
t 'claude: the arguments pass through, the token never among them' [ "$(cat "$work/claude-argv")" = $'--print\na prompt' ]
OUT=$(env -u CLAUDE_CONFIG_DIR "$PACKAGE/accounts/claude" --version)
t 'claude: without CLAUDE_CONFIG_DIR the first account logs in' [ "$OUT" = "token=sk-ant-work-token config=$accounts/work autoupdater=1" ]

# --- Units: try, wait and admit.
t 'units: admit accepts what is free' "$admit" 3
OUT=$("$admit" 4)
t 'units: admit refuses more than the executor has' has "$OUT" 'asks 4 units; this executor has 3'
holding "executor_units_try 2 && touch '$work/held' && until [ -e '$work/release' ]; do sleep 0.1; done" &
holder=$!
wait_for "$work/held"
OUT=$("$admit" 2)
t 'units: admit refuses while the units are held' [ "$OUT" = 'free=1/3 waiting=no' ]
t 'units: admit takes AGENTIC_UNITS when no count is given' env AGENTIC_UNITS=1 "$admit"
t 'units: try fails for more than is free' not units executor_units_try 2
t 'units: try takes what is free' units executor_units_try 1
holding "executor_units_wait 2 && touch '$work/waited'" 2>"$work/wait.err" &
waiter=$!
wait_for "$work/state/units/waiting"
t 'units: a waiting run says so' grep -q 'busy; waiting for 2 of 3 units' "$work/wait.err"
t 'units: while a run waits, admit refuses even what is free' bash -c '[ "$("$1" 1)" = "free=1/3 waiting=yes" ]' _ "$admit"
t 'units: while a run waits, try refuses' not units executor_units_try 1
touch "$work/release"
wait "$holder"
t 'units: the waiting run gets its units once they are released' wait_for "$work/waited"
wait "$waiter"
t 'units: the waiting marker goes away' test ! -e "$work/state/units/waiting"
t 'units: every unit is free again' "$admit" 3
OUT=$("$status")
t 'status: free units and accounts' bash -c 'has_line() { grep -Fxq -- "$2" <<<"$1"; }; has_line "$1" "free=3/3 waiting=no" && has_line "$1" "account work: ready"' _ "$OUT"

# --- The run prefix.
cat >"$work/probe" <<EOF
#!/usr/bin/env bash
env | sort >'$work/probe-env'
printf '%s\n' "\$@" >'$work/probe-args'
pwd >'$work/probe-pwd'
'$admit' 3 >/dev/null; printf '%s\n' "\$?" >'$work/probe-admit3'
'$admit' 1 >/dev/null; printf '%s\n' "\$?" >'$work/probe-admit1'
'$status' >'$work/probe-status'
exit "\${PROBE_EXIT:-0}"
EOF
chmod +x "$work/probe"
: >"$log"
OUT=$(LEAKED=1 AGENTIC_UNITS=2 "$run" env AGENTIC_FORWARDED=runner AGENTIC_CLAUDE_ACCOUNTS=udarnik CLAUDE_CONFIG_DIR=/elsewhere \
  AGENTIC_EXECUTOR_RUN=0 "$work/probe" one 'two words' 2>&1)
t 'run: the command succeeds' [ $? -eq 0 ]
ENV=$(cat "$work/probe-env")
t 'run: the arguments arrive intact' [ "$(cat "$work/probe-args")" = $'one\ntwo words' ]
t 'run: it runs from the first bound path' [ "$(cat "$work/probe-pwd")" = "$work/home" ]
t 'run: HOME is the first bound path' has_line "$ENV" "HOME=$work/home"
t 'run: USER is the run user' has_line "$ENV" 'USER=agentic-test'
t 'run: PATH starts with the package accounts folder and EXECUTOR_PATH' \
  has_line "$ENV" "PATH=$PACKAGE/accounts:/opt/tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
t 'run: the proxies are set' bash -c 'grep -Fxq "https_proxy=http://10.9.0.1:3128" <<<"$1" && grep -Fxq "NO_PROXY=localhost,10.9.0.0/24" <<<"$1"' _ "$ENV"
t 'run: the env file adds its variables' has_line "$ENV" 'FROM_FILE=1'
t 'run: the runner variables win over the env file' has_line "$ENV" 'AGENTIC_FORWARDED=runner'
t 'run: AGENTIC_EXECUTOR_RUN=1 always wins' has_line "$ENV" 'AGENTIC_EXECUTOR_RUN=1'
t 'run: the account hook is the package one, whatever the runner forwarded' \
  has_line "$ENV" "AGENTIC_CLAUDE_ACCOUNTS=$PACKAGE/accounts/agentic-executor-accounts"
t 'run: CLAUDE_CONFIG_DIR is the first account' has_line "$ENV" "CLAUDE_CONFIG_DIR=$accounts/work"
t 'run: the run knows its settings and its units' bash -c 'grep -Fxq "AGENTIC_EXECUTOR_CONF=$2" <<<"$1" && grep -Fxq "AGENTIC_UNITS=2" <<<"$1"' _ "$ENV" "$work/executor.conf"
t 'run: nothing else of the caller leaks in' lacks "$ENV" 'LEAKED='
t 'run: it holds AGENTIC_UNITS units while it runs' bash -c '[ "$(cat "$1/probe-admit3")" = 1 ] && [ "$(cat "$1/probe-admit1")" = 0 ]' _ "$work"
t 'run: status shows it running with its units' bash -c 'grep -Eq "^running agentic-run-[0-9]+-[0-9]+ units=2 for 0m: $2 one two words$" "$1/probe-status"' _ "$work" "$work/probe"
LOG=$(cat "$log")
t 'run: a scope in the slice' bash -c 'grep -Eq "^systemd-run --scope --quiet --unit=agentic-run-[0-9]+-[0-9]+ --slice=agentic-test.slice " <<<"$1"' _ "$LOG"
t 'run: every bound path is mounted from the root' bash -c 'grep -Fxq "mount --bind $2/root$2/home $2/home" <<<"$1" && grep -Fxq "mount --bind $2/root$2/data $2/data" <<<"$1"' _ "$LOG" "$work"
t 'run: in the network namespace' bash -c 'grep -q "^ip netns exec agentic-test setpriv " <<<"$1"' _ "$LOG"
t 'run: as the run user' bash -c 'grep -q "^setpriv --reuid=agentic-test --regid=agentic-test --init-groups env -i " <<<"$1"' _ "$LOG"
t 'run: the scope is stopped at the end' bash -c 'grep -Eq "^systemctl stop agentic-run-[0-9]+-[0-9]+\.scope$" <<<"$1"' _ "$LOG"
t 'run: the units are free again afterwards' "$admit" 3
t 'run: its record is gone' bash -c '[ -z "$(ls -A "$1/state/runs")" ]' _ "$work"
"$run" env PROBE_EXIT=7 "$work/probe" >/dev/null 2>&1
t 'run: the exit status is the command one' [ $? -eq 7 ]
t 'run: without env words the forced variables still arrive' has_line "$(cat "$work/probe-env")" 'AGENTIC_EXECUTOR_RUN=1'
t 'run: the default is EXECUTOR_WORKER_UNITS' has_line "$(cat "$work/probe-env")" 'AGENTIC_UNITS=1'
AGENTIC_UNITS=0 "$run" "$work/probe" >/dev/null 2>&1
t 'run: AGENTIC_UNITS=0 takes no unit' [ "$(cat "$work/probe-admit3")" = 0 ]
OUT=$(AGENTIC_UNITS=4 "$run" "$work/probe" 2>&1)
t 'run: more units than the executor has exits 64' bash -c '[ "$1" -eq 64 ] && grep -q "AGENTIC_UNITS=4, but this executor has 3 units" <<<"$2"' _ $? "$OUT"

# A run waits while its units are busy, and starts once they are released.
rm -f "$work/held" "$work/release" "$work/probe-pwd"
holding "executor_units_try 3 && touch '$work/held' && until [ -e '$work/release' ]; do sleep 0.1; done" &
holder=$!
wait_for "$work/held"
"$run" "$work/probe" >/dev/null 2>"$work/run-wait.err" &
waiting_run=$!
wait_for "$work/state/units/waiting"
sleep 0.3
t 'run: it waits while its units are busy' test ! -e "$work/probe-pwd"
t 'run: status shows it waiting' bash -c '"$1" | grep -Eq "^waiting agentic-run-[0-9]+-[0-9]+ units=1 "' _ "$status"
touch "$work/release"
wait "$holder"
wait "$waiting_run"
t 'run: it runs once the units are released' test -e "$work/probe-pwd"
t 'run: it said it was waiting' has "$(cat "$work/run-wait.err")" 'busy; waiting for 1 of 3 units'

# TERM stops the scope and exits 143.
: >"$log"
cat >"$work/sleeper" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$\$" >'$work/scope-pid'
touch '$work/sleeping'
exec sleep 30
EOF
chmod +x "$work/sleeper"
"$run" "$work/sleeper" >/dev/null 2>&1 &
sleeping_run=$!
wait_for "$work/sleeping"
kill -TERM "$sleeping_run"
wait "$sleeping_run"
t 'run: TERM exits 143' [ $? -eq 143 ]
t 'run: TERM stops the scope' bash -c 'grep -Eq "^systemctl stop agentic-run-[0-9]+-[0-9]+\.scope$" "$1"' _ "$log"
t 'run: TERM releases the units' "$admit" 3
rm -f "$work/scope-pid"

# --- install.sh, without touching a host (--dry-run).
: >"$log"
OUT=$(bash "$PACKAGE/install.sh" root@Build.Box --config "$work/executor.conf" --dry-run 2>&1)
t 'install: a dry run succeeds' [ $? -eq 0 ]
t 'install: a dry run never calls ssh with --config' bash -c '! grep -q "^ssh " "$1"' _ "$log"
ENTRY=$(sed -n '/^{/,/^}/p' <<<"$OUT")
t 'install: the entry is named after the host and points at the package' bash -c '
  jq -e --arg root "$2/root" ".name == \"build-box\" and .ssh == \"root@Build.Box\" and .root == \$root and .workers == 3
    and .worker_units == 1 and .run == [\"/usr/local/bin/agentic-executor-run\"]
    and .admit == [\"/usr/local/bin/agentic-executor-admit\"] and .rsync_options == [\"--chmod=g+rwX\"]" <<<"$1"' _ "$ENTRY" "$work"
t 'install: the plan names the slice and the namespace' bash -c 'grep -q "agentic-test.slice" <<<"$1" && grep -q "namespace agentic-test" <<<"$1"' _ "$OUT"
OUT=$(AGENTIC_SSH=$stubs/ssh bash "$PACKAGE/install.sh" root@box --dry-run 2>&1 </dev/null)
t 'install: without --config it reads the host settings' bash -c '[ "$1" -eq 0 ] && grep -q "keep /etc/agentic/executor.conf" <<<"$2"' _ $? "$OUT"
OUT=$(bash "$PACKAGE/install.sh" root@box --config "$work/bad.conf" --dry-run 2>&1)
t 'install: invalid settings stop it' bash -c '[ "$1" -ne 0 ] && grep -q "fix the settings first" <<<"$2"' _ $? "$OUT"

# --- token.sh: the token goes on ssh's stdin, never in a command line.
: >"$log"; rm -f "$work/ssh-stdin"
OUT=$(printf 'sk-ant-oat01-secret\n' | AGENTIC_SSH=$stubs/ssh bash "$PACKAGE/token.sh" root@box work 2>&1)
t 'token: it succeeds' [ $? -eq 0 ]
t 'token: claude setup-token runs here' bash -c 'grep -Fxq "claude setup-token" "$1"' _ "$log"
t 'token: the token reaches the executor on stdin' [ "$(cat "$work/ssh-stdin")" = sk-ant-oat01-secret ]
t 'token: the token is in no command line' bash -c '! grep -q "secret" "$1"' _ "$log"
t 'token: the ssh command stores it for the account' bash -c 'grep -q "^ssh -o BatchMode=yes root@box bash -c .* agentic-token work$" "$1"' _ "$log"
: >"$log"
OUT=$(printf 'not-a-token\n' | AGENTIC_SSH=$stubs/ssh bash "$PACKAGE/token.sh" root@box work 2>&1)
t 'token: something else is refused and nothing is sent' bash -c '[ "$1" -ne 0 ] && grep -q "nothing was stored" <<<"$2" && ! grep -q "^ssh" "$3"' _ $? "$OUT" "$log"
OUT=$(AGENTIC_SSH=$stubs/ssh bash "$PACKAGE/token.sh" root@box ../escape </dev/null 2>&1)
t 'token: an account must be a folder name' bash -c '[ "$1" -ne 0 ] && grep -q "folder name" <<<"$2"' _ $? "$OUT"

printf '# %d tests, %d failed\n' "$n" "$failures"
((failures == 0)) && ((n > 0))

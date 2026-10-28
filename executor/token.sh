#!/usr/bin/env bash
# token.sh DEST ACCOUNT [--config-dir DIR]: makes a long-lived Claude token with `claude setup-token` on this machine
# (in the account the browser logs into; --config-dir runs it with CLAUDE_CONFIG_DIR=DIR) and stores it on the executor
# DEST (the ssh destination install.sh used, logged in as root) at <EXECUTOR_ACCOUNTS_DIR>/<ACCOUNT>/token, owned by the
# run user, mode 600. The token is read without echo and travels on ssh's stdin: it is never written on this machine
# and never appears in a command line. Add ACCOUNT to EXECUTOR_ACCOUNTS there for the runs to use it.
set -euo pipefail

usage() {
  printf 'usage: token.sh DEST ACCOUNT [--config-dir DIR]\n' >&2
  exit 64
}
die() {
  printf 'token.sh: %s\n' "$*" >&2
  exit 1
}

positional=() config_dir=''
while (($#)); do
  case $1 in
    --config-dir) (($# >= 2)) || usage; config_dir=$2; shift 2 ;;
    -*) usage ;;
    *) positional+=("$1"); shift ;;
  esac
done
((${#positional[@]} == 2)) || usage
dest=${positional[0]} account=${positional[1]}
[[ $dest =~ ^[^-[:space:]][^[:space:]]*$ ]] || die "not an ssh destination: $dest"
[[ $account =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "an account is a folder name ([A-Za-z0-9._-]): $account"
command -v claude >/dev/null 2>&1 || die 'claude is not installed on this machine'
IFS=' ' read -r -a ssh_command <<<"${AGENTIC_SSH:-ssh}"

# Runs on the executor as root: the token arrives on stdin and replaces the account's token in one rename.
read -r -d '' STORE <<'SCRIPT' || true
set -eu
account=$1
. /usr/local/lib/agentic-executor/lib/config.sh
executor_config_load
dir=$EXECUTOR_ACCOUNTS_DIR/$account
install -d -m 700 -o "$EXECUTOR_USER" -g "$EXECUTOR_GROUP" "$EXECUTOR_ACCOUNTS_DIR" "$dir"
umask 077
cat >"$dir/token.new"
[ -s "$dir/token.new" ] || { rm -f "$dir/token.new"; echo 'no token arrived' >&2; exit 1; }
chown "$EXECUTOR_USER:$EXECUTOR_GROUP" "$dir/token.new"
mv -f "$dir/token.new" "$dir/token"
case " $EXECUTOR_ACCOUNTS " in
  *" $account "*) printf 'stored the token of %s in %s\n' "$account" "$dir" ;;
  *) printf 'stored the token of %s in %s; add %s to EXECUTOR_ACCOUNTS in %s to use it\n' "$account" "$dir" "$account" "$EXECUTOR_CONF" ;;
esac
SCRIPT

printf 'Account %s: claude setup-token opens the browser; log in with that account and authorize it.\n' "$account" >&2
if [[ -n $config_dir ]]; then CLAUDE_CONFIG_DIR=$config_dir claude setup-token; else claude setup-token; fi
printf '\n' >&2
token=''
IFS= read -r -s -p 'Paste the token shown above (it is not echoed) and press Enter: ' token || true
printf '\n' >&2
[[ $token == sk-ant-* ]] || die 'that does not look like a token (it starts with sk-ant-); nothing was stored'
store=$(printf '%q ' bash -c "$STORE" agentic-token "$account")
printf '%s' "$token" | "${ssh_command[@]}" -o BatchMode=yes "$dest" "${store% }"

#!/usr/bin/env bash
# Tests of install.sh: throwaway Git repositories and a fake HOME per scenario; the real home is never read.
#   bash tests/install.sh
# INSTALL_TESTS_DIR (optional) is the directory the throwaway repositories go under; default: a new temp dir.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)
INSTALLER=$ROOT/install.sh
BASE=${INSTALL_TESTS_DIR:-$(mktemp -d)}
mkdir -p "$BASE"
work=$(mktemp -d "$BASE/run.XXXXXX")
trap 'rm -rf -- "$work"; [[ -n ${INSTALL_TESTS_DIR:-} ]] || rmdir -- "$BASE" 2>/dev/null || true' EXIT

# Git must neither read the real configuration nor need an identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

n=0
failures=0
ok() { n=$((n + 1)); printf 'ok %d - %s\n' "$n" "$1"; }
not_ok() { n=$((n + 1)); failures=$((failures + 1)); printf 'not ok %d - %s\n' "$n" "$1"; }
# t DESCRIPTION COMMAND...: the test passes when the command succeeds (stdin is passed through).
t() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else not_ok "$description"; fi
}

OUT='' RC=0
TEST_PATH=$PATH
INSTALL_CMD=$INSTALLER
ANSWER=''
EXTRA_ENV=()
# inst_raw HOME ARGS...: runs the installer with a fake HOME, ANSWER on its stdin and EXTRA_ENV in its
# environment; sets OUT (stdout and stderr) and RC.
inst_raw() {
  local home=$1
  shift
  OUT=$(printf '%s' "$ANSWER" | env -u CLAUDE_CONFIG_DIR HOME="$home" PATH="$TEST_PATH" "${EXTRA_ENV[@]}" bash "$INSTALL_CMD" "$@" 2>&1) && RC=0 || RC=$?
}
# inst HOME ARGS...: the project install alone (the machine setup has its own scenarios below).
inst() {
  local home=$1
  shift
  inst_raw "$home" --no-machine-setup "$@"
}
out_has() { grep -Fq -- "$1" <<<"$OUT"; }
out_lacks() { ! grep -Fq -- "$1" <<<"$OUT"; }

new_repo() { # NAME [BRANCH]
  local dir=$work/$1
  mkdir -p "$dir"
  git init -q -b "${2:-main}" "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}
new_home() { mkdir -p "$work/home-$1"; printf '%s\n' "$work/home-$1"; }
seed_matt() { # SKILLS-ROOT
  local s
  for s in grilling to-spec to-tickets; do
    mkdir -p "$1/$s"
    printf -- '---\nname: %s\n---\n' "$s" >"$1/$s/SKILL.md"
  done
}
# A project and a home in which Matt's skills are found, so a clean install prints no warning.
setup() { # NAME [BRANCH] -> sets repo and home
  repo=$(new_repo "$1" "${2:-main}")
  home=$(new_home "$1")
  seed_matt "$home/.claude/skills"
}
TEMPLATE_TRACKER=$ROOT/templates/docs/agents/issue-tracker.md

# --- Fresh install on main.
setup fresh-main
before_home=$(cd "$home" && find . | sort)
inst "$home" --providers claude "$repo"
t 'fresh install on main: succeeds' [ "$RC" -eq 0 ]
t 'fresh install on main: .agentic/bin/campaign is installed and executable' test -x "$repo/.agentic/bin/campaign"
t 'fresh install on main: project.json names the project and the main branch' \
  jq -e --arg name fresh-main '.name == $name and .main_branch == "main"' "$repo/.agentic/project.json"
t 'fresh install on main: no __pycache__ or .pyc is copied' bash -c '[[ -z $(find "$1" \( -name __pycache__ -o -name "*.pyc" \)) ]]' _ "$repo/.agentic"
t 'fresh install on main: .agentic is the kit, except project.json' \
  diff -r -x __pycache__ -x '*.pyc' -x project.json "$ROOT/agentic" "$repo/.agentic"
t 'fresh install on main: provider skills are installed' test -f "$repo/.claude/skills/run-campaign/SKILL.md"
t 'fresh install on main: only the chosen provider is installed' bash -c '[[ ! -e $1/.codex && ! -e $1/.grok ]]' _ "$repo"
t 'fresh install on main: tracker equals the template' cmp -s "$TEMPLATE_TRACKER" "$repo/docs/agents/issue-tracker.md"
t 'fresh install on main: AGENTS.md carries the block between its markers' \
  bash -c 'grep -q "^<!-- stakhanov:start -->$" "$1" && grep -q "^<!-- stakhanov:end -->$" "$1"' _ "$repo/AGENTS.md"
t 'fresh install on main: CLAUDE.md is not created' test ! -e "$repo/CLAUDE.md"
t 'fresh install on main: no warning when Matt skills are present' out_lacks 'WARNING'
t 'fresh install on main: prints the next steps in order' \
  bash -c 'grep -q "/grilling -> /to-spec -> /to-tickets -> /run-campaign -> /finalize-campaign" <<<"$1" && grep -q "git add .agentic .claude/skills AGENTS.md docs/agents/issue-tracker.md" <<<"$1"' _ "$OUT"
t 'fresh install on main: nothing is written to HOME' [ "$before_home" = "$(cd "$home" && find . | sort)" ]
t 'fresh install on main: nothing is committed' [ "$(git -C "$repo" rev-list --count HEAD)" = 1 ]

# --- Fresh install on master (and a repository with no commit yet).
setup fresh-master master
inst "$home" --providers claude,codex "$repo"
t 'fresh install on master: project.json detects master' jq -e '.main_branch == "master"' "$repo/.agentic/project.json"
t 'fresh install on master: both providers get their skills' \
  bash -c '[[ -f $1/.claude/skills/run-campaign/SKILL.md && -f $1/.codex/skills/run-campaign/SKILL.md ]]' _ "$repo"
repo=$work/no-commit
home=$(new_home no-commit)
git init -q -b trunk "$repo"
seed_matt "$home/.claude/skills"
inst "$home" --providers claude "$repo"
t 'a repository without commits: the current branch is used' jq -e '.main_branch == "trunk"' "$repo/.agentic/project.json"

# --- Refusal without --update.
setup refuse
inst "$home" --providers claude "$repo"
printf 'precious\n' >"$repo/.agentic/note.txt"
inst "$home" --providers claude "$repo"
t 'second install without --update: refused' [ "$RC" -ne 0 ]
t 'second install without --update: says to use --update' out_has '--update'
t 'second install without --update: .agentic is untouched' test -f "$repo/.agentic/note.txt"

# --- --update keeps project.json and replaces only the marker block.
setup update
printf '# Mine\n\nbefore\n' >"$repo/AGENTS.md"
inst "$home" --providers claude "$repo"
t 'block is appended to an existing AGENTS.md' out_has 'stakhanov block appended'
printf '\nafter text\n' >>"$repo/AGENTS.md"
tampered=$(<"$repo/AGENTS.md")
printf '%s\n' "${tampered//Functional acceptance first/TAMPERED}" >"$repo/AGENTS.md"
jq '.name = "custom" | .required_checks = [["true"]]' "$repo/.agentic/project.json" >"$work/project.json.new"
mv -- "$work/project.json.new" "$repo/.agentic/project.json"
printf 'stale\n' >"$repo/.claude/skills/run-campaign/stale.txt"
inst "$home" --update "$repo"
t '--update: succeeds' [ "$RC" -eq 0 ]
t '--update: project.json is kept' jq -e '.name == "custom" and .required_checks == [["true"]]' "$repo/.agentic/project.json"
t '--update: the block is restored' bash -c '! grep -q TAMPERED "$1" && [[ $(grep -c "stakhanov:start" "$1") == 1 ]]' _ "$repo/AGENTS.md"
t '--update: text before the block is untouched' [ "$(head -n 3 "$repo/AGENTS.md")" = $'# Mine\n\nbefore' ]
t '--update: text after the block is untouched' [ "$(tail -n 1 "$repo/AGENTS.md")" = 'after text' ]
t '--update: reports the block as updated' out_has 'stakhanov block updated'
t '--update: provider skills are replaced' test ! -e "$repo/.claude/skills/run-campaign/stale.txt"

# --- AGENTS.md created when missing; CLAUDE.md never touched.
setup claude-md
printf '# Claude notes\n\nkeep me\n' >"$repo/CLAUDE.md"
cp -p -- "$repo/CLAUDE.md" "$work/CLAUDE.md.orig"
inst "$home" --providers claude "$repo"
t 'CLAUDE.md only: AGENTS.md is created with the block' grep -q 'stakhanov:start' "$repo/AGENTS.md"
t 'CLAUDE.md only: CLAUDE.md is byte-identical' cmp -s "$work/CLAUDE.md.orig" "$repo/CLAUDE.md"
inst "$home" --update "$repo"
t 'CLAUDE.md only: still byte-identical after --update' cmp -s "$work/CLAUDE.md.orig" "$repo/CLAUDE.md"

# --- Tracker that differs from the template.
setup tracker
mkdir -p "$repo/docs/agents"
printf '# Issue tracker: GitHub\n\nIssues on GitHub.\n' >"$repo/docs/agents/issue-tracker.md"
cp -p -- "$repo/docs/agents/issue-tracker.md" "$work/tracker.orig"
inst "$home" --providers claude "$repo"
t 'differing tracker: warns that skills will not publish into campaigns' bash -c 'grep -q "issue-tracker.md" <<<"$1" && grep -q "NOT into campaigns" <<<"$1"' _ "$OUT"
t 'differing tracker: kept' cmp -s "$work/tracker.orig" "$repo/docs/agents/issue-tracker.md"
inst "$home" --update "$repo"
t 'differing tracker: kept and warned again on --update' bash -c 'grep -q "NOT into campaigns" <<<"$1"' _ "$OUT"
t 'differing tracker: --update does not overwrite it' cmp -s "$work/tracker.orig" "$repo/docs/agents/issue-tracker.md"
inst "$home" --update --replace-tracker "$repo"
t '--replace-tracker: overwrites it with the template' cmp -s "$TEMPLATE_TRACKER" "$repo/docs/agents/issue-tracker.md"
t '--replace-tracker: no tracker warning' out_lacks 'NOT into campaigns'

# --- Foreign "## Agent skills" section.
setup foreign-skills
printf '# Project\n\n## Agent skills\n\n### Issue tracker\n\nGitHub issues.\n' >"$repo/AGENTS.md"
inst "$home" --providers claude "$repo"
t 'foreign "## Agent skills" in AGENTS.md: warns about the conflict' bash -c 'grep -q "AGENTS.md has its own .## Agent skills. section" <<<"$1"' _ "$OUT"
setup foreign-skills-claude
printf '# Claude\n\n## Agent skills\n\nsomething\n' >"$repo/CLAUDE.md"
inst "$home" --providers claude "$repo"
t 'foreign "## Agent skills" in CLAUDE.md: warns about the conflict' bash -c 'grep -q "CLAUDE.md has its own .## Agent skills. section" <<<"$1"' _ "$OUT"
setup own-block-only
inst "$home" --providers claude "$repo"
inst "$home" --update "$repo"
t 'the installer'"'"'s own "## Agent skills" block is not reported' out_lacks 'has its own'

# --- Kit run through a symlink.
setup symlink-kit
ln -s -- "$INSTALLER" "$work/install-link.sh"
INSTALL_CMD=$work/install-link.sh
inst "$home" --providers claude "$repo"
t 'kit run through a symlink to install.sh: installs' bash -c '[[ $1 -eq 0 && -x $2/.agentic/bin/campaign ]]' _ "$RC" "$repo"
setup symlink-kit-dir
ln -s -- "$ROOT" "$work/kit-link"
INSTALL_CMD=$work/kit-link/install.sh
inst "$home" --providers claude "$repo"
t 'kit run through a symlinked directory: installs' bash -c '[[ $1 -eq 0 && -x $2/.agentic/bin/campaign ]]' _ "$RC" "$repo"
INSTALL_CMD=$INSTALLER

# --- Symlinked .agentic.
setup symlink-agentic
mkdir -p "$work/elsewhere"
ln -s -- "$work/elsewhere" "$repo/.agentic"
inst "$home" --providers claude "$repo"
t 'symlinked .agentic: refused' [ "$RC" -ne 0 ]
t 'symlinked .agentic: says it is a symlink' out_has 'symlink'
inst "$home" --update --providers claude "$repo"
t 'symlinked .agentic: refused with --update too' [ "$RC" -ne 0 ]
t 'symlinked .agentic: the target is untouched' bash -c '[[ -z $(ls -A "$1") ]]' _ "$work/elsewhere"

# --- Providers kept on --update.
setup providers
mkdir -p "$work/fakebin"
for cli in claude codex grok; do printf '#!/bin/sh\nexit 0\n' >"$work/fakebin/$cli"; chmod +x "$work/fakebin/$cli"; done
TEST_PATH="$work/fakebin:$PATH"
inst "$home" --providers codex "$repo"
inst "$home" --update "$repo"
t '--update without --providers: succeeds' [ "$RC" -eq 0 ]
t '--update without --providers: keeps the installed provider' test -f "$repo/.codex/skills/run-campaign/SKILL.md"
t '--update without --providers: does not add providers found on PATH' bash -c '[[ ! -e $1/.claude && ! -e $1/.grok ]]' _ "$repo"
inst "$home" --update --providers codex,grok "$repo"
t '--update with --providers: installs exactly the listed ones' bash -c '[[ -e $1/.grok/skills/run-campaign && -e $1/.codex/skills/run-campaign ]]' _ "$repo"
TEST_PATH=$PATH

# --- Files of .agentic that the kit does not ship.
setup foreign-files
inst "$home" --providers claude "$repo"
mkdir -p "$repo/.agentic/lib/__pycache__"
printf 'x\n' >"$repo/.agentic/lib/__pycache__/common.cpython-314.pyc"
inst "$home" --update "$repo"
t '--update: a __pycache__ is not a foreign file' [ "$RC" -eq 0 ]
printf 'mine\n' >"$repo/.agentic/extra.txt"
printf '#!/bin/sh\n' >"$repo/.agentic/bin/mine.sh"
printf 'old\n' >"$repo/.agentic/bin/campaign-old"
inst "$home" --update "$repo"
t 'foreign files: --update is refused' [ "$RC" -ne 0 ]
t 'foreign files: the message lists them' bash -c 'grep -q ".agentic/extra.txt" <<<"$1" && grep -q ".agentic/bin/mine.sh" <<<"$1" && grep -q "campaign-old" <<<"$1" && grep -q -- "--force" <<<"$1"' _ "$OUT"
t 'foreign files: nothing was deleted' bash -c '[[ -f $1/.agentic/extra.txt && -f $1/.agentic/bin/mine.sh && -x $1/.agentic/bin/campaign ]]' _ "$repo"
inst "$home" --update --force "$repo"
t 'foreign files: --force succeeds' [ "$RC" -eq 0 ]
t 'foreign files: --force removes them' bash -c '[[ ! -e $1/.agentic/extra.txt && ! -e $1/.agentic/bin/mine.sh ]]' _ "$repo"
t 'foreign files: --force keeps project.json' test -f "$repo/.agentic/project.json"
inst "$home" --force "$repo"
t '--force without --update: refused' [ "$RC" -ne 0 ]

# --- Matt Pocock's skills.
repo=$(new_repo matt-plugin)
home=$(new_home matt-plugin)
for s in grilling to-spec to-tickets; do
  mkdir -p "$home/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.0.0/skills/engineering/$s"
  printf -- '---\nname: %s\n---\n' "$s" >"$home/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.0.0/skills/engineering/$s/SKILL.md"
done
inst "$home" --providers claude "$repo"
t 'Matt skills in a plugin install: no warning' out_lacks 'could not confirm'
repo=$(new_repo matt-project-agents)
home=$(new_home matt-project-agents)
seed_matt "$repo/.agents/skills"
inst "$home" --providers claude "$repo"
t 'Matt skills in the project .agents/skills: no warning' out_lacks 'could not confirm'
repo=$(new_repo matt-home-agents)
home=$(new_home matt-home-agents)
seed_matt "$home/.agents/skills"
inst "$home" --providers codex "$repo"
t 'Matt skills in ~/.agents/skills: no warning' out_lacks 'could not confirm'
repo=$(new_repo matt-missing)
home=$(new_home matt-missing)
inst "$home" --providers claude "$repo"
t 'Matt skills missing: installs anyway' [ "$RC" -eq 0 ]
t 'Matt skills missing: one warning per skill' \
  bash -c 'grep -q "could not confirm skill .grilling." <<<"$1" && grep -q "could not confirm skill .to-spec." <<<"$1" && grep -q "could not confirm skill .to-tickets." <<<"$1"' _ "$OUT"
t 'Matt skills missing: the warning names the source and says how to get them' \
  bash -c 'grep -q "github.com/mattpocock/skills" <<<"$1" && grep -q -- "without --no-machine-setup" <<<"$1"' _ "$OUT"
repo=$(new_repo matt-one-missing)
home=$(new_home matt-one-missing)
seed_matt "$home/.claude/skills"
rm -rf -- "$home/.claude/skills/to-spec"
inst "$home" --providers claude "$repo"
t 'one Matt skill missing: only that one is reported' \
  bash -c 'grep -q "could not confirm skill .to-spec." <<<"$1" && ! grep -q "could not confirm skill .grilling." <<<"$1"' _ "$OUT"

# --- Targets that are not a Git top level.
mkdir -p "$work/plain"
home=$(new_home plain)
inst "$home" --providers claude "$work/plain"
t 'a directory that is not a Git work tree: refused' [ "$RC" -ne 0 ]
t 'a directory that is not a Git work tree: says so, writes nothing' bash -c 'grep -q "not a Git work tree" <<<"$1" && [[ -z $(ls -A "$2") ]]' _ "$OUT" "$work/plain"
setup subdir
mkdir -p "$repo/packages/app"
inst "$home" --providers claude "$repo/packages/app"
t 'a subdirectory of a work tree: refused' [ "$RC" -ne 0 ]
t 'a subdirectory of a work tree: names the top level' bash -c 'grep -qF -- "$2" <<<"$1" && [[ ! -e $2/.agentic && ! -e $2/packages/app/.agentic ]]' _ "$OUT" "$repo"
inst "$home" --providers nonsense "$repo"
t 'an unknown provider: refused' [ "$RC" -ne 0 ]
inst "$home" --providers claude "$work/does-not-exist"
t 'a missing directory: refused' [ "$RC" -ne 0 ]

# --- The installer does not depend on the timeout command.
t 'install.sh does not require timeout' bash -c '! grep -Eq "(^|[^_A-Za-z-])timeout([^_A-Za-z-]|$)" "$1"' _ "$INSTALLER"

# =========================================================================================================
# Machine setup. Nothing here touches the network, sudo, the real package manager or the real HOME: stubs come
# first on PATH and record their calls in a log, over a PATH that holds only the real basic tools.
# =========================================================================================================
REAL_JQ=$(command -v jq)
SRC=$work/stub-src
mkdir -p "$SRC"
cat >"$SRC/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$STUB_LOG"
exec "$@"
STUB
cat >"$SRC/pkgmgr" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$STUB_LOG"
case " $* " in
  *" install "*|*" -S "*) for pair in ${STUB_PROVIDES:-}; do ln -sf "${pair#*=}" "$STUB_BIN/${pair%%=*}"; done ;;
esac
exit 0
STUB
cat >"$SRC/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
[[ -z ${STUB_CURL_FAIL:-} ]] || exit 22
args=("$@")
url=${args[${#args[@]} - 1]}
out=''
for ((i = 0; i < ${#args[@]}; i++)); do [[ ${args[i]} == -o ]] && out=${args[i + 1]}; done
case "$url" in
  https://codeload.github.com/mattpocock/skills/tar.gz/*) src=$STUB_MATT_TGZ ;;
  https://claude.ai/install.sh) src=$STUB_CLAUDE_INSTALLER ;;
  *) echo "curl stub: unexpected URL $url" >&2; exit 22 ;;
esac
if [[ -n $out ]]; then cp -- "$src" "$out"; else cat -- "$src"; fi
STUB
cat >"$SRC/npm" <<'STUB'
#!/usr/bin/env bash
echo "npm $*" >>"$STUB_LOG"
prefix=$HOME/.npm-global
case "$1 $2 $3" in
  "config get prefix") echo "$prefix" ;;
  "install -g "*)
    case "$3" in @openai/codex) name=codex ;; @xai-official/grok) name=grok ;; *) exit 1 ;; esac
    mkdir -p "$prefix/bin"
    printf '#!/bin/sh\nexit 0\n' >"$prefix/bin/$name"
    chmod +x "$prefix/bin/$name" ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' >"$SRC/cli"
cat >"$work/claude-install.sh" <<'STUB'
echo "claude-installer ran" >>"$STUB_LOG"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
STUB
chmod +x "$SRC"/*

# A fake upstream archive: his layout today, plus a decoy.
upstream=$work/matt-src/mattpocock-skills-main/skills
for entry in productivity/grilling engineering/to-spec engineering/to-tickets other/decoy; do
  mkdir -p "$upstream/$entry/agents"
  printf -- '---\nname: %s\n---\nupstream %s\n' "${entry##*/}" "${entry##*/}" >"$upstream/$entry/SKILL.md"
  printf 'interface: %s\n' "${entry##*/}" >"$upstream/$entry/agents/openai.yaml"
done
tar -C "$work/matt-src" -czf "$work/matt.tgz" mattpocock-skills-main

# A PATH of the real tools minus the ones a scenario controls.
make_base() { # DIR EXCLUDED...
  local dir=$1
  shift
  mkdir -p "$dir"
  python3 -I - "$dir" "$PATH" "$@" <<'PY'
import os, sys
dest, path, *excluded = sys.argv[1:]
seen = set(excluded)
for d in path.split(":"):
    if not d or not os.path.isdir(d):
        continue
    for name in os.listdir(d):
        full = os.path.join(d, name)
        if name not in seen and os.path.isfile(full) and os.access(full, os.X_OK):
            seen.add(name)
            os.symlink(full, os.path.join(dest, name))
PY
}
CONTROLLED=(sudo pacman apt-get dnf zypper npm node curl claude codex grok)
make_base "$work/base-all" "${CONTROLLED[@]}"
make_base "$work/base-nojq" "${CONTROLLED[@]}" jq

STUBS=''
# mach NAME BASE STUB...: a fresh stub directory over BASE; the log starts empty.
mach() {
  local name=$1 base=$2 s
  shift 2
  STUBS=$work/stubs-$name
  mkdir -p "$STUBS"
  for s in "$@"; do
    case "$s" in
      pacman|apt-get|dnf|zypper) cp -- "$SRC/pkgmgr" "$STUBS/$s" ;;
      claude|codex|grok) cp -- "$SRC/cli" "$STUBS/$s" ;;
      *) cp -- "$SRC/$s" "$STUBS/$s" ;;
    esac
  done
  : >"$STUBS/log"
  TEST_PATH=$STUBS:$base
  ANSWER=''
  EXTRA_ENV=(STUB_LOG="$STUBS/log" STUB_BIN="$STUBS" STUB_MATT_TGZ="$work/matt.tgz" STUB_CLAUDE_INSTALLER="$work/claude-install.sh")
}
log_has() { grep -Fq -- "$1" "$STUBS/log"; }
log_line() { grep -n -- "$1" "$STUBS/log" | head -n 1 | cut -d: -f1; }
seed_all() { seed_matt "$home/.claude/skills"; seed_matt "$home/.codex/skills"; seed_matt "$home/.grok/skills"; }

# --- A missing jq: the pacman command is proposed and asked for.
setup mach-refuse
seed_all
mach mach-refuse "$work/base-nojq" sudo curl pacman claude
EXTRA_ENV+=("STUB_PROVIDES=jq=$REAL_JQ")
ANSWER=$'n\n'
inst_raw "$home" --providers claude "$repo"
t 'missing jq: the pacman command is proposed' out_has 'pacman -S jq'
t 'missing jq: it asks before installing' out_has 'Install? [y/N]'
t 'missing jq: no --noconfirm without --yes' out_lacks '--noconfirm'
t 'refusal: the installer stops with an error' [ "$RC" -ne 0 ]
t 'refusal: nothing was run' test ! -s "$STUBS/log"
t 'refusal: it lists what to install by hand' out_has 'by hand'
t 'refusal: the project is untouched' bash -c '[[ ! -e $1/.agentic && ! -e $1/AGENTS.md && ! -e $1/.claude ]]' _ "$repo"
ANSWER=''
inst_raw "$home" --providers claude "$repo"
t 'no answer (end of input) counts as no' bash -c '[[ $1 -ne 0 && ! -e $2/.agentic ]]' _ "$RC" "$repo"
ANSWER=$'y\n'
inst_raw "$home" --providers claude "$repo"
t 'answering y runs the command' [ "$RC" -eq 0 ]
t 'answering y: pacman got the plain command' log_has 'pacman -S jq'
t 'answering y: the project is installed' test -f "$repo/.agentic/project.json"

# --- --yes goes through sudo (directly when root).
setup mach-yes
seed_all
mach mach-yes "$work/base-nojq" sudo curl pacman claude
EXTRA_ENV+=("STUB_PROVIDES=jq=$REAL_JQ")
inst_raw "$home" --yes --providers claude "$repo"
t '--yes: succeeds without a prompt' bash -c '[[ $1 -eq 0 ]] && ! grep -q "Install?" <<<"$2"' _ "$RC" "$OUT"
t '--yes: pacman runs with --needed --noconfirm' log_has 'pacman -S --needed --noconfirm jq'
t '--yes: through sudo unless root' bash -c '(( EUID == 0 )) || grep -q "^sudo pacman -S --needed --noconfirm jq$" "$1"' _ "$STUBS/log"
t '--yes: the project is installed with the new jq' jq -e '.name == "mach-yes"' "$repo/.agentic/project.json"
t '--yes: the summary lists the system commands' out_has 'system commands: jq'

# --- apt-get runs update first.
setup mach-apt
seed_all
mach mach-apt "$work/base-nojq" sudo curl apt-get claude
EXTRA_ENV+=("STUB_PROVIDES=jq=$REAL_JQ")
inst_raw "$home" --yes --providers claude "$repo"
t 'apt-get: succeeds' [ "$RC" -eq 0 ]
t 'apt-get: update runs before install' \
  bash -c 'u=$(grep -n "^apt-get update" "$1" | head -n 1 | cut -d: -f1); i=$(grep -n "^apt-get install -y jq" "$1" | head -n 1 | cut -d: -f1); [[ -n $u && -n $i && $u -lt $i ]]' _ "$STUBS/log"
t 'apt-get: both commands are printed' bash -c 'grep -q "apt-get update" <<<"$1" && grep -q "apt-get install -y jq" <<<"$1"' _ "$OUT"

# --- Unknown package manager.
setup mach-unknown
seed_all
mach mach-unknown "$work/base-nojq" sudo curl claude
inst_raw "$home" --yes --providers claude "$repo"
t 'unknown package manager: refused' [ "$RC" -ne 0 ]
t 'unknown package manager: lists the missing commands to install by hand' bash -c 'grep -q "missing commands: jq" <<<"$1" && grep -q "by hand" <<<"$1"' _ "$OUT"
t 'unknown package manager: nothing was run, nothing installed' bash -c '[[ ! -s $1 && ! -e $2/.agentic ]]' _ "$STUBS/log" "$repo"

# --- No provider on PATH: claude, through the official installer.
setup mach-claude
seed_all
mach mach-claude "$work/base-all" sudo curl
ANSWER=$'y\n'
inst_raw "$home" "$repo"
t 'no provider on PATH: succeeds' [ "$RC" -eq 0 ]
t 'no provider on PATH: the installer command is shown' out_has 'curl -fsSL https://claude.ai/install.sh | bash'
t 'no provider on PATH: claude is installed through it' bash -c 'grep -q "^curl -fsSL https://claude.ai/install.sh" "$1" && grep -q "claude-installer ran" "$1"' _ "$STUBS/log"
t 'no provider on PATH: claude skills go into the project' test -f "$repo/.claude/skills/run-campaign/SKILL.md"
t 'no provider on PATH: says which directory to add to PATH' bash -c 'grep -q "not on your PATH" <<<"$1" && grep -qF -- "$2/.local/bin" <<<"$1"' _ "$OUT" "$home"
t 'no provider on PATH: claude is listed for login' bash -c 'grep -A3 "this installer never logs in" <<<"$1" | grep -q "^  claude$"' _ "$OUT"
t 'no provider on PATH: nothing else was installed' bash -c '[[ ! -e $1/.codex && ! -e $1/.grok ]]' _ "$repo"
setup mach-claude-no
seed_all
mach mach-claude-no "$work/base-all" sudo curl
ANSWER=$'n\n'
inst_raw "$home" "$repo"
t 'declining a provider CLI: the project install goes on' [ "$RC" -eq 0 ]
t 'declining a provider CLI: the installer was not run and a warning is printed' bash -c '! grep -q "claude-installer" "$1" && grep -q "CLI was not installed" <<<"$2"' _ "$STUBS/log" "$OUT"
t 'declining a provider CLI: nothing to log in to' out_lacks 'never logs in'

# --- --providers codex with npm missing: nodejs npm first, then the npm package.
setup mach-codex
seed_all
mach mach-codex "$work/base-all" sudo curl pacman
EXTRA_ENV+=("STUB_PROVIDES=npm=$SRC/npm")
inst_raw "$home" --yes --providers codex "$repo"
t 'codex without npm: succeeds' [ "$RC" -eq 0 ]
t 'codex without npm: nodejs npm are installed first' log_has 'pacman -S --needed --noconfirm nodejs npm'
t 'codex without npm: then the npm package' bash -c 'grep -q "^npm install -g @openai/codex$" "$1"' _ "$STUBS/log"
t 'codex without npm: in that order' bash -c 'p=$(grep -n "^pacman" "$1" | head -n 1 | cut -d: -f1); i=$(grep -n "^npm install" "$1" | head -n 1 | cut -d: -f1); [[ $p -lt $i ]]' _ "$STUBS/log"
t 'codex without npm: the npm bin directory is named' bash -c 'grep -qF -- "$2/.npm-global/bin" <<<"$1"' _ "$OUT" "$home"
t 'codex without npm: codex is listed for login' bash -c 'grep -A3 "this installer never logs in" <<<"$1" | grep -q "^  codex$"' _ "$OUT"
t 'codex without npm: only the codex skills go into the project' bash -c '[[ -d $1/.codex/skills/run-campaign && ! -e $1/.claude ]]' _ "$repo"

# --- Matt Pocock's skills.
repo=$(new_repo mach-matt)
home=$(new_home mach-matt)
mkdir -p "$home/.codex/skills/to-spec"
printf 'mine\n' >"$home/.codex/skills/to-spec/SKILL.md"
mach mach-matt "$work/base-all" sudo curl claude codex
inst_raw "$home" --providers claude,codex "$repo"
t 'Matt skills: succeeds without any prompt' [ "$RC" -eq 0 ]
t 'Matt skills: downloaded once for both providers, from main' bash -c '[[ $(grep -c "codeload" "$1") == 1 ]] && grep -q "https://codeload.github.com/mattpocock/skills/tar.gz/main$" "$1"' _ "$STUBS/log"
t 'Matt skills: claude gets all three, found by name whatever the group folder' \
  bash -c 'for s in grilling to-spec to-tickets; do grep -q "upstream $s" "$1/.claude/skills/$s/SKILL.md" || exit 1; done' _ "$home"
t 'Matt skills: the whole folder is copied (agents/)' test -f "$home/.claude/skills/to-spec/agents/openai.yaml"
t 'Matt skills: codex gets the two it lacked' bash -c 'grep -q "upstream grilling" "$1/.codex/skills/grilling/SKILL.md" && grep -q "upstream to-tickets" "$1/.codex/skills/to-tickets/SKILL.md"' _ "$home"
t 'Matt skills: an existing one is untouched' bash -c '[[ $(cat "$1/.codex/skills/to-spec/SKILL.md") == mine && ! -e $1/.codex/skills/to-spec/agents ]]' _ "$home"
t 'Matt skills: nothing unrelated is copied' test ! -e "$home/.claude/skills/decoy"
t 'Matt skills: nothing is installed into the project' bash -c '[[ ! -e $1/.claude/skills/grilling && ! -e $1/.codex/skills/to-tickets ]]' _ "$repo"
t 'Matt skills: the summary says what was installed' bash -c 'grep -q "Matt Pocock.s skills for claude" <<<"$1" && grep -q "Matt Pocock.s skills for codex" <<<"$1"' _ "$OUT"
t 'Matt skills: no missing-skill warning afterwards' out_lacks 'could not confirm'
inst_raw "$home" --update --providers claude,codex "$repo"
t 'Matt skills: a second run downloads nothing more' bash -c '[[ $(grep -c "codeload" "$1") == 1 ]]' _ "$STUBS/log"

repo=$(new_repo mach-matt-ref)
home=$(new_home mach-matt-ref)
mach mach-matt-ref "$work/base-all" sudo curl claude
EXTRA_ENV+=("CLAUDE_CONFIG_DIR=$home/cfg")
inst_raw "$home" --matt-ref v9.9 --providers claude "$repo"
t '--matt-ref: the ref is in the URL' log_has '/mattpocock/skills/tar.gz/v9.9'
t 'CLAUDE_CONFIG_DIR: the claude skills go there' test -f "$home/cfg/skills/to-tickets/SKILL.md"
t 'CLAUDE_CONFIG_DIR: not into ~/.claude' test ! -e "$home/.claude"

repo=$(new_repo mach-matt-fail)
home=$(new_home mach-matt-fail)
mach mach-matt-fail "$work/base-all" sudo curl claude
EXTRA_ENV+=("STUB_CURL_FAIL=1")
inst_raw "$home" --providers claude "$repo"
t 'download failure: the project is still installed' bash -c '[[ $1 -eq 0 && -x $2/.agentic/bin/campaign ]]' _ "$RC" "$repo"
t 'download failure: a warning says so' out_has 'could not download'
t 'download failure: the skills are still reported missing' out_has "could not confirm skill 'to-spec'"
t 'download failure: nothing is left in HOME' test ! -e "$home/.claude"

# --- --no-machine-setup calls none of the stubs.
repo=$(new_repo mach-skip)
home=$(new_home mach-skip)
mach mach-skip "$work/base-nojq" sudo curl pacman npm claude codex
inst_raw "$home" --no-machine-setup --providers claude "$repo"
t '--no-machine-setup: no jq is not repaired, so the project install refuses cleanly' bash -c '[[ $1 -ne 0 ]] && grep -q "missing required commands: jq" <<<"$2"' _ "$RC" "$OUT"
t '--no-machine-setup: not one stub was called' test ! -s "$STUBS/log"
mach mach-skip2 "$work/base-all" sudo curl pacman npm claude codex
inst_raw "$home" --no-machine-setup --providers claude "$repo"
t '--no-machine-setup: installs the project' [ "$RC" -eq 0 ]
t '--no-machine-setup: not one stub was called' test ! -s "$STUBS/log"
t '--no-machine-setup: Matt skills are only checked' out_has "could not confirm skill 'grilling'"
t '--no-machine-setup: nothing is written to HOME' test ! -e "$home/.claude"

# The kit never stores Matt Pocock's skills.
t 'the kit has no copy of his skills' bash -c '[[ -z $(find "$1/skills" "$1/templates" "$1/agentic" \( -path "*/grilling/*" -o -path "*/to-spec/*" -o -path "*/to-tickets/*" \)) ]]' _ "$ROOT"

printf '# %d tests, %d failed\n' "$n" "$failures"
((failures == 0)) && ((n > 0))

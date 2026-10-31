#!/usr/bin/env bash
# Prepare the machine and install the Stakhanov campaign kit into a Git project.
#   install.sh [--providers claude,codex,grok] [--update [--force]] [--replace-tracker]
#              [--yes] [--no-machine-setup] [--matt-ref REF] <project-dir>
set -Eeuo pipefail
IFS=$'\n\t'

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
KIT=$(cd -- "$(dirname -- "$SELF")" && pwd -P)
BLOCK_START='<!-- stakhanov:start -->'
BLOCK_END='<!-- stakhanov:end -->'
MATT_SKILLS=(grilling to-spec to-tickets)
MATT_URL=https://github.com/mattpocock/skills
MATT_TARBALL=https://codeload.github.com/mattpocock/skills/tar.gz
CLAUDE_INSTALLER_URL=https://claude.ai/install.sh
CODEX_NPM_PACKAGE=@openai/codex
GROK_NPM_PACKAGE=@xai-official/grok
TRACKER=docs/agents/issue-tracker.md
INSTRUCTION_FILE=AGENTS.md

usage() {
  cat <<'USAGE'
Usage: install.sh [--providers claude,codex,grok] [--update [--force]] [--replace-tracker]
                  [--yes] [--no-machine-setup] [--matt-ref REF] <project-dir>

Prepares the machine (missing system commands, provider CLIs, Matt Pocock's skills), then installs the kit
into the project.

  --providers LIST    comma-separated providers to set up. Default: the providers whose CLI is on PATH, and
                      claude when none is; with --update, the providers whose skills are already installed.
  --update            replace an existing .agentic (keeping project.json) and the provider skills
  --force             with --update: also delete files of .agentic that the kit does not ship
  --replace-tracker   overwrite an existing docs/agents/issue-tracker.md with the kit's template
                      (it is never overwritten otherwise, not even with --update)
  --yes               do not ask before installing system packages and provider CLIs
  --no-machine-setup  skip the machine setup (system commands, provider CLIs, Matt's skills): for CI
  --matt-ref REF      Git ref of github.com/mattpocock/skills to take the skills from (default: main)
USAGE
}

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
join() { local sep=$1 out='' item; shift; for item in "$@"; do out+=${out:+$sep}$item; done; printf '%s' "$out"; }

[[ $(uname -s) == Linux ]] || die 'Linux only: this kit does not support macOS or other systems.'

providers_arg=''
update=false
force=false
replace_tracker=false
assume_yes=false
machine_setup=true
matt_ref=main
project=''
while (($#)); do
  case "$1" in
    --providers) (($# >= 2)) || die '--providers needs a value'; providers_arg=$2; shift 2 ;;
    --providers=*) providers_arg=${1#*=}; shift ;;
    --update) update=true; shift ;;
    --force) force=true; shift ;;
    --replace-tracker) replace_tracker=true; shift ;;
    --yes|-y) assume_yes=true; shift ;;
    --no-machine-setup) machine_setup=false; shift ;;
    --matt-ref) (($# >= 2)) || die '--matt-ref needs a value'; matt_ref=$2; shift 2 ;;
    --matt-ref=*) matt_ref=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) [[ -z $project ]] || { usage >&2; die 'only one project directory is accepted'; }; project=$1; shift ;;
  esac
done
[[ -n $project ]] || { usage >&2; exit 64; }
[[ $force == false || $update == true ]] || die '--force only applies together with --update'
[[ $matt_ref =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid --matt-ref: $matt_ref"

[[ -f $KIT/agentic/bin/campaign && -f $KIT/templates/AGENTS.md ]] || die "$KIT is not a complete Stakhanov kit"

[[ -d $project ]] || die "not a directory: $project"
project=$(cd -- "$project" && pwd -P)

work_tmp=''
trap '[[ -z $work_tmp ]] || rm -rf -- "$work_tmp"' EXIT

created=()
changed=()
warnings=()
machine_done=()
login_needed=()

# ---------------------------------------------------------------------------------------------------------
# Project checks (they need git, so they run before the machine setup when git is there, and after it if not).

validate_project() {
  local top file rel foreign
  top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || die "not a Git work tree: $project"
  [[ $top == "$project" ]] || die "$project is inside a Git work tree; pass its top level: $top"
  [[ ! -L $project/.agentic ]] || die "$project/.agentic is a symlink; the kit is installed as a real directory. Remove the link or install elsewhere."
  if [[ -e $project/.agentic && ! -d $project/.agentic ]]; then die "$project/.agentic exists and is not a directory"; fi
  if [[ -e $project/.agentic && $update == false ]]; then
    die "$project/.agentic already exists; use --update to replace it (project.json is kept)"
  fi
  # --update replaces .agentic: refuse before changing anything when it holds files the kit does not ship.
  if [[ -d $project/.agentic && $force == false ]]; then
    foreign=()
    while IFS= read -r -d '' file; do
      rel=${file#"$project/.agentic/"}
      [[ $rel != project.json ]] || continue
      [[ -f $KIT/agentic/$rel && ! -L $KIT/agentic/$rel ]] || foreign+=("$rel")
    done < <(find "$project/.agentic" \( -name __pycache__ -prune \) -o \( ! -type d ! -name '*.pyc' -print0 \))
    if ((${#foreign[@]})); then
      printf 'install.sh: .agentic holds files that the kit does not ship, and --update would delete them:\n' >&2
      printf '  .agentic/%s\n' "${foreign[@]}" >&2
      die 'move them out, or run again with --force to delete them'
    fi
  fi
}
project_validated=false
if command -v git >/dev/null 2>&1; then validate_project; project_validated=true; fi

# ---------------------------------------------------------------------------------------------------------
# Providers: --providers, else (with --update) the ones already installed in the project, else the ones whose
# CLI is on PATH, else claude.

kit_provider_skills_installed() {
  local p=$1 skill_dir
  [[ -d $KIT/skills/$p ]] || return 1
  for skill_dir in "$KIT/skills/$p"/*/; do
    [[ -e $project/.$p/skills/$(basename -- "$skill_dir") ]] && return 0
  done
  return 1
}

providers=()
if [[ -n $providers_arg ]]; then
  IFS=, read -r -a providers <<<"$providers_arg"
  for p in "${providers[@]}"; do
    case "$p" in claude|codex|grok) ;; *) die "unknown provider '$p' (claude, codex, grok)" ;; esac
  done
else
  if [[ $update == true ]]; then
    for p in claude codex grok; do
      kit_provider_skills_installed "$p" && providers+=("$p")
    done
  fi
  if ((${#providers[@]} == 0)); then
    for p in claude codex grok; do
      command -v "$p" >/dev/null 2>&1 && providers+=("$p")
    done
  fi
  ((${#providers[@]})) || providers=(claude)
fi
for p in "${providers[@]}"; do
  [[ -d $KIT/skills/$p ]] || die "the kit has no skills for provider '$p'"
done

# ---------------------------------------------------------------------------------------------------------
# Matt Pocock's skills: where they may already be, and where a missing one is installed.

# Sets MATT_ROOTS (skill folders) and MATT_PLUGIN_SKILLS (every SKILL.md of the provider's plugins).
# Looked for where his README installs them: ~/.<provider>/skills and the project's .<provider>/skills; a plugin
# under ~/.<provider>/plugins (any depth); `npx skills add` under .agents/skills (project and home).
matt_scan() {
  local p=$1 h
  local config_homes=("$HOME/.$p")
  [[ $p == claude && -n ${CLAUDE_CONFIG_DIR:-} ]] && config_homes+=("$CLAUDE_CONFIG_DIR")
  MATT_ROOTS=("$project/.$p/skills" "$HOME/.agents/skills" "$project/.agents/skills")
  MATT_PLUGIN_SKILLS=''
  for h in "${config_homes[@]}"; do
    MATT_ROOTS+=("$h/skills")
    [[ -d $h/plugins ]] && MATT_PLUGIN_SKILLS+=$'\n'$(find -L "$h/plugins" -maxdepth 10 -type f -name SKILL.md 2>/dev/null || true)
  done
  return 0
}
matt_found() {
  local skill=$1 r
  for r in "${MATT_ROOTS[@]}"; do
    [[ -e $r/$skill/SKILL.md ]] && return 0
  done
  [[ -n $MATT_PLUGIN_SKILLS ]] && grep -Fq "/$skill/SKILL.md" <<<"$MATT_PLUGIN_SKILLS"
}
# The machine-level skills folder of a provider.
matt_dest() {
  if [[ $1 == claude ]]; then printf '%s/skills\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; else printf '%s/.%s/skills\n' "$HOME" "$1"; fi
}

# ---------------------------------------------------------------------------------------------------------
# Machine setup.

as_root() {
  if ((EUID == 0)); then "$@"; else sudo "$@"; fi
}
root_prefix() { if ((EUID == 0)); then printf ''; else printf 'sudo '; fi; }

# Asks "Install? [y/N]" (default no) unless --yes.
confirm_install() {
  local answer=''
  $assume_yes && return 0
  printf 'Install? [y/N] '
  read -r answer || true
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) printf '\n'; return 1 ;; esac
}

# Packages that provide a command, for the package manager $1 (one per line).
packages_for() {
  local manager=$1 cmd=$2
  case "$cmd" in
    python3) if [[ $manager == pacman ]]; then echo python; else echo python3; fi ;;
    flock|setsid) echo util-linux ;;
    cmp) echo diffutils ;;
    npm) echo nodejs; echo npm ;;
    *) echo "$cmd" ;;
  esac
}

install_system_commands() {
  local needed=(git jq python3 flock setsid cmp curl tar) cmd p manager='' m
  local missing=() pkgs=() prefix commands=() line
  local need_npm=false
  for p in "${providers[@]}"; do
    if [[ $p == codex || $p == grok ]] && ! command -v "$p" >/dev/null 2>&1; then need_npm=true; fi
  done
  [[ $need_npm == false ]] || needed+=(npm)
  for cmd in "${needed[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]})) || return 0

  for m in pacman apt-get dnf zypper; do
    if command -v "$m" >/dev/null 2>&1; then manager=$m; break; fi
  done
  if [[ -z $manager ]]; then
    printf 'install.sh: missing commands: %s\n' "$(join ' ' "${missing[@]}")" >&2
    die 'no supported package manager (pacman, apt-get, dnf, zypper) found: install these commands by hand, then run again'
  fi
  mapfile -t pkgs < <(for cmd in "${missing[@]}"; do packages_for "$manager" "$cmd"; done | awk '!seen[$0]++')

  prefix=$(root_prefix)
  case "$manager" in
    pacman)
      if $assume_yes; then commands=("pacman -S --needed --noconfirm $(join ' ' "${pkgs[@]}")")
      else commands=("pacman -S $(join ' ' "${pkgs[@]}")"); fi ;;
    apt-get) commands=("apt-get update" "apt-get install -y $(join ' ' "${pkgs[@]}")") ;;
    dnf) commands=("dnf install -y $(join ' ' "${pkgs[@]}")") ;;
    zypper) commands=("zypper install -y $(join ' ' "${pkgs[@]}")") ;;
  esac
  note ''
  note "Missing commands: $(join ' ' "${missing[@]}"). To install them ($manager):"
  for line in "${commands[@]}"; do note "  $prefix$line"; done
  if ((EUID != 0)) && ! command -v sudo >/dev/null 2>&1; then
    die "sudo is not available: run this installer as root, or install by hand: $(join ' ' "${pkgs[@]}")"
  fi
  if ! confirm_install; then
    die "not installed. Install these by hand, then run again: $(join ' ' "${pkgs[@]}") (commands: $(join ' ' "${missing[@]}"))"
  fi
  for line in "${commands[@]}"; do
    IFS=' ' read -r -a cmd_words <<<"$line"
    as_root "${cmd_words[@]}" || die "'$prefix$line' failed"
  done
  hash -r
  for cmd in "${missing[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is still missing after installing $(join ' ' "${pkgs[@]}")"
  done
  machine_done+=("system commands: $(join ' ' "${missing[@]}") (packages: $(join ' ' "${pkgs[@]}"))")
}

# A directory where a freshly installed CLI may have landed, when it is not on PATH.
cli_directory() {
  local p=$1 d prefix=''
  command -v npm >/dev/null 2>&1 && prefix=$(npm config get prefix 2>/dev/null || true)
  for d in "$HOME/.local/bin" "$HOME/.claude/local" ${prefix:+"$prefix/bin"}; do
    [[ -x $d/$p ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

install_provider_cli() {
  local p=$1 description
  command -v "$p" >/dev/null 2>&1 && return 0
  case "$p" in
    claude) description="curl -fsSL $CLAUDE_INSTALLER_URL | bash" ;;
    codex) description="npm install -g $CODEX_NPM_PACKAGE" ;;
    grok) description="npm install -g $GROK_NPM_PACKAGE" ;;
  esac
  note ''
  note "The $p CLI is not installed. To install it:"
  note "  $description"
  if ! confirm_install; then
    warnings+=("WARNING: the $p CLI was not installed; the $p skills are installed but you need the CLI ($description).")
    return 0
  fi
  case "$p" in
    claude) curl -fsSL "$CLAUDE_INSTALLER_URL" | bash || { warnings+=("WARNING: the $p installer failed: run '$description' by hand."); return 0; } ;;
    codex) npm install -g "$CODEX_NPM_PACKAGE" || { warnings+=("WARNING: '$description' failed (a root-owned npm prefix needs 'npm config set prefix ~/.npm-global' first): run it by hand."); return 0; } ;;
    grok) npm install -g "$GROK_NPM_PACKAGE" || { warnings+=("WARNING: '$description' failed (a root-owned npm prefix needs 'npm config set prefix ~/.npm-global' first): run it by hand."); return 0; } ;;
  esac
  hash -r
  machine_done+=("$p CLI ($description)")
  login_needed+=("$p")
  if ! command -v "$p" >/dev/null 2>&1; then
    local dir
    if dir=$(cli_directory "$p"); then
      warnings+=("$p was installed in $dir, which is not on your PATH: add it (for example 'export PATH=\"$dir:\$PATH\"' in your shell profile) and open a new terminal.")
    else
      warnings+=("$p was installed but is not on your PATH yet: open a new terminal, or add its install directory to PATH.")
    fi
  fi
}

# Downloads Matt Pocock's repository once per run; sets matt_src to the extracted folder.
matt_src=''
matt_download_failed=false
fetch_matt() {
  [[ -z $matt_src ]] || return 0
  [[ $matt_download_failed == false ]] || return 1
  local url=$MATT_TARBALL/$matt_ref
  [[ -n $work_tmp ]] || work_tmp=$(mktemp -d)
  mkdir -p "$work_tmp/matt"
  if curl -fsSL -o "$work_tmp/matt.tar.gz" "$url" && tar -xzf "$work_tmp/matt.tar.gz" -C "$work_tmp/matt"; then
    matt_src=$work_tmp/matt
    return 0
  fi
  matt_download_failed=true
  warnings+=("WARNING: could not download Matt Pocock's skills from $url: the project install went on without them.")
  return 1
}

install_matt_skills() {
  local p skill dest found_path dir installed
  for p in "${providers[@]}"; do
    matt_scan "$p"
    dest=$(matt_dest "$p")
    installed=()
    for skill in "${MATT_SKILLS[@]}"; do
      matt_found "$skill" && continue
      fetch_matt || return 0
      # Located by name, not by his folder layout (today skills/<group>/<name>); the shortest path wins.
      found_path=$(find "$matt_src" -type f -path "*/$skill/SKILL.md" 2>/dev/null | awk '{ print length($0) " " $0 }' | sort -n | head -n 1 | cut -d' ' -f2- || true)
      if [[ -z $found_path ]]; then
        warnings+=("WARNING: skill '$skill' is not in the archive of $MATT_URL (ref $matt_ref); it was not installed for $p.")
        continue
      fi
      dir=$(dirname -- "$found_path")
      if [[ -e $dest/$skill ]]; then
        warnings+=("WARNING: $dest/$skill exists but has no SKILL.md; it was left untouched and the skill was not installed for $p.")
        continue
      fi
      mkdir -p "$dest"
      cp -r -- "$dir" "$dest/$skill"
      installed+=("$skill")
    done
    ((${#installed[@]} == 0)) || machine_done+=("Matt Pocock's skills for $p in $dest: $(join ' ' "${installed[@]}")")
  done
  return 0
}

if [[ $machine_setup == true ]]; then
  install_system_commands
  for p in "${providers[@]}"; do install_provider_cli "$p"; done
  install_matt_skills
fi

missing=()
for cmd in bash git jq python3 flock setsid cmp tar; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
((${#missing[@]} == 0)) || die "missing required commands: $(join ' ' "${missing[@]}") (run without --no-machine-setup to install them)"

[[ $project_validated == true ]] || validate_project

# ---------------------------------------------------------------------------------------------------------
# Project install.

had_agentic=false
[[ -d $project/.agentic ]] && had_agentic=true

# Engine. An existing project.json is never touched.
mkdir -p "$project/.agentic"
find "$project/.agentic" -mindepth 1 -maxdepth 1 ! -name project.json -exec rm -rf {} +
tar -C "$KIT/agentic" --exclude='__pycache__' --exclude='*.pyc' -cf - . | tar -C "$project/.agentic" -xf -
if [[ $had_agentic == true ]]; then changed+=('.agentic/'); else created+=('.agentic/'); fi

# Project configuration.
detect_branch() {
  if git -C "$project" show-ref --verify --quiet refs/heads/main; then echo main
  elif git -C "$project" show-ref --verify --quiet refs/heads/master; then echo master
  else git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main
  fi
}
if [[ ! -f $project/.agentic/project.json ]]; then
  [[ -f $KIT/agentic/project.json.example ]] || die 'the kit is missing agentic/project.json.example'
  jq --arg name "$(basename -- "$project")" --arg branch "$(detect_branch)" \
    '.name = $name | .main_branch = $branch' "$KIT/agentic/project.json.example" >"$project/.agentic/project.json"
  created+=('.agentic/project.json')
fi
main_branch=$(jq -r '.main_branch // ""' "$project/.agentic/project.json" 2>/dev/null || true)
[[ -n $main_branch ]] || main_branch=$(detect_branch)

# Provider skills.
for p in "${providers[@]}"; do
  dest=$project/.$p/skills
  mkdir -p "$dest"
  for skill_dir in "$KIT/skills/$p"/*/; do
    skill=$(basename -- "$skill_dir")
    if [[ -e $dest/$skill ]]; then
      if [[ $update == true ]]; then
        rm -rf "$dest/$skill"; cp -r "$skill_dir" "$dest/$skill"; changed+=(".$p/skills/$skill/")
      else
        warnings+=("kept the existing .$p/skills/$skill (use --update to overwrite it)")
      fi
    else
      cp -r "$skill_dir" "$dest/$skill"; created+=(".$p/skills/$skill/")
    fi
  done
done

# Tracker configuration: /to-spec and /to-tickets publish wherever this file says.
if [[ ! -e $project/$TRACKER ]]; then
  mkdir -p "$project/docs/agents"
  cp "$KIT/templates/$TRACKER" "$project/$TRACKER"
  created+=("$TRACKER")
elif ! cmp -s -- "$KIT/templates/$TRACKER" "$project/$TRACKER"; then
  if [[ $replace_tracker == true ]]; then
    cp -- "$KIT/templates/$TRACKER" "$project/$TRACKER"
    changed+=("$TRACKER (replaced with the kit's template)")
  else
    warnings+=("WARNING: $TRACKER already exists and differs from the kit's template, so it was kept. /to-spec and /to-tickets publish wherever that file says, NOT into campaigns, and the campaign workflow will not work until it says so. Replace it with templates/$TRACKER from the kit, or run this installer again with --replace-tracker (it overwrites the file).")
  fi
fi

# Instruction file: the rules block always goes into AGENTS.md (created when missing). CLAUDE.md is never touched.
action=$(python3 -I - "$project/$INSTRUCTION_FILE" "$KIT/templates/AGENTS.md" "$BLOCK_START" "$BLOCK_END" <<'PY'
import os, sys
path, template, start, end = sys.argv[1:5]
with open(template, newline="") as f:
    block = f.read().strip("\n")
if not (block.startswith(start) and block.endswith(end)):
    sys.exit("install.sh: the template block lacks its markers")
text = open(path, newline="").read() if os.path.exists(path) else None
if text is None:
    new, action = block + "\n", "created"
elif start in text:
    a = text.index(start)
    b = text.find(end, a)
    if b < 0:
        sys.exit(f"install.sh: {path} has a '{start}' marker without its end marker")
    b += len(end)
    new, action = text[:a] + block + text[b:], "updated"
else:
    trailing = len(text) - len(text.rstrip("\n"))
    sep = "\n" * max(0, 2 - trailing) if text else ""
    new, action = text + sep + block + "\n", "appended"
if text != new:
    with open(path, "w", newline="") as f:
        f.write(new)
print(action if text != new else "unchanged")
PY
)
case "$action" in
  created) created+=("$INSTRUCTION_FILE") ;;
  appended|updated) changed+=("$INSTRUCTION_FILE (stakhanov block $action)") ;;
esac
if [[ -L $project/$INSTRUCTION_FILE ]]; then
  warnings+=("$INSTRUCTION_FILE is a symlink to $(readlink -- "$project/$INSTRUCTION_FILE"); the stakhanov block went into the file it points to.")
fi

# A second "## Agent skills" section outside the stakhanov markers conflicts with the block.
for f in CLAUDE.md "$INSTRUCTION_FILE"; do
  [[ -f $project/$f ]] || continue
  if awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
      index($0, start) { skip = 1 }
      !skip && /^##[ \t]+Agent skills[ \t]*$/ { found = 1 }
      index($0, end) { skip = 0 }
      END { exit !found }' "$project/$f"; then
    warnings+=("WARNING: $f has its own '## Agent skills' section outside the stakhanov block. It conflicts with the block (for example a different issue tracker). Keep one section, the one that points to $TRACKER.")
  fi
done

# Matt Pocock's skills that are still missing (the machine setup installs them unless it was skipped or failed).
matt_missing=false
for p in "${providers[@]}"; do
  matt_scan "$p"
  for skill in "${MATT_SKILLS[@]}"; do
    if ! matt_found "$skill"; then
      warnings+=("WARNING: could not confirm skill '$skill' for $p (looked in .$p/skills, ~/.$p/skills, .agents/skills, ~/.agents/skills and the plugins under ~/.$p/plugins).")
      matt_missing=true
    fi
  done
done
if [[ $matt_missing == true ]]; then
  warnings+=("The workflow needs those skills. A run without --no-machine-setup installs them unmodified from $MATT_URL; or install them yourself and ignore this warning.")
fi

note ''
note "Stakhanov installed in $project"
note ''
if ((${#machine_done[@]})); then note 'Installed on this machine:'; printf '  %s\n' "${machine_done[@]}"; note ''; fi
if ((${#created[@]})); then note 'Created in the project:'; printf '  %s\n' "${created[@]}"; fi
if ((${#changed[@]})); then note 'Changed in the project:'; printf '  %s\n' "${changed[@]}"; fi
if ((${#warnings[@]})); then note ''; printf '%s\n' "${warnings[@]}"; fi
if ((${#login_needed[@]})); then
  note ''
  note 'Log in (this installer never logs in): open each of these once and sign in:'
  printf '  %s\n' "${login_needed[@]}"
fi

commit_paths=(.agentic)
for p in "${providers[@]}"; do commit_paths+=(".$p/skills"); done
commit_paths+=("$INSTRUCTION_FILE" "$TRACKER")
commit_list=$(join ' ' "${commit_paths[@]}")
cat <<NEXT

Next steps:
  1. Edit .agentic/project.json if needed (main branch, required checks, time zone, archive folder).
  2. Commit the kit on the main branch ($main_branch), because /to-spec's 'campaign init' refuses an
     uncommitted kit:
       git add $commit_list
       git commit -m 'chore: install the Stakhanov campaign kit'
  3. Then, in your agent: /grilling -> /to-spec -> /to-tickets -> /run-campaign -> /finalize-campaign
NEXT

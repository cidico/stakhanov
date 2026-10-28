# Executor package

Turns a Linux machine into a Stakhanov executor: a host that runs workers and offloaded commands
(`.agentic/bin/offload`) for the projects of a controlling machine (see "Remote executors" and "Offloading commands" in
`agentic/README.md`). The engine on the controlling machine does the transport (mirror, checkout, rsync both ways); this
package is what runs on the host: the run prefix, the admission, the capacity, the Claude accounts and the isolation of
the runs. It is installed on the host from the controlling machine with `install.sh`, never into a project.

```
bin/agentic-executor-run     the run prefix ("run" of the executors entry)
bin/agentic-executor-admit   the admission ("admit"): exit 0 when AGENTIC_UNITS units are free and nobody waits
bin/agentic-executor-status  free units, waiting and running runs, accounts
bin/agentic-executor-netns   the optional network namespace of the runs (up, down, status)
lib/                         config.sh (settings), units.sh (capacity), session.sh (ssh session watch), hostrun.sh (one run)
accounts/claude              claude for the runs: logs in with the account's long-lived token
accounts/agentic-executor-accounts   the Claude account hook of the runs (udarnik's `account` commands)
executor.conf.example        the settings, installed at /etc/agentic/executor.conf
install.sh                   installs or updates the package on a host
token.sh                     stores a long-lived Claude token on a host
tests/executor.sh            tests with stubs, no root
```

## Adding a machine

Prerequisites on the host:

- Linux with systemd, reachable over ssh as root from the controlling machine with a key and no prompt (the engine uses
  `BatchMode`). An `ssh_config` entry with `ControlMaster auto` and `ControlPersist` makes the many short connections of
  a run cheap.
- `bash`, `git`, `rsync`, `flock`, `setsid`, `setpriv`, `unshare`, `mount` (util-linux), `useradd`, `setfacl` (acl: the
  synced files arrive owned by root and the run user changes them through the group's ACL); `ip` (iproute2) only for a
  network namespace.
- The projects' own toolchains (compilers, SDKs, `jq` and `python3` for the engine's adapter), on the standard PATH or
  in `EXECUTOR_PATH`, and Docker only when the projects' tests start containers.
- The `claude` binary at `EXECUTOR_CLAUDE`, readable by the run user. The official installer puts it under root's home,
  which the run user cannot read; copy the binary out, for example:
  `curl -fsSL https://claude.ai/install.sh | bash && install -D -m 755 "$(readlink -f ~/.local/bin/claude)" /usr/local/lib/agentic-claude/claude`.

Then, from the controlling machine (in a clone of the kit):

1. Write the settings from `executor.conf.example`. At least `EXECUTOR_BIND_PATHS` (the folders of the controlling
   machine that hold the worktrees, the runtime cache and the engine: usually the home of the user who runs campaigns),
   the capacity (`EXECUTOR_UNITS`, `EXECUTOR_WORKER_UNITS`) and the accounts (`EXECUTOR_ACCOUNTS`).
2. `executor/install.sh root@host --config my-executor.conf --dry-run` checks them and prints the plan; without
   `--dry-run` it installs. Run it again after any change; without `--config` the host keeps its settings.
3. `executor/token.sh root@host ACCOUNT` once per account of `EXECUTOR_ACCOUNTS` (see [Tokens](#tokens)).
4. Paste the printed entry into the project's `.agentic/project.json` `executors` list, add its `exclude` (build output
   and dependencies that should stay on each side), `requires` (the toolchain commands the project's runs need) and
   `env`, and commit it on the main branch.
5. Check: `ssh root@host agentic-executor-status`, then from the project `.agentic/bin/offload -- uname -a`.

`install.sh DEST [--config FILE] [--dry-run]` copies the package to `/usr/local/lib/agentic-executor` (replaced in one
rename) and `FILE` to `/etc/agentic/executor.conf`, then, as root there:

- creates the run group and user (`EXECUTOR_GROUP`, `EXECUTOR_USER`, a system user without login) and adds it to
  `EXECUTOR_USER_GROUPS`;
- creates the mirror root and `<EXECUTOR_ROOT><P>` for every bound path `P` (root-owned, group the run group, setgid,
  `2770`, closed to other users, with a default ACL that keeps what root writes there group-writable), the state folder
  with `units`, `runs` and `accounts`, the accounts folder (`700`, the run user's) and the mount points `P` when missing;
- writes the slice `EXECUTOR_SLICE` (`CPUWeight=20`, `IOWeight=20`, `CPUQuota`, `MemoryMax`) and, with `EXECUTOR_NETNS`,
  enables `agentic-executor-netns.service` (removing it when `EXECUTOR_NETNS` is emptied);
- links the four commands into `/usr/local/bin`;
- touches nothing else, and prints the `executors` entry to paste, named after the host:

```json
{"name": "build-box", "ssh": "root@build-box", "workers": 4, "root": "/srv/agentic/work",
 "run": ["/usr/local/bin/agentic-executor-run"], "admit": ["/usr/local/bin/agentic-executor-admit"],
 "worker_units": 1, "rsync_options": ["--chmod=g+rwX"], "exclude": [], "requires": [], "env": {}}
```

`root` must equal `EXECUTOR_ROOT`. `workers` (tickets at once) starts as `EXECUTOR_UNITS / EXECUTOR_WORKER_UNITS`;
`worker_units` is what a worker asks for. `rsync_options` keeps the synced files group-writable: the engine's files are
owner-only on the controlling machine, the ssh login is root and the runs execute as the run user.

## A run

The engine runs `env AGENTIC_UNITS=<n> agentic-executor-run env NAME=VALUE... COMMAND...` over a connection of its own.
The run prefix, as root:

1. takes `AGENTIC_UNITS` units (default `EXECUTOR_WORKER_UNITS`; `0` takes none, as the engine's check of `requires`
   does), waiting while they are busy and saying so once on stderr; more than `EXECUTOR_UNITS` exits 64;
2. watches the ssh session it came from: when it ends (the runner died), the run stops, waiting or running;
3. runs the command in the scope `agentic-run-<time>-<pid>.scope` of `EXECUTOR_SLICE`, in a mount namespace of its own
   where every `P` of `EXECUTOR_BIND_PATHS` is `<EXECUTOR_ROOT><P>` bound at `P` (so the controlling machine's paths
   exist), in the network namespace `EXECUTOR_NETNS` when set, as the run user, from the first bound path, with
   `umask 002`;
4. waits, then stops the scope (nothing the command left keeps running or holding units); TERM or INT stops it at once
   (exit 143). The status is the command's.

The run's environment starts empty (`env -i`) and gets, in this order (a later one wins): `HOME` (the first bound path),
`USER`, `LANG=C.UTF-8`, `PATH` (the package's `accounts/` with its `claude` and hook, then `EXECUTOR_PATH`, then the
standard folders), `DISABLE_AUTOUPDATER=1`, `safe.directory=*` for git, `AGENTIC_UNITS`, `CLAUDE_CONFIG_DIR` (the first
account), the proxies; the lines of `EXECUTOR_ENV_FILE`; the command's own leading `env NAME=VALUE...` words (the
runner's `AGENTIC_*` variables, the project's and the executor's `env`); and last `AGENTIC_EXECUTOR_RUN=1`,
`AGENTIC_CLAUDE_ACCOUNTS=<the package hook>`, `AGENTIC_EXECUTOR_CONF` and `CLAUDE_CONFIG_DIR`, which always win (an
offload inside the run then runs there, and claude uses this host's accounts whatever the runner forwarded).

## Units

`EXECUTOR_UNITS` is the host's capacity, in units of whatever one heavy run costs there (for example one test
partition). A run holds its units as flock locks in `<EXECUTOR_STATE_DIR>/units` until its last process exits. While a
run waits for units, no new run is admitted, so a large one is never starved by small ones.
`agentic-executor-admit [N]` (N defaults to `AGENTIC_UNITS`, then `EXECUTOR_WORKER_UNITS`) exits 0 when N units are
free and nobody waits, else prints `free=F/T waiting=yes|no` and exits 1: the runner then keeps that worker, or runs
that offloaded command, on its own machine instead of waiting here. `agentic-executor-status` shows the free units,
every waiting or running run (its units, age and command) and the accounts.

## Tokens

`token.sh DEST ACCOUNT [--config-dir DIR]` runs `claude setup-token` on the controlling machine (the browser logs into
the account; `--config-dir` picks a `CLAUDE_CONFIG_DIR` there), reads the token without echo and sends it on ssh's
stdin to `<EXECUTOR_ACCOUNTS_DIR>/<ACCOUNT>/token` on the host, owned by the run user, mode 600. It is never written on
the controlling machine nor put in a command line. Add `ACCOUNT` to `EXECUTOR_ACCOUNTS` (the order is the order of use).

In a run, `claude` (`accounts/claude`) exports the token of the account in `CLAUDE_CONFIG_DIR` as
`CLAUDE_CODE_OAUTH_TOKEN` and runs `EXECUTOR_CLAUDE`. The hook `agentic-executor-accounts` (`account enabled`,
`current`, `limit ACCOUNT`, `next`, `env ACCOUNT`, `pick [EXCLUDE...]`) lets the Claude adapter go on in the next
account after a usage limit: the account is out until the reset its message names (`resets 3:30pm (Area/City)`, one
hour when none), in `<EXECUTOR_STATE_DIR>/accounts`, shared by every run on the host.

## Settings

`/etc/agentic/executor.conf` (shell `KEY=VALUE`, read by every command as root and as the run user; no secrets):

| Key | Default | Meaning |
| --- | --- | --- |
| `EXECUTOR_USER`, `EXECUTOR_GROUP` | `agentic` | The run user and its group. |
| `EXECUTOR_USER_GROUPS` | | Extra groups of the run user (for example `docker`). |
| `EXECUTOR_ROOT` | `/srv/agentic/work` | The mirror root; equals the entry's `root`. |
| `EXECUTOR_BIND_PATHS` | (required) | Paths of the controlling machine presented at their place in a run; the first is `HOME`. |
| `EXECUTOR_STATE_DIR` | `/srv/agentic/state` | Units, run records and account limits. |
| `EXECUTOR_UNITS` | `4` | Capacity in units. |
| `EXECUTOR_WORKER_UNITS` | `1` | Units of a run that does not say. |
| `EXECUTOR_SLICE` | `agentic-executor.slice` | The slice of every run. |
| `EXECUTOR_CPU_QUOTA`, `EXECUTOR_MEMORY_MAX` | no cap | The slice's `CPUQuota` (100% per thread) and `MemoryMax`. |
| `EXECUTOR_NETNS` | host network | The runs' network namespace. |
| `EXECUTOR_NETNS_BRIDGE`, `EXECUTOR_NETNS_ADDRESS` | | Its veth's bridge and address (CIDR); required with a namespace. |
| `EXECUTOR_NETNS_GATEWAY` | no route | Its default route; without one it reaches the bridge's network alone. |
| `EXECUTOR_NETNS_AFTER` | | Units that create the bridge (for example `docker.service`). |
| `EXECUTOR_PROXY`, `EXECUTOR_NO_PROXY` | none, `localhost,127.0.0.1` | The runs' HTTP proxy and its exceptions. |
| `EXECUTOR_ACCOUNTS_DIR` | `/srv/agentic/accounts` | The Claude account folders. |
| `EXECUTOR_ACCOUNTS` | | Account folder names, in the order of use. |
| `EXECUTOR_CLAUDE` | `/usr/local/lib/agentic-claude/claude` | The real claude binary. |
| `EXECUTOR_ENV_FILE` | `/etc/agentic/executor.env` | `NAME=VALUE` lines for every run, when the file exists. |
| `EXECUTOR_PATH` | | Extra PATH folders for the runs (colon-separated). |

`AGENTIC_EXECUTOR_CONF` names another settings file (the tests use it); a run gets the one its prefix read.

## Security

- The controlling machine logs in as root: whoever controls it (and its ssh key) controls this host. Give the key to
  that machine only, and keep the host for this purpose.
- A run is not a sandbox against its own project: it executes the project's code and the worker's commands as the run
  user. What it cannot do is act as root, leave its slice's caps, outlive its ssh session or scope, or, with a network
  namespace without a gateway, reach anything but the bridge's network and the proxy.
- Every project and every run on the host share the run user: a run can read the other runs' worktrees and the account
  tokens (claude needs them). One host is one trust domain; give it only the accounts its workers may use.
- Membership of `docker` (`EXECUTOR_USER_GROUPS`) is root on this host in all but name, and Docker's own networks
  bypass the namespace; add it only when the projects need containers.
- Tokens are mode 600 and owned by the run user, travel only on ssh's stdin, and reach claude only through its
  environment. The settings file is world-readable: keep secrets out of it; `EXECUTOR_ENV_FILE` is read by root, so it
  may be mode 600, but every run sees its values.

## Updating and removing

Run `install.sh` again (without `--config` the host keeps its settings); runs in progress keep the files they started
with. To remove the package: `systemctl disable --now agentic-executor-netns.service` (when enabled), then delete
`/usr/local/lib/agentic-executor`, the four links in `/usr/local/bin`, `/etc/agentic`, the slice and service files in
`/etc/systemd/system`, `EXECUTOR_ROOT`, `EXECUTOR_STATE_DIR`, `EXECUTOR_ACCOUNTS_DIR` and the run user.

## Tests

`bash executor/tests/executor.sh` runs without root: stub `systemd-run`, `systemctl`, `ip`, `setpriv`, `unshare`,
`mount`, `ssh` and `claude`, and settings of temporary folders. The user switch, the namespaces and the slice are
proven on a real host.

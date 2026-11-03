#!/usr/bin/env python3
"""Session mode of the claude provider: the request queue of the machine and the watch over a hosted subagent.

In session mode no `claude --print` process runs. The adapter files a request in the machine's queue
(`$AGENTIC_SESSION_DIR`, default `${XDG_STATE_HOME:-~/.local/state}/agentic-session`) and an interactive claude session
that registered itself as a host (`bin/session-host`) runs the role as a background subagent. This module is both the
library of that queue (used by `bin/session-host`) and the command line of the adapter side:

  session.py live                       exit 0 when a live host session exists on this machine
  session.py model-alias MODEL          the Agent tool alias of a model id (opus, sonnet, haiku or fable), or exit 1
  session.py submit ...                 files a request and prints its folder
  session.py inspect DIR STATE IDLE     one JSON verdict about the request and its subagent
  session.py usage DIR OUT              the usage of the subagent's transcript, in the shape of the provider usage files

Queue layout: hosts/<pid>.json and requests/<id>/ with request.json and the markers assigned, done, cancel, cancelled
(plus reserved, dispatches, limited and finished). Every file is written atomically (a temporary file and a rename).
"""

import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time

HZ = os.sysconf("SC_CLK_TCK")
TAIL_BYTES = 4 * 1024 * 1024
MODEL_ALIASES = ("opus", "sonnet", "haiku", "fable")
SHELLS = {"bash", "sh", "zsh", "dash"}
LIMIT_TEXT = re.compile(r"hit your .*limit|usage limit reached", re.IGNORECASE)
# A reservation (the host that is about to start the subagent) holds the request this long.
RESERVATION_SECONDS = 120
# A finished request is kept for this long for diagnosis.
FINISHED_KEEP_SECONDS = 24 * 3600
# A request whose adapter is gone and that nobody took is removed after this long.
ABANDONED_KEEP_SECONDS = 600


# ---------------------------------------------------------------------------------------------------------
# Files

def session_dir():
    explicit = os.environ.get("AGENTIC_SESSION_DIR")
    if explicit:
        return explicit
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "agentic-session")


def hosts_dir():
    return os.path.join(session_dir(), "hosts")


def requests_dir():
    return os.path.join(session_dir(), "requests")


def write_atomic(path, text=""):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value):
    write_atomic(path, json.dumps(value, separators=(",", ":")) + "\n")


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as stream:
            return stream.read()
    except OSError:
        return None


def read_json(path):
    text = read_text(path)
    if text is None:
        return None
    try:
        return json.loads(text)
    except ValueError:
        return None


def mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


# ---------------------------------------------------------------------------------------------------------
# Processes

def stat_fields(pid):
    """The fields of /proc/PID/stat after the command name: [0] state, [1] ppid, [11] utime, [19] starttime."""
    raw = read_text("/proc/%s/stat" % pid)
    if not raw:
        return None
    fields = raw.rpartition(")")[2].split()
    return fields if len(fields) > 19 else None


def proc_start(pid):
    fields = stat_fields(pid)
    return fields[19] if fields else None


def pid_alive(pid, start):
    """True when PID runs and is still the process that started at START (a reused PID has another start time)."""
    if not isinstance(pid, int) or start is None:
        return False
    fields = stat_fields(pid)
    return bool(fields) and fields[0] != "Z" and fields[19] == str(start)


def parent_of(pid):
    fields = stat_fields(pid)
    return int(fields[1]) if fields else 0


def comm_of(pid):
    text = read_text("/proc/%s/comm" % pid)
    return text.strip() if text else ""


def cgroup_of(pid):
    """The cgroup path of a process (unified hierarchy), or ''."""
    for line in (read_text("/proc/%s/cgroup" % pid) or "").splitlines():
        if line.startswith("0::"):
            return line[3:]
    return ""


def find_claude():
    """The pid of the claude process that runs this command: the first ancestor whose name is claude."""
    pid = os.getppid()
    seen = set()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        if comm_of(pid) == "claude":
            return pid
        pid = parent_of(pid)
    fallback = os.environ.get("CLAUDE_PID", "")
    if fallback.isdigit() and comm_of(int(fallback)) == "claude":
        return int(fallback)
    return None


# ---------------------------------------------------------------------------------------------------------
# Hosts

def load_hosts():
    hosts = []
    for path in sorted(glob.glob(os.path.join(hosts_dir(), "*.json"))):
        host = read_json(path)
        if isinstance(host, dict) and isinstance(host.get("pid"), int):
            host["alive"] = pid_alive(host["pid"], host.get("start"))
            host["path"] = path
            hosts.append(host)
    return hosts


def live_hosts():
    return [host for host in load_hosts() if host["alive"]]


def host_of(pid):
    for host in load_hosts():
        if host["pid"] == pid:
            return host
    return None


# ---------------------------------------------------------------------------------------------------------
# Requests

def request_folders():
    folders = []
    for path in glob.glob(os.path.join(requests_dir(), "*")):
        if os.path.isdir(path) and not os.path.basename(path).startswith("."):
            request = read_json(os.path.join(path, "request.json"))
            if isinstance(request, dict):
                folders.append((request.get("created") or 0, path, request))
    folders.sort(key=lambda item: (item[0], item[1]))
    return [(path, request) for _, path, request in folders]


def has(folder, name):
    return os.path.exists(os.path.join(folder, name))


def adapter_alive(request):
    if "adapter_pid" not in request:
        return True
    return pid_alive(request["adapter_pid"], request.get("adapter_start"))


def assigned_alive(assigned):
    return isinstance(assigned, dict) and pid_alive(assigned.get("host_pid"), assigned.get("host_start"))


def reservation(folder):
    """The live, fresh reservation of a request, or None."""
    reserved = read_json(os.path.join(folder, "reserved"))
    if not isinstance(reserved, dict):
        return None
    if time.time() - reserved.get("at", 0) > RESERVATION_SECONDS or not pid_alive(reserved.get("host_pid"), reserved.get("host_start")):
        return None
    return reserved


def request_state(folder, request):
    if has(folder, "finished"):
        return "finished"
    if has(folder, "cancelled"):
        return "cancelled"
    if has(folder, "done"):
        return "done"
    if not adapter_alive(request):
        return "abandoned"
    if has(folder, "cancel"):
        return "cancelling"
    assigned = read_json(os.path.join(folder, "assigned"))
    if assigned is not None:
        return "running" if assigned_alive(assigned) else "orphaned"
    return "reserved" if reservation(folder) else "pending"


def prune():
    """Removes the host files of dead hosts, hands back the requests of dead hosts and drops old leftovers.
    Returns the number of requests put back in the queue."""
    for host in load_hosts():
        if not host["alive"]:
            try:
                os.unlink(host["path"])
            except OSError:
                pass
    requeued = 0
    now = time.time()
    for folder, request in request_folders():
        state = request_state(folder, request)
        if state == "orphaned":
            try:
                os.unlink(os.path.join(folder, "assigned"))
                requeued += 1
            except OSError:
                pass
        elif state == "finished" or (state in ("abandoned", "cancelled") and not adapter_alive(request)):
            marker = "finished" if state == "finished" else "request.json"
            age = now - (mtime(os.path.join(folder, marker)) or now)
            if age > (FINISHED_KEEP_SECONDS if state == "finished" else ABANDONED_KEEP_SECONDS):
                shutil.rmtree(folder, ignore_errors=True)
    return requeued


def model_alias(model):
    lowered = (model or "").lower()
    for alias in MODEL_ALIASES:
        if alias in lowered:
            return alias
    return None


# ---------------------------------------------------------------------------------------------------------
# Transcripts

def resolve_transcript(assigned):
    """The transcript file of the assigned subagent: the stored path, or its glob when the file had not appeared yet."""
    stored = assigned.get("transcript") or ""
    if stored and os.path.isfile(stored):
        return stored
    if stored and any(character in stored for character in "*?["):
        matches = glob.glob(stored)
        if matches:
            return matches[0]
    return None


def tail_entries(path):
    """The user and assistant entries of the end of a transcript, oldest first."""
    size = os.path.getsize(path)
    with open(path, "rb") as stream:
        stream.seek(max(0, size - TAIL_BYTES))
        data = stream.read()
    lines = data.split(b"\n")
    if size > TAIL_BYTES:
        lines = lines[1:]
    entries = []
    for line in lines:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get("type") in ("user", "assistant"):
            entries.append(entry)
    return entries


def blocks(entry):
    content = (entry.get("message") or {}).get("content")
    return [block for block in content if isinstance(block, dict)] if isinstance(content, list) else []


def entry_text(entry):
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    return " ".join(block.get("text", "") for block in blocks(entry) if block.get("type") == "text")


def classify(entries):
    """What the end of a transcript says: kind finished, pending (a tool call waits for its result), model (the model
    is working) or empty; the Bash commands of the pending calls; and the usage-limit error it ends with, if any."""
    result = {"kind": "empty", "bash": [], "limit": None}
    if not entries:
        return result
    last = entries[-1]
    if last["type"] == "assistant" and last.get("isApiErrorMessage") is True:
        text = entry_text(last)
        if last.get("error") == "rate_limit" or LIMIT_TEXT.search(text):
            result["limit"] = {"text": text[:2000], "id": str(last.get("uuid") or hashlib.sha256(text.encode()).hexdigest()[:16])}
    answered = {block.get("tool_use_id") for entry in entries if entry["type"] == "user"
                for block in blocks(entry) if block.get("type") == "tool_result"}
    trailing = []
    for entry in reversed(entries):
        if entry["type"] != "assistant":
            break
        trailing.append(entry)
    if not trailing:
        result["kind"] = "model"
        return result
    uses = [block for entry in trailing for block in blocks(entry) if block.get("type") == "tool_use"]
    pending = [block for block in uses if block.get("id") not in answered]
    if pending:
        result["kind"] = "pending"
        result["bash"] = [(block.get("input") or {}).get("command", "") for block in pending
                          if block.get("name") == "Bash" and not (block.get("input") or {}).get("run_in_background")]
        return result
    stop = (trailing[0].get("message") or {}).get("stop_reason")
    result["kind"] = "finished" if stop in ("end_turn", "stop_sequence", "max_tokens") and not uses else "model"
    return result


# ---------------------------------------------------------------------------------------------------------
# Processes of a pending Bash call

def read_processes():
    """{pid: {ppid, cpu, argv}} for every process; cpu is utime + stime + the time of the children it waited for."""
    processes = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        fields = stat_fields(pid)
        if not fields:
            continue
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as stream:
                argv = [part.decode("utf-8", "replace") for part in stream.read().split(b"\0") if part]
        except OSError:
            argv = []
        processes[pid] = {"ppid": int(fields[1]), "cpu": sum(int(value) for value in fields[11:15]), "argv": argv}
    return processes


def process_io(pid):
    total = 0
    text = read_text("/proc/%d/io" % pid)
    for line in (text or "").splitlines():
        key, _, value = line.partition(":")
        if key in ("read_bytes", "write_bytes"):
            total += int(value)
    return total


def normalize(text):
    return re.sub(r"\s+", " ", text.replace("'\"'\"'", "'")).strip()


def cgroup_members(cgroup):
    """The pids of a cgroup, or None when it cannot be read."""
    if not cgroup:
        return None
    text = read_text("/sys/fs/cgroup%s/cgroup.procs" % cgroup)
    if text is None:
        return None
    return {int(value) for value in text.split() if value.isdigit()}


def command_roots(command, processes, members):
    """The wrapper shells (`bash -c ... eval '<command>'`) of a Bash tool call: the processes whose command line carries
    the command text. Only shells run with -c count (claude's own command line holds the launch prompt)."""
    needle = normalize(command)
    if not needle:
        return set()
    short = needle[:200]
    roots = set()
    for pid, process in processes.items():
        argv = process["argv"]
        if pid == os.getpid() or (members is not None and pid not in members):
            continue
        if not argv or os.path.basename(argv[0]) not in SHELLS or "-c" not in argv[1:3]:
            continue
        haystack = normalize(" ".join(argv))
        if needle in haystack or short in haystack:
            roots.add(pid)
    return roots


def descendants(roots, processes):
    children = {}
    for pid, process in processes.items():
        children.setdefault(process["ppid"], []).append(pid)
    seen, stack = set(roots), list(roots)
    while stack:
        for child in children.get(stack.pop(), []):
            if child not in seen:
                seen.add(child)
                stack.append(child)
    return seen


def work_signature(commands, cgroup):
    """[cpu ticks, io bytes, process count] of the processes running the pending Bash commands and their descendants,
    or None when no such process is found."""
    processes = read_processes()
    members = cgroup_members(cgroup)
    tree = set()
    for command in commands:
        tree |= descendants(command_roots(command, processes, members), processes)
    if not tree:
        return None
    return [sum(processes[pid]["cpu"] for pid in tree), sum(process_io(pid) for pid in tree), len(tree)]


# ---------------------------------------------------------------------------------------------------------
# Adapter side

def command_live(_args):
    return 0 if live_hosts() else 1


def command_model_alias(args):
    alias = model_alias(args.model)
    if alias is None:
        return 1
    print(alias)
    return 0


def command_submit(args):
    """Files a request: the whole folder is built under a hidden name and renamed into place, so a host never sees it half
    written. Prints the folder."""
    final = os.path.join(requests_dir(), args.id)
    attempt = 1 + sum(1 for _, other in request_folders()
                      if other.get("worktree") == args.worktree and other.get("role") == args.role
                      and other.get("ticket") == args.ticket)
    os.makedirs(requests_dir(), mode=0o700, exist_ok=True)
    staging = tempfile.mkdtemp(prefix=".new-", dir=requests_dir())
    prompt_copy = os.path.join(final, "prompt.md")
    schema_copy = os.path.join(final, "schema.json")
    for source, name in ((args.prompt, "prompt.md"), (args.schema, "schema.json")):
        write_atomic(os.path.join(staging, name), read_text(source) or "")
    adapter_pid = args.adapter_pid
    write_json(os.path.join(staging, "request.json"), {
        "id": args.id,
        "project": args.project,
        "ticket": args.ticket,
        "role": args.role,
        "model": args.model,
        "effort": args.effort,
        "read_only": args.read_only == "true",
        "worktree": args.worktree,
        "prompt": prompt_copy,
        "result": os.path.join(final, "result.json"),
        "done": os.path.join(final, "done"),
        "schema": schema_copy,
        "created": int(time.time()),
        "attempt": attempt,
        "adapter_pid": adapter_pid,
        "adapter_start": proc_start(adapter_pid),
    })
    os.rename(staging, final)
    print(final)
    return 0


def command_inspect(args):
    folder = args.folder
    now = time.time()
    state = read_json(args.state) or {}
    assigned = read_json(os.path.join(folder, "assigned"))
    if assigned is None:
        if os.path.exists(args.state):
            os.unlink(args.state)
        print(json.dumps({"verdict": "unassigned"}))
        return 0
    host = host_of(assigned.get("host_pid"))
    account = (host or {}).get("account") or assigned.get("account") or ""
    base = {"account": account, "agent_id": assigned.get("agent_id", "")}
    if not assigned_alive(assigned):
        # A dead host proves nothing about the subagent: its clock starts again when a host takes the request.
        if os.path.exists(args.state):
            os.unlink(args.state)
        print(json.dumps(dict(base, verdict="host-dead")))
        return 0
    if state.get("agent_id") != assigned.get("agent_id") or state.get("assigned_at") != assigned.get("at"):
        # The idle clock of a subagent starts when a host took the request.
        taken = assigned.get("at")
        state = {"agent_id": assigned.get("agent_id"), "assigned_at": taken,
                 "last_activity": min(now, taken) if isinstance(taken, (int, float)) else now}
    transcript = resolve_transcript(assigned)
    classification = state.get("class") or {"kind": "empty", "bash": [], "limit": None}
    if transcript:
        stamp = os.stat(transcript)
        key = [stamp.st_size, stamp.st_mtime_ns]
        if state.get("key") != key:
            classification = classify(tail_entries(transcript))
            state["key"] = key
            state["class"] = classification
        state["last_activity"] = max(state.get("last_activity", 0), stamp.st_mtime)
    if args.ack_limit:
        state["limit_handled"] = args.ack_limit
    limit = classification.get("limit")
    if limit and limit["id"] != state.get("limit_handled"):
        write_json(args.state, state)
        print(json.dumps(dict(base, verdict="limit", limit_text=limit["text"], limit_id=limit["id"])))
        return 0
    if classification["kind"] == "finished":
        state.setdefault("finished_at", now)
        write_json(args.state, state)
        print(json.dumps(dict(base, verdict="finished", finished_for=int(now - state["finished_at"]))))
        return 0
    state.pop("finished_at", None)
    commands = classification.get("bash") if classification["kind"] == "pending" else []
    signature = work_signature(commands, (host or {}).get("cgroup", "")) if commands else None
    if signature is not None and state.get("signature") is not None and signature != state["signature"]:
        state["last_activity"] = max(state["last_activity"], now)
    state["signature"] = signature
    write_json(args.state, state)
    idle_for = int(now - state["last_activity"])
    print(json.dumps(dict(base, verdict="idle" if idle_for >= args.idle else "working", idle_for=idle_for)))
    return 0


def command_usage(args):
    """The usage of the subagent: its assistant messages summed, once per message id (a message with several content blocks
    appears once per block). The transcript carries tokens but no cost, so cost_usd stays null."""
    assigned = read_json(os.path.join(args.folder, "assigned"))
    transcript = resolve_transcript(assigned) if isinstance(assigned, dict) else None
    if not transcript:
        return 1
    messages = {}
    models = {}
    first = last = None
    with open(transcript, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if '"usage"' not in line and '"timestamp"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict) or entry.get("type") not in ("assistant", "user"):
                continue
            moment = entry.get("timestamp")
            if isinstance(moment, str):
                try:
                    parsed = datetime.datetime.fromisoformat(moment.replace("Z", "+00:00")).timestamp()
                    first = parsed if first is None else min(first, parsed)
                    last = parsed if last is None else max(last, parsed)
                except ValueError:
                    pass
            message = entry.get("message")
            if entry["type"] != "assistant" or not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
                continue
            key = message.get("id") or entry.get("uuid")
            previous = messages.get(key)
            if previous is None or (message["usage"].get("output_tokens") or 0) >= (previous.get("output_tokens") or 0):
                messages[key] = message["usage"]
            model = message.get("model")
            if isinstance(model, str) and not model.startswith("<"):
                models[model] = models.get(model, 0) + 1

    def total(field):
        values = [usage.get(field) for usage in messages.values() if isinstance(usage.get(field), int)]
        return sum(values) if values else None

    record = {
        "provider": "claude",
        "model": max(models, key=models.get) if models else None,
        "cost_usd": None,
        "input_tokens": total("input_tokens"),
        "output_tokens": total("output_tokens"),
        "cache_read_tokens": total("cache_read_input_tokens"),
        "cache_creation_tokens": total("cache_creation_input_tokens"),
        "num_turns": len(messages) or None,
        "duration_ms": int((last - first) * 1000) if first is not None and last is not None else None,
    }
    write_json(args.out, record)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="session.py")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("live")
    alias = commands.add_parser("model-alias")
    alias.add_argument("model")
    submit = commands.add_parser("submit")
    for name in ("id", "project", "ticket", "role", "model", "effort", "read-only", "worktree", "prompt", "schema"):
        submit.add_argument("--" + name, required=True)
    submit.add_argument("--adapter-pid", type=int, required=True)
    inspect = commands.add_parser("inspect")
    inspect.add_argument("folder")
    inspect.add_argument("state")
    inspect.add_argument("idle", type=float)
    inspect.add_argument("--ack-limit", default="")
    usage = commands.add_parser("usage")
    usage.add_argument("folder")
    usage.add_argument("out")
    args = parser.parse_args(argv)
    handler = {"live": command_live, "model-alias": command_model_alias, "submit": command_submit,
               "inspect": command_inspect, "usage": command_usage}[args.command]
    return handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

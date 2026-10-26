#!/usr/bin/env python3
"""Enforce a provider deadline without orphaning its subprocesses or logging argv."""
import os
import signal
import subprocess
import sys
import time


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def terminate_group(process):
    def send(signum):
        try:
            os.killpg(process.pid, signum)
            return True
        except ProcessLookupError:
            return False

    if send(signal.SIGTERM):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            process.poll()
            if not send(0):
                break
            time.sleep(0.1)
        send(signal.SIGKILL)
    process.wait()


def main():
    seconds = int(sys.argv[1])
    if seconds <= 0 or len(sys.argv) < 3:
        return 64
    process = subprocess.Popen(sys.argv[2:], start_new_session=True)

    def interrupt(signum, _frame):
        raise Interrupted(signum)

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        result = process.wait(timeout=seconds)
        return result if result >= 0 else 128 - result
    except (subprocess.TimeoutExpired, Interrupted) as error:
        # Further interrupts must not bypass cleanup of our owned session.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        terminate_group(process)
        return 128 + error.signum if isinstance(error, Interrupted) else 124


if __name__ == '__main__':
    sys.exit(main())

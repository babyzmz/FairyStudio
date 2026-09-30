#!/usr/bin/env python3
"""Run a CI command with a wall-clock deadline and a persistent, flushed log.

Timeouts fail with 124; no failure is converted to success. No credentials are
accepted by this wrapper or printed intentionally. Use only for build/test tools.
"""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=int, required=True)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if args.timeout <= 0 or not command:
        parser.error('positive --timeout and a command are required')
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open('w', encoding='utf-8') as output:
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, errors='replace', bufsize=1,
                              start_new_session=True) as process:
            def stream() -> None:
                assert process.stdout is not None
                for line in process.stdout:
                    output.write(line)
                    output.flush()
                    print(line, end='', flush=True)
            pump = threading.Thread(target=stream, daemon=True)
            pump.start()
            try:
                result = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                print(f'::error::Command exceeded {args.timeout}s. Test/build did not pass.', flush=True)
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(process.pid, sig)
                    except ProcessLookupError:
                        break
                    try:
                        process.wait(timeout=10)
                        break
                    except subprocess.TimeoutExpired:
                        continue
                result = 124
            pump.join(timeout=10)
            if pump.is_alive():
                # A child retaining the log pipe is itself a failure, not a pass.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                pump.join(timeout=5)
                result = result or 124
            output.write(f'\nCI_COMMAND_EXIT={result}\n')
            output.flush()
            return result if result >= 0 else 128 - result


if __name__ == '__main__':
    sys.exit(main())

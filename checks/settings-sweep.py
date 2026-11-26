"""Run the button sweep again in a clean profile after a system dialog blocks a click."""
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

attempted = set()
exe = sys.argv[1]
with open('buttons.log', 'w', buffering=1) as total:
    for attempt in range(30):
        prior = len(attempted)
        env = dict(os.environ, LUMEN_QA_SKIP='\n'.join(sorted(attempted)))
        logfile = Path(f'buttons-{attempt}.log')
        with logfile.open('wb') as raw:
            proc = subprocess.Popen([exe, '--release-check'], stdout=raw, stderr=subprocess.STDOUT,
                                    env=env, start_new_session=True)
        with logfile.open() as read:
            deadline = time.monotonic() + 100
            last = None
            pid = None
            changed = False
            def process(line):
                global deadline, last, pid, changed
                total.write(line)
                if line.startswith('BUTTON KEY '):
                    last = line.strip()[len('BUTTON KEY '):]
                    attempted.add(last)
                    deadline = time.monotonic() + 18
                elif line.startswith(('BUTTON RETURNED ', 'BUTTON EXCEPTION ')):
                    last = None
                    deadline = time.monotonic() + 55
                elif line.startswith('BUTTON CHANGED '):
                    changed = True
                elif m := re.search(r'its own \(pid (\d+)\)', line):
                    pid = int(m[1])
            while proc.poll() is None and time.monotonic() < deadline:
                for line in read:
                    process(line)
                time.sleep(.25)
            for line in read:
                process(line)
            if proc.poll() is None:
                total.write(f'AUDIT TIMEOUT {last} on pass {attempt}\n')
                if pid:
                    subprocess.run(['/usr/bin/sample', str(pid),'1','-f',f'stack-{attempt}.log'],
                                   timeout=8, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
            elif not changed and last is None:
                break
            if len(attempted) == prior:
                break
    print(f'Tested {len(attempted)} button occurrences')

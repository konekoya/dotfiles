#!/bin/bash
# Description: Check credential transport, caller state, and interrupted HTTP requests

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/http-regression.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
cp "$REPO_ROOT/lib/http.sh" "$TEST_ROOT/http.sh"

python3 - "$TEST_ROOT" <<'PY'
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
bin_dir = root / 'bin'
bin_dir.mkdir()
mock = bin_dir / 'curl'
mock.write_text('#!' + sys.executable + '\n' + r'''
import json
import os
import signal
import stat
import sys
from pathlib import Path

args = sys.argv[1:]
expected = {
    'basic': 'Authorization: Basic c3ludGhldGljOnBhdA==',
    'bearer': 'Authorization: Bearer synthetic-http-token',
    'none': '',
}[os.environ['HTTP_TEST_HEADER_KIND']]
header = ''
is_pipe = False
for index, arg in enumerate(args):
    if arg in ('-H', '--header') and args[index + 1].startswith('@'):
        with open(args[index + 1][1:]) as stream:
            is_pipe = stat.S_ISFIFO(os.fstat(stream.fileno()).st_mode)
            header = stream.read().rstrip('\n')
stdin_body = sys.stdin.read()
event = {
    'pipe': is_pipe,
    'header_ok': header == expected,
    'args_safe': not any(value in arg for arg in args for value in (
        'Authorization:', 'synthetic-http-token', 'c3ludGhldGljOnBhdA==')),
    'body_ok': stdin_body == os.environ['HTTP_TEST_EXPECT_BODY'],
}
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
event_file = Path(os.environ['HTTP_TEST_EVENT_FILE'])
ready_file = event_file.with_suffix('.ready')
ready_file.write_text(json.dumps(event))
ready_file.replace(event_file)
if os.environ['HTTP_TEST_MODE'] == 'block':
    while True:
        signal.pause()
if os.environ['HTTP_TEST_MODE'] == 'failure':
    sys.exit(28)
print('{"ok":true}\n200')
''')
mock.chmod(0o700)

runner = root / 'request.sh'
runner.write_text(r'''#!/bin/bash
set -euo pipefail
source "$1"
trap 'printf "%s\n" INT >> "$HTTP_TEST_TRAP_FILE"; exit 130' INT
trap 'printf "%s\n" TERM >> "$HTTP_TEST_TRAP_FILE"; exit 143' TERM
trap 'printf "%s\n" EXIT >> "$HTTP_TEST_TRAP_FILE"' EXIT
before="$(trap -p INT TERM EXIT)"
exec 3< "$HTTP_TEST_CALLER_INPUT"
case "$HTTP_TEST_HEADER_KIND" in
  basic) header='Authorization: Basic c3ludGhldGljOnBhdA==' ;;
  bearer) header='Authorization: Bearer synthetic-http-token' ;;
esac
case "$HTTP_TEST_HEADER_STYLE" in
  -H|--header) set -- "$HTTP_TEST_HEADER_STYLE" "$header" ;;
  equals) set -- "--header=$header" ;;
  none) set -- ;;
esac
if http_request "$@" -d @- https://example.invalid/test > "$HTTP_TEST_RESPONSE_FILE"; then
  request_status=0
else
  request_status=$?
fi
response="$(< "$HTTP_TEST_RESPONSE_FILE")"
[ "$request_status" -eq "$HTTP_TEST_EXPECT_STATUS" ]
if [ "$request_status" -eq 0 ]; then [ "$response" = '{"ok":true}' ]; fi
after="$(trap -p INT TERM EXIT)"
[ "$before" = "$after" ]
IFS= read -r caller_input <&3
[ "$caller_input" = caller-descriptor ]
printf "%s\n" completed >> "$HTTP_TEST_TRAP_FILE"
''')
(root / 'caller-input').write_text('caller-descriptor\n')

cases = [
    ('basic', '-H', 'block', signal.SIGINT),
    ('bearer', 'equals', 'block', signal.SIGTERM),
    ('basic', '-H', 'success', None),
    ('bearer', '--header', 'success', None),
    ('bearer', 'equals', 'failure', None),
    ('none', 'none', 'success', None),
]
for index, (kind, style, mode, interrupt) in enumerate(cases):
    label = f'{kind}/{style}/{mode}/{interrupt}'
    case_dir = root / str(index)
    case_dir.mkdir()
    tmp_dir = case_dir / 'tmp'
    tmp_dir.mkdir()
    event_file = case_dir / 'event.json'
    trap_file = case_dir / 'traps'
    body = '' if interrupt else 'synthetic request body\n'
    env = {
        'PATH': str(bin_dir) + os.pathsep + '/usr/bin:/bin:/usr/sbin:/sbin',
        'TMPDIR': str(tmp_dir),
        'HTTP_TEST_HEADER_KIND': kind,
        'HTTP_TEST_HEADER_STYLE': style,
        'HTTP_TEST_MODE': mode,
        'HTTP_TEST_EVENT_FILE': str(event_file),
        'HTTP_TEST_TRAP_FILE': str(trap_file),
        'HTTP_TEST_RESPONSE_FILE': str(case_dir / 'response'),
        'HTTP_TEST_CALLER_INPUT': str(root / 'caller-input'),
        'HTTP_TEST_EXPECT_BODY': body,
        'HTTP_TEST_EXPECT_STATUS': '1' if mode == 'failure' else '0',
    }
    process = subprocess.Popen(
        ['/bin/bash', str(runner), str(root / 'http.sh')],
        stdin=subprocess.DEVNULL if interrupt else subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=env, start_new_session=True,
    )
    try:
        if interrupt:
            deadline = time.monotonic() + 5
            while not event_file.exists():
                assert process.poll() is None, (label, 'request exited before curl blocked')
                assert time.monotonic() < deadline, (label, 'curl did not block')
                time.sleep(0.02)
            wrote_header_file = bool(list(tmp_dir.iterdir()))
            os.killpg(process.pid, interrupt)
            stdout, stderr = process.communicate(timeout=5)
            assert process.returncode == 128 + interrupt, (label, 'caller signal handler did not run')
            assert not list(tmp_dir.iterdir()), (label, 'interrupted request left a credential file')
            assert not wrote_header_file, (label, 'request wrote a credential file')
        else:
            stdout, stderr = process.communicate(input=body, timeout=5)
            assert process.returncode == 0, (label, 'request changed caller state or response')
        event = json.loads(event_file.read_text())
        assert event['header_ok'] and event['args_safe'], (label, 'unsafe or incorrect auth transport')
        assert event['body_ok'], (label, 'auth transport consumed caller stdin')
        assert event['pipe'] == (kind != 'none'), (label, 'auth header was not passed through a pipe')
        assert not list(tmp_dir.iterdir()), (label, 'request left a credential file')
        traps = trap_file.read_text().splitlines()
        assert 'EXIT' in traps, (label, 'caller EXIT trap was replaced')
        if interrupt:
            assert signal.Signals(interrupt).name[3:] in traps, (label, 'caller signal trap was replaced')
            assert 'completed' not in traps, (label, 'interrupted request continued')
        else:
            assert 'completed' in traps, (label, 'caller state was not preserved')
        for value in ('synthetic-http-token', 'c3ludGhldGljOnBhdA=='):
            assert value not in stdout + stderr, (label, 'request printed a credential')
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)
PY

echo "HTTP regression checks passed"

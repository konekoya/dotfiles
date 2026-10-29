#!/bin/bash
# Description: Regression coverage for fzf image browsing, cancellation, and path fallback

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/image-picker-regression.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/home/dotfiles/scripts" "$TEST_ROOT/bin" "$TEST_ROOT/fallback-bin"
cp "$REPO_ROOT/scripts/image-shrink" "$REPO_ROOT/scripts/cmds" "$TEST_ROOT/home/dotfiles/scripts/"
REAL_FZF="$(command -v fzf)" || { echo 'FAIL: fzf is required' >&2; exit 1; }
REAL_MAGICK="$(command -v magick)" || { echo 'FAIL: ImageMagick is required' >&2; exit 1; }
export REAL_FZF HOME="$TEST_ROOT/home"
export PICKER_TEST_INPUT="$TEST_ROOT/candidates"
ln -s "$REAL_MAGICK" "$TEST_ROOT/fallback-bin/magick"
magick -size 160x120 gradient: jpeg:- > "$TEST_ROOT/source.jpg"
cat > "$TEST_ROOT/bin/fzf" <<'EOF'
#!/bin/bash
if [ "${1:-}" != --read0 ]; then
  awk '$1 == "image-shrink" { print $1; found = 1 } END { exit !found }'
  exit
fi
cat > "$PICKER_TEST_INPUT"
case "${PICKER_TEST_MODE:-real}" in
  real) exec "$REAL_FZF" "$@" < "$PICKER_TEST_INPUT" ;;
  fixed) printf '%s\n' "$PICKER_TEST_SELECTION" ;;
  failure) exit 2 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/fzf"
export PATH="$TEST_ROOT/bin:$PATH"

python3 - "$TEST_ROOT" <<'PY'
import errno
import fcntl
import os
import pathlib
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import termios
import time

root = pathlib.Path(sys.argv[1])
images = root / 'images'
images.mkdir()
names = ['aaasgadsgsdag.jpg', 'arrow-one.jpg', 'arrow-two.jpg', 'tab-one.jpg',
         'tab-two.jpg', 'nested folder/inside.jpg', 'parent.jpg', 'manual.jpg',
         '.hidden.JPG', "odd 'quotes' \\ $(touch SENTINEL)\nphoto.jpg", 'fallback.jpg']
for name in names:
    path = images / name
    path.parent.mkdir(exist_ok=True)
    shutil.copyfile(root / 'source.jpg', path)
(images / 'not-an-image.txt').write_text('synthetic fixture')
(images / 'empty').mkdir()
(root / 'fzf-options').write_text('--filter=never-match\n')
scripts = root / 'home/dotfiles/scripts'
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')

def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

def run_picker(steps, filename=None, *, cwd=images, script='image-shrink', mode='real',
               status=0, fallback=False):
    environment = dict(os.environ, INPUTRC='/dev/null', TERM='xterm', PICKER_TEST_MODE=mode,
                       FZF_DEFAULT_OPTS='--filter=never-match',
                       FZF_DEFAULT_OPTS_FILE=str(root / 'fzf-options'))
    if fallback:
        environment['PATH'] = str(root / 'fallback-bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'
    if mode == 'fixed':
        environment['PICKER_TEST_SELECTION'] = str(filename.relative_to(cwd))
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 110, 0, 0))
    process = subprocess.Popen(['/bin/bash', str(scripts / script)], cwd=cwd,
                               env=environment, stdin=slave, stdout=slave, stderr=slave,
                               preexec_fn=controlling_terminal)
    os.close(slave)
    steps = list(steps)
    if filename is not None:
        steps += [(b'Maximum size', b'\n'), (b'Maximum longest edge', b'80\n'),
                  (b'Output format', b'png\n')]
    transcript = b''
    since = 0
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                if b'\x1b[6n' in data:
                    os.write(master, b'\x1b[1;1R')
                transcript += data
                if steps and steps[0][0] in ansi.sub(b'', transcript[since:]):
                    _, keys = steps.pop(0)
                    os.write(master, keys)
                    since = len(transcript)
            elif process.poll() is not None:
                break
        assert time.monotonic() < deadline, 'picker interaction timed out'
        process.wait(timeout=5)
        assert process.returncode == status, f'unexpected picker exit status {process.returncode}'
        assert not steps, 'picker did not complete the expected interaction'
        if filename is not None:
            assert filename.with_suffix('.small.png').is_file(), 'wrong image selected'
        else:
            assert b'Maximum size' not in transcript, 'cancelled/failed picker continued'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)

# Wait for the search to settle before Enter so tests exercise live filtering.
run_picker([(b'Select an image', b'aaasgadsgsdag'), (b'1/', b'\r')],
           images / 'aaasgadsgsdag.jpg')
entries = (root / 'candidates').read_bytes().split(b'\0')
assert b'not-an-image.txt' not in entries, 'unsupported file listed'
assert b'.hidden.JPG' in entries and b'nested folder/' in entries, 'image/directory missing'
assert b'[Enter a path]' in entries and b'../' in entries, 'navigation choices missing'
run_picker([(b'Select an image', b'arrow-'), (b'2/', b'\x1b[B\r')], images / 'arrow-two.jpg')
run_picker([(b'Select an image', b'tab-'), (b'2/', b'\t\x1b[Z\t\r')], images / 'tab-two.jpg')
run_picker([(b'Select an image', b'nested folder/'), (b'1/', b'\r'),
            (b'Select an image', b'inside'), (b'1/', b'\r')],
           images / 'nested folder/inside.jpg', script='cmds')
run_picker([(b'Select an image', b'../'), (b'1/', b'\r'),
            (b'Select an image', b'parent.jpg'), (b'1/', b'\r')],
           images / 'parent.jpg', cwd=images / 'empty')
run_picker([(b'Select an image', b'Enter a path'), (b'1/', b'\r'),
            (b'Image path', str(images / 'manual.jpg').encode() + b'\n')], images / 'manual.jpg')
run_picker([(b'Select an image', b'hidden'), (b'1/', b'\r')], images / '.hidden.JPG')
run_picker([(b'Select an image', b'\x1b')], status=130)
run_picker([], mode='failure', status=1)
odd = images / names[9]
run_picker([], odd, mode='fixed')
assert odd.name.encode() in (root / 'candidates').read_bytes().split(b'\0'), 'filename split at newline'
assert not (images / 'SENTINEL').exists(), 'filename was executed as shell syntax'
run_picker([(b'Image path', str(images / 'fallback.jpg').encode() + b'\n')],
           images / 'fallback.jpg', fallback=True)
assert not list(images.rglob('.image-shrink.*')), 'temporary working directory leaked'
PY
echo 'Image picker regression checks passed'

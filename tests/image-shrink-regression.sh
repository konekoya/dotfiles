#!/bin/bash
# Description: Regression coverage for image limits, codecs, orientation, and safe publication

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/image-shrink-regression.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/home/dotfiles/scripts" "$TEST_ROOT/images" "$TEST_ROOT/bin"
cp "$REPO_ROOT/scripts/image-shrink" "$REPO_ROOT/scripts/cmds" "$TEST_ROOT/home/dotfiles/scripts/"
SHRINK="$TEST_ROOT/home/dotfiles/scripts/image-shrink"
export HOME="$TEST_ROOT/home"
REAL_MAGICK="$(command -v magick)" || { echo 'FAIL: ImageMagick is required' >&2; exit 1; }
export REAL_MAGICK

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run_shrink() {
  status=0
  /bin/bash "$SHRINK" "$@" </dev/null > "$TEST_ROOT/output" 2>&1 || status=$?
}
assert_success() { [ "$status" -eq 0 ] || fail "expected success: $*"; }
assert_failure() { [ "$status" -ne 0 ] || fail "expected failure: $*"; }
assert_limit() {
  local bytes
  bytes="$(wc -c < "$1" | tr -d '[:space:]')"
  [ "$bytes" -gt 0 ] && [ "$bytes" -le "$2" ] || fail 'output exceeded the byte limit or was empty'
  "$REAL_MAGICK" identify - < "$1" >/dev/null 2>&1 || fail 'output was not decodable'
}
assert_clean() {
  local path
  for path in "$TEST_ROOT/images"/.image-shrink.*; do
    [ ! -e "$path" ] || fail 'working directory leaked'
  done
}

run_shrink --help
assert_success help
run_shrink
[ "$status" -eq 2 ] || fail 'noninteractive missing input did not return usage error'

photo="$TEST_ROOT/images/photo [0] %03d.jpg"
"$REAL_MAGICK" -seed 42 -size 1000x750 xc: -channel RGB +noise Random -depth 8 -quality 98 jpeg:- > "$photo"
cp "$photo" "$TEST_ROOT/original.jpg"

for size in 0KB -1MB 0.1B 1XB NaNKB 1000001MB 500 '1 MB'; do
  run_shrink "$photo" --max-size "$size"
  [ "$status" -eq 2 ] || fail "invalid size accepted: $size"
done
for side in 0 -1 1.5 100001 9999999999999999999; do
  run_shrink "$photo" --max-side "$side"
  [ "$status" -eq 2 ] || fail "invalid side accepted: $side"
done
run_shrink "$photo" --max-side 160 --keep-dimensions
[ "$status" -eq 2 ] || fail 'conflicting dimension flags accepted'
run_shrink "$photo" --format png -o "$TEST_ROOT/images/conflict.jpg"
[ "$status" -eq 2 ] || fail 'conflicting output format accepted'
run_shrink "$photo" --format gif
[ "$status" -eq 2 ] || fail 'unsupported format accepted'
run_shrink "$photo" --unknown
[ "$status" -eq 2 ] || fail 'unknown option accepted'
run_shrink "$photo" --max-size
[ "$status" -eq 2 ] || fail 'missing flag value accepted'

run_shrink "$photo" --max-size 0.12MB
assert_success 'JPEG target with resizing'
small="$TEST_ROOT/images/photo [0] %03d.small.jpg"
assert_limit "$small" 120000
"$REAL_MAGICK" identify -format '%w %h' "jpeg:-" < "$small" > "$TEST_ROOT/dimensions"
read -r width height < "$TEST_ROOT/dimensions" || true
[ "$width" -lt 1000 ] && [ "$width" -ge 320 ] || fail 'JPEG did not resize within its bounds'
[ "$((width * 750 - height * 1000))" -le 1000 ] &&
  [ "$((height * 1000 - width * 750))" -le 1000 ] || fail 'aspect ratio changed'
cmp -s "$photo" "$TEST_ROOT/original.jpg" || fail 'original changed'
assert_clean

cp "$small" "$TEST_ROOT/saved-output.jpg"
run_shrink "$photo"
assert_failure 'existing default output'
cmp -s "$small" "$TEST_ROOT/saved-output.jpg" || fail 'existing output changed'
run_shrink "$photo" -o "$photo"
assert_failure 'output is input'
cmp -s "$photo" "$TEST_ROOT/original.jpg" || fail 'input was overwritten'
ln -s "$TEST_ROOT/images/missing" "$TEST_ROOT/images/broken.jpg"
run_shrink "$photo" -o "$TEST_ROOT/images/broken.jpg"
assert_failure 'dangling output symlink'
[ -L "$TEST_ROOT/images/broken.jpg" ] || fail 'symlink replaced'
mkdir "$TEST_ROOT/images/directory.jpg"
run_shrink "$photo" -o "$TEST_ROOT/images/directory.jpg"
assert_failure 'output directory'

run_shrink "$photo" --max-size 900KB --keep-dimensions -o "$TEST_ROOT/images/quality.jpg"
assert_success 'quality search without resizing'
assert_limit "$TEST_ROOT/images/quality.jpg" 900000
[ "$("$REAL_MAGICK" identify -format '%wx%h' "$TEST_ROOT/images/quality.jpg")" = 1000x750 ] || fail 'keep-dimensions resized'

run_shrink "$photo" --max-size 1B --keep-dimensions -o "$TEST_ROOT/images/impossible.jpg"
assert_failure 'impossible quality-only limit'
[ ! -e "$TEST_ROOT/images/impossible.jpg" ] || fail 'failed target published output'
run_shrink "$photo" --max-size 1B -o "$TEST_ROOT/images/floor.jpg"
assert_failure 'automatic dimension floor'
[ ! -e "$TEST_ROOT/images/floor.jpg" ] || fail 'dimension floor published output'
assert_clean

transparent="$TEST_ROOT/images/transparent.png"
"$REAL_MAGICK" "jpeg:-" -alpha set -channel A -evaluate set 65% +channel "$transparent" < "$photo"
run_shrink "$transparent" --max-side 000128 --max-size 100KB
assert_success 'transparent PNG resize'
assert_limit "$TEST_ROOT/images/transparent.small.png" 100000
[ "$("$REAL_MAGICK" identify -format '%wx%h %[opaque]' "$TEST_ROOT/images/transparent.small.png")" = '128x96 False' ] || fail 'PNG dimensions or transparency changed'
run_shrink "$transparent" --format jpg
assert_failure 'transparent JPEG conversion'
[ ! -e "$TEST_ROOT/images/transparent.small.jpg" ] || fail 'transparent image flattened'
run_shrink "$transparent" --max-side 128 --format webp
assert_success 'transparent WebP conversion'
assert_limit "$TEST_ROOT/images/transparent.small.webp" 500000
[ "$("$REAL_MAGICK" identify -format '%[opaque]' "$TEST_ROOT/images/transparent.small.webp")" = False ] || fail 'WebP transparency lost'
run_shrink "$TEST_ROOT/images/transparent.small.webp" --max-side 64
assert_success 'WebP input'
assert_limit "$TEST_ROOT/images/transparent.small.small.webp" 500000

run_shrink "$small" --max-size 512KiB
assert_success 'under-limit skip'
grep -Fq 'Skipped: already under the limit' "$TEST_ROOT/output" || fail 'under-limit file not skipped'
[ ! -e "$TEST_ROOT/images/photo [0] %03d.small.small.jpg" ] || fail 'skip wrote an output'
run_shrink "$photo" --max-size 1.5MiB --max-side 2000 -o "$TEST_ROOT/images/binary.jpg"
assert_success 'binary size and no enlargement'
assert_limit "$TEST_ROOT/images/binary.jpg" 1572864
[ "$("$REAL_MAGICK" identify -format '%wx%h' "$TEST_ROOT/images/binary.jpg")" = 1000x750 ] || fail 'image enlarged'
run_shrink "$photo" --max-side 64 -o "$TEST_ROOT/images/inferred.webp"
assert_success 'output extension inference'
[ "$("$REAL_MAGICK" identify -format '%m' "$TEST_ROOT/images/inferred.webp")" = WEBP ] || fail 'output extension did not select codec'

# Synthetic EXIF orientation 6 (rotate 90 degrees clockwise), no personal metadata.
python3 - "$TEST_ROOT/original.jpg" "$TEST_ROOT/images/oriented.jpg" <<'PY'
import pathlib
import struct
import sys
exif = b'Exif\0\0II' + struct.pack('<HIH', 42, 8, 1)
exif += struct.pack('<HHIHHI', 0x112, 3, 1, 6, 0, 0)
original = pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[2]).write_bytes(original[:2] + b'\xff\xe1' + struct.pack('>H', len(exif) + 2) + exif + original[2:])
PY
run_shrink "$TEST_ROOT/images/oriented.jpg" --max-side 200
assert_success 'EXIF orientation'
[ "$("$REAL_MAGICK" identify -format '%wx%h' "$TEST_ROOT/images/oriented.small.jpg")" = 150x200 ] || fail 'orientation not applied'

# Real HEIC input/output, including uppercase .HEIF and primary-image selection.
phone="$TEST_ROOT/images/IMG_1234.HEIF"
"$REAL_MAGICK" -size 160x120 gradient: -quality 90 "heic:$phone" 2>/dev/null || fail 'HEIC encoder unavailable'
run_shrink "$phone" --max-size 40KB --max-side 80
assert_success 'HEIF input and HEIC output'
assert_limit "$TEST_ROOT/images/IMG_1234.small.heic" 40000
[ "$("$REAL_MAGICK" identify -format '%wx%h' "$TEST_ROOT/images/IMG_1234.small.heic")" = 80x60 ] || fail 'HEIC resize incorrect'
run_shrink "$phone" --format jpg
assert_success 'HEIC to JPEG'
assert_limit "$TEST_ROOT/images/IMG_1234.small.jpg" 500000
run_shrink "$phone" --format webp
assert_success 'HEIC to WebP'
assert_limit "$TEST_ROOT/images/IMG_1234.small.webp" 500000
"$REAL_MAGICK" -size 80x60 xc:red -size 80x60 xc:blue "$TEST_ROOT/images/animated.webp"
run_shrink "$TEST_ROOT/images/animated.webp" --max-side 40
assert_success 'primary still image'
[ "$("$REAL_MAGICK" identify -format '%n' "$TEST_ROOT/images/animated.small.webp")" = 1 ] || fail 'multiple frames were written'

printf 'not an image\n' > "$TEST_ROOT/images/corrupt.jpg"
run_shrink "$TEST_ROOT/images/corrupt.jpg"
assert_failure 'corrupt input'
[ ! -e "$TEST_ROOT/images/corrupt.small.jpg" ] || fail 'corrupt input published output'
assert_clean

# Delegate valid operations to the real backend; simulate codec/encoder failures
# and a concurrent destination directory without ever touching real user images.
cat > "$TEST_ROOT/bin/magick" <<'EOF'
#!/bin/bash
case "${IMAGE_TEST_MODE:-}" in
  no-heic)
    if [ "$1" = -list ]; then
      "$REAL_MAGICK" "$@" | awk '$1 !~ /^HEI[CF]/'
      exit
    fi ;;
  encode-failure)
    case "${*: -1}" in *:*/candidate) exit 1 ;; esac ;;
  interrupt)
    case "${*: -1}" in *:*/candidate) kill -TERM "$PPID"; exit 1 ;; esac ;;
  publish-race)
    if [ "$1" = identify ] && [[ "${*: -1}" == *:*/best ]]; then
      mkdir -p "$IMAGE_TEST_DESTINATION"
    fi ;;
esac
exec "$REAL_MAGICK" "$@"
EOF
chmod +x "$TEST_ROOT/bin/magick"
export PATH="$TEST_ROOT/bin:$PATH"
export IMAGE_TEST_MODE=no-heic
run_shrink "$phone" --format png
assert_failure 'missing HEIC decoder'
grep -Fq 'Input codec unavailable' "$TEST_ROOT/output" || fail 'missing codec not explained'
IMAGE_TEST_MODE=encode-failure
run_shrink "$photo" --max-side 100 -o "$TEST_ROOT/images/encode-failure.jpg"
assert_failure 'encoder failure'
[ ! -e "$TEST_ROOT/images/encode-failure.jpg" ] || fail 'encoder failure published output'
IMAGE_TEST_MODE=interrupt
run_shrink "$photo" --max-side 100 -o "$TEST_ROOT/images/interrupted.jpg"
[ "$status" -eq 143 ] || fail 'TERM did not return interrupted status'
[ ! -e "$TEST_ROOT/images/interrupted.jpg" ] || fail 'interruption published output'
assert_clean
IMAGE_TEST_MODE=publish-race
export IMAGE_TEST_DESTINATION="$TEST_ROOT/images/race.jpg"
run_shrink "$photo" --max-side 100 -o "$IMAGE_TEST_DESTINATION"
assert_failure 'concurrent output directory'
[ -d "$IMAGE_TEST_DESTINATION" ] || fail 'concurrent directory replaced'
[ -z "$(ls -A "$IMAGE_TEST_DESTINATION")" ] || fail 'output written inside concurrent directory'
unset IMAGE_TEST_MODE
assert_clean

# Exercise cmds and Readline in pseudo-terminals. Completion must remove its
# appended space/escapes without evaluating metacharacters in filenames.
cat > "$TEST_ROOT/bin/fzf" <<'EOF'
#!/bin/bash
if [ "${1:-}" = --read0 ]; then
  cat >/dev/null
  printf '[Enter a path]\n'
  exit 0
fi
awk '$1 == "image-shrink" { print $1; found = 1 } END { exit !found }'
EOF
chmod +x "$TEST_ROOT/bin/fzf"
python3 - "$TEST_ROOT/home/dotfiles/scripts/cmds" "$SHRINK" "$TEST_ROOT/images" <<'PY'
import errno
import os
import pathlib
import pty
import select
import shutil
import subprocess
import sys
import time
images = pathlib.Path(sys.argv[3])
completion_dir = images / 'completion'
completion_dir.mkdir()
names = ['aaasgadsgsdag.jpg', "spaces and 'quotes'.jpg", r'back\slash.jpg',
         'literal$(touch SENTINEL).jpg', 'multiple-one.jpg', 'multiple-two.jpg',
         'absolute-photo.jpg', 'nested folder/deep photo.jpg']
for name in names:
    destination = completion_dir / name
    destination.parent.mkdir(exist_ok=True)
    shutil.copyfile(images / 'quality.jpg', destination)

def run_interactive(script, filename, keys=None, list_first=False):
    steps = [(b'Image path', keys)]
    if list_first:
        steps = [(b'Image path', b'\t'),
                 (b'aaasgadsgsdag.jpg', b'multiple\t'),
                 (b'multiple-two.jpg', b'two.jpg\n')]
    steps += [(b'Maximum size', b'\n'),
              (b'Maximum longest edge', b'80\n'),
              (b'Output format', b'png\n')]
    master, slave = pty.openpty()
    environment = dict(os.environ, INPUTRC='/dev/null', TERM='xterm')
    process = subprocess.Popen(['/bin/bash', script], cwd=completion_dir,
                               stdin=slave, stdout=slave, stderr=slave, env=environment)
    os.close(slave)
    transcript = b''
    search_start = 0
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                transcript += data
                if steps and steps[0][0] in transcript[search_start:]:
                    _, keys_to_send = steps.pop(0)
                    os.write(master, keys_to_send)
                    search_start = len(transcript)
            elif process.poll() is not None:
                break
        assert process.poll() is not None or time.monotonic() < deadline, 'interactive prompt timed out'
        process.wait(timeout=5)
        assert process.returncode == 0, 'interactive command failed'
        assert not steps, 'interactive prompts were incomplete'
        assert filename.with_suffix('.small.png').is_file(), 'selected image was not processed'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)

# Both direct invocation and cmds inherit the directory in which they started.
run_interactive(sys.argv[1], images / 'IMG_1234.HEIF',
                keys=str(images / 'IMG_1234.HEIF').encode() + b'\n')
for name, keys in [('aaasgadsgsdag.jpg', b'aaa\t\n'),
                   ("spaces and 'quotes'.jpg", b'spa\t\n'),
                   (r'back\slash.jpg', b'back\t\n'),
                   ('literal$(touch SENTINEL).jpg', b'lit\t\n'),
                   ('nested folder/deep photo.jpg', b'nest\tdee\t\n')]:
    run_interactive(sys.argv[2], completion_dir / name, keys=keys)
run_interactive(sys.argv[2], completion_dir / 'absolute-photo.jpg',
                keys=str(completion_dir / 'absolute-').encode() + b'\t\n')
run_interactive(sys.argv[1], completion_dir / 'multiple-two.jpg', list_first=True)
assert not (completion_dir / 'SENTINEL').exists(), 'filename shell syntax was evaluated'
PY
assert_limit "$TEST_ROOT/images/IMG_1234.small.png" 500000
assert_clean
cmp -s "$photo" "$TEST_ROOT/original.jpg" || fail 'original changed during tests'
echo 'Image shrink regression checks passed'

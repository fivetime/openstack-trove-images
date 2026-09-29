#!/usr/bin/env bash
# Run Trove's unit tests, the backup container's unit tests and flake8
# against a checkout of fivetime/openstack-trove, in the same Python and
# constraints the service image is built with.
#
# Usage: tools/run-unit-tests.sh <trove-checkout> [flake8-path ...]
#
# The checkout is copied first, so the run leaves nothing behind in it
# (egg-info, .stestr, trove_test.sqlite). Uncommitted changes are included.
#
# The suites run serially: the tests share one sqlite file, and parallel
# workers fail at random with "database is locked".

set -Eeuo pipefail

src=$(readlink -f "${1:?trove checkout}"); shift
image=${VENV_BUILDER:-quay.io/airshipit/venv_builder:2026.1-ubuntu_noble}
work=$(mktemp -d "${TMPDIR:-/tmp}/trove-ut.XXXXXX")
trap 'rm -rf "$work"' EXIT

# git archive would drop uncommitted work; rsync would drag in build output.
git -C "$src" ls-files -z --cached --others --exclude-standard \
    | tar -C "$src" --null -T - -cf - 2>/dev/null | tar -C "$work" -xf -
# pbr needs the history to name the version.
cp -a "$src/.git" "$work/.git"

cat > "$work/.run.sh" <<'EOF'
#!/bin/bash
set -e
cd /src
git config --global --add safe.directory '*'
uv venv -q /tmp/venv --python 3.12 && . /tmp/venv/bin/activate
uv pip install -q -c /upper-constraints.txt \
    -r requirements.txt -r test-requirements.txt -r backup/requirements.txt
uv pip install -q -c /upper-constraints.txt -e .
rc=0
summary() { grep -E "^ - (Passed|Skipped|Failed)" "$1"; }

echo "== trove unit tests"
rm -rf trove_test.sqlite .stestr
OS_TEST_PATH=./trove/tests/unittests OS_STDOUT_CAPTURE=1 OS_STDERR_CAPTURE=1 \
    stestr run --serial > /tmp/trove.out 2>&1 || rc=1
summary /tmp/trove.out; stestr failing --list 2>/dev/null || true

echo "== backup unit tests"
rm -rf .stestr
OS_TEST_PATH=./backup/tests/unittests stestr run --serial > /tmp/backup.out 2>&1 || rc=1
summary /tmp/backup.out; stestr failing --list 2>/dev/null || true

if [ $# -gt 0 ]; then
    echo "== flake8 $*"
    flake8 "$@" && echo "flake8 clean" || rc=1
fi
exit $rc
EOF
chmod +x "$work/.run.sh"

docker run --rm -v "$work:/src" --entrypoint /src/.run.sh "$image" "$@"

#!/bin/bash
# Description: Regression coverage for morning repository sync and Orca worktree review
# shellcheck disable=SC2088 # "~/..." in messages is literal text, not a path to expand

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_ENV="$(command -v env)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/morning-regression.XXXXXX")" || exit 1
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || exit 1
TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN" || exit 1

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for tool in git jq awk sed grep tr cat mkdir rm dirname basename head wc sort ssh; do
  tool_path="$(command -v "$tool")" || fail "required test utility '$tool' is unavailable"
  ln -s "$tool_path" "$TEST_BIN/$tool" || fail "could not add '$tool' to test PATH"
done

# Orca is mocked: it prints whatever the case stored in ORCA_WORKTREES_JSON / ORCA_TERMINALS_JSON.
mkdir -p "$TEST_ROOT/orca-bin" || exit 1
cat > "$TEST_ROOT/orca-bin/orca" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "worktree list") cat "$ORCA_WORKTREES_JSON" ;;
  "terminal list") cat "$ORCA_TERMINALS_JSON" ;;
  *) echo "unexpected orca call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/orca-bin/orca" || fail "could not create orca mock"

setup_fixture() {
  local name="$1"
  TEST_CASE_DIR="$TEST_ROOT/$name"
  TEST_HOME="$TEST_CASE_DIR/home"
  TEST_DOTFILES="$TEST_HOME/dotfiles"
  mkdir -p "$TEST_DOTFILES/scripts" "$TEST_DOTFILES/lib" "$TEST_DOTFILES/alias" "$TEST_HOME/code" || fail "could not create fixture for $name"
  # morning locates lib/ and sync-branch from its own path, so run copies inside the fixture.
  cp "$REPO_ROOT/scripts/morning" "$REPO_ROOT/scripts/sync-branch" "$TEST_DOTFILES/scripts/" || fail "could not copy scripts for $name"
  cp "$REPO_ROOT"/lib/*.sh "$TEST_DOTFILES/lib/" || fail "could not copy helpers for $name"
  : > "$TEST_DOTFILES/alias/.env"
  MORNING="$TEST_DOTFILES/scripts/morning"
  printf '[user]\n\tname = Regression Test\n\temail = regression@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$TEST_HOME/.gitconfig"
}

run_morning() {
  "$REAL_ENV" -i HOME="$TEST_HOME" PATH="$TEST_BIN" /bin/bash "$MORNING" "$@"
}

run_morning_with_orca() {
  "$REAL_ENV" -i HOME="$TEST_HOME" PATH="$TEST_ROOT/orca-bin:$TEST_BIN" \
    ORCA_WORKTREES_JSON="$TEST_CASE_DIR/worktrees.json" ORCA_TERMINALS_JSON="$TEST_CASE_DIR/terminals.json" \
    /bin/bash "$MORNING"
}

tgit() {
  HOME="$TEST_HOME" git "$@"
}

# make_origin NAME: a bare origin with one commit on main, plus a publisher clone for later pushes.
make_origin() {
  local name="$1"
  ORIGIN="$TEST_CASE_DIR/$name.git"
  PUBLISHER="$TEST_CASE_DIR/$name-publisher"
  tgit init -q --bare -b main "$ORIGIN" || fail "could not create origin $name"
  tgit clone -q "$ORIGIN" "$PUBLISHER" 2>/dev/null || fail "could not clone origin $name"
  printf 'base\n' > "$PUBLISHER/base.txt"
  tgit -C "$PUBLISHER" add base.txt && tgit -C "$PUBLISHER" commit -qm base && tgit -C "$PUBLISHER" push -q origin main ||
    fail "could not publish base for $name"
}

publish_commit() {
  local file="$1"
  printf '%s\n' "$file" > "$PUBLISHER/$file"
  tgit -C "$PUBLISHER" add "$file" && tgit -C "$PUBLISHER" commit -qm "add $file" && tgit -C "$PUBLISHER" push -q origin main ||
    fail "could not publish $file"
}

# --- Unconfigured: a warning, not a failure ---
setup_fixture unconfigured
run_morning > "$TEST_CASE_DIR/output" 2>&1 || fail "morning failed without configuration"
grep -Fq 'No repositories configured; set MORNING_REPOS in alias/.env' "$TEST_CASE_DIR/output" || fail "missing MORNING_REPOS was not reported"
grep -Fq 'orca not found; skipped' "$TEST_CASE_DIR/output" || fail "missing orca was not reported as skipped"
grep -Fq 'Done with 1 warning(s).' "$TEST_CASE_DIR/output" || fail "warning summary was not printed"

# --- Repositories: fast-forward only a clean default branch ---
setup_fixture repositories
make_origin shared
for clone in clean dirty feature; do
  tgit clone -q "$ORIGIN" "$TEST_HOME/code/$clone" 2>/dev/null || fail "could not clone $clone"
done
tgit -C "$TEST_HOME/code/feature" switch -q -c topic || fail "could not create topic branch"
publish_commit second.txt
printf 'local edit\n' >> "$TEST_HOME/code/dirty/base.txt"
mkdir -p "$TEST_HOME/code/plain"
clean_head="$(tgit -C "$TEST_HOME/code/clean" rev-parse HEAD)"

printf 'export MORNING_REPOS="~/code/clean:%s/code/dirty:~/code/feature:~/code/missing:~/code/plain:~/code/clean/"\n' "$TEST_HOME" > "$TEST_DOTFILES/alias/.env"
run_morning --dry-run > "$TEST_CASE_DIR/dry-output" 2>&1 || { cat "$TEST_CASE_DIR/dry-output" >&2; fail "dry run failed"; }
grep -Fq '~/code/clean: would fast-forward main by 1 commit(s)' "$TEST_CASE_DIR/dry-output" || fail "dry run did not report the pending fast-forward"
[ "$(tgit -C "$TEST_HOME/code/clean" rev-parse HEAD)" = "$clean_head" ] || fail "dry run changed a repository"

run_morning > "$TEST_CASE_DIR/output" 2>&1 || fail "morning failed with repositories"
grep -Fq '~/code/clean: fast-forwarded main by 1 commit(s)' "$TEST_CASE_DIR/output" || fail "clean repository was not fast-forwarded"
[ "$(tgit -C "$TEST_HOME/code/clean" rev-parse HEAD)" = "$(tgit -C "$ORIGIN" rev-parse main)" ] || fail "clean repository is not at origin/main"
grep -Fq '~/code/dirty: 1 uncommitted change(s) on main; not updated' "$TEST_CASE_DIR/output" || fail "dirty repository was not reported"
grep -Fq 'local edit' "$TEST_HOME/code/dirty/base.txt" || fail "dirty repository lost its change"
grep -Fq '~/code/feature: on topic, not main; not updated' "$TEST_CASE_DIR/output" || fail "feature branch repository was not reported"
grep -Fq '~/code/missing does not exist; skipped' "$TEST_CASE_DIR/output" || fail "missing repository was not reported"
grep -Fq '~/code/plain is not a Git repository; skipped' "$TEST_CASE_DIR/output" || fail "non-Git directory was not reported"
[ "$(grep -c '^  ~/code/clean:' "$TEST_CASE_DIR/output")" -eq 1 ] || fail "a duplicate MORNING_REPOS entry was synced twice"
grep -Fq '▸ ~/code/clean' "$TEST_CASE_DIR/output" || fail "sync-branch did not run for the clean repository"

# --- Orca worktrees: listed, never removed ---
setup_fixture orca
make_origin project
tgit clone -q "$ORIGIN" "$TEST_HOME/code/project" 2>/dev/null || fail "could not clone project"
PROJECT="$TEST_HOME/code/project"
for wt in merged dirty terminal unmerged active; do
  tgit -C "$PROJECT" worktree add -q -b "$wt" "$TEST_CASE_DIR/wt-$wt" origin/main 2>/dev/null || fail "could not add worktree $wt"
  printf '%s\n' "$wt" > "$TEST_CASE_DIR/wt-$wt/$wt.txt"
  tgit -C "$TEST_CASE_DIR/wt-$wt" add "$wt.txt" && tgit -C "$TEST_CASE_DIR/wt-$wt" commit -qm "$wt change" &&
    tgit -C "$TEST_CASE_DIR/wt-$wt" push -q -u origin "$wt" 2>/dev/null || fail "could not publish worktree $wt"
done
# Squash-merge three branches on origin and delete their remote branches; leave one unmerged but deleted.
tgit -C "$PUBLISHER" fetch -q origin || fail "publisher could not fetch"
for wt in merged dirty terminal; do
  tgit -C "$PUBLISHER" merge -q --squash "origin/$wt" >/dev/null 2>&1 && tgit -C "$PUBLISHER" commit -qm "squash $wt" || fail "could not squash $wt"
done
tgit -C "$PUBLISHER" push -q origin main || fail "could not push squashed main"
for wt in merged dirty terminal unmerged; do
  tgit -C "$PUBLISHER" push -q origin --delete "$wt" 2>/dev/null || fail "could not delete remote $wt"
done
printf 'edit\n' >> "$TEST_CASE_DIR/wt-dirty/dirty.txt"

jq -n --arg main "$PROJECT" --arg base "$TEST_CASE_DIR/wt-" \
  '{ok: true, result: {worktrees: ([{path: $main, isMainWorktree: true}] + ([ "merged", "dirty", "terminal", "unmerged", "active" ] | map({path: ($base + .), isMainWorktree: false})) + [{path: ($base + "gone-from-disk"), isMainWorktree: false}])}}' \
  > "$TEST_CASE_DIR/worktrees.json"
jq -n --arg path "$TEST_CASE_DIR/wt-terminal" '{ok: true, result: {terminals: [{worktreePath: $path, handle: "term_1"}]}}' > "$TEST_CASE_DIR/terminals.json"
printf 'export MORNING_REPOS="~/code/project"\n' > "$TEST_DOTFILES/alias/.env"

run_morning_with_orca > "$TEST_CASE_DIR/output" 2>&1 || fail "morning failed with Orca worktrees"
grep -Fq "✅ $TEST_CASE_DIR/wt-merged (merged): merged into main, clean, no terminals — orca worktree rm --worktree path:$TEST_CASE_DIR/wt-merged" "$TEST_CASE_DIR/output" ||
  fail "merged clean worktree was not offered for removal"
grep -Fq "wt-dirty (dirty): merged into main but has 1 uncommitted change(s); check before removing" "$TEST_CASE_DIR/output" || fail "dirty merged worktree was not flagged"
grep -Fq "wt-terminal (terminal): merged into main but has 1 open terminal(s); check before removing" "$TEST_CASE_DIR/output" || fail "worktree with a terminal was not flagged"
grep -Fq "wt-unmerged (unmerged): upstream gone but its changes are not on main; check it" "$TEST_CASE_DIR/output" || fail "unmerged worktree was not flagged"
grep -Fq "wt-gone-from-disk is listed by Orca but missing on disk" "$TEST_CASE_DIR/output" || fail "missing worktree directory was not reported"
grep -Fq "1 active, 1 ready to remove (morning never removes worktrees)" "$TEST_CASE_DIR/output" || fail "worktree summary was wrong"
for wt in merged dirty terminal unmerged active; do
  [ -d "$TEST_CASE_DIR/wt-$wt" ] || fail "worktree $wt was removed"
  tgit -C "$PROJECT" rev-parse --verify --quiet "refs/heads/$wt" >/dev/null || fail "branch $wt held by a worktree was deleted"
done

echo "morning regression checks passed"

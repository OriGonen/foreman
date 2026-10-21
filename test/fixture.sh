# Fixture repositories for test/smoke.sh and test/bench.sh — sourced, not run. One file, so
# the two scripts cannot drift apart: the benchmark's numbers compare with the suite's only
# while both build the same repository.
#
# A fixture is a copy of a template. The template is a configured repository — git identity,
# line endings, foreman.conf, .gitignore, .gitattributes — with no tickets and no commit: the
# ticket count differs from case to case, and the initial commit holds the tickets, so a
# committed template would need `git rm` and `commit --amend` per case and give every fixture
# the same root commit. Each fixture gets its tickets and its one commit after the copy.
#
# The caller sets FOREMAN_HOME (the repository root) before calling either function.

# Builds the template at $1, which must not exist yet. Call it once per run, in the main
# shell, and give the same path to every copy_fixture.
build_fixture_template() {
  local template="$1"
  mkdir -p "$template/batch/issues"
  git -C "$template" init --quiet
  git -C "$template" config core.autocrlf false
  git -C "$template" config user.name foreman-test
  git -C "$template" config user.email test@foreman.invalid

  cp "$FOREMAN_HOME/lib/foreman.conf.template" "$template/batch/foreman.conf"
  printf 'FOREMAN_EXEC=fake\n' >> "$template/batch/foreman.conf"
  printf '%s\n' '**/foreman-runs.jsonl' '**/foreman-runs.log' '**/.foreman-iter.bundle' \
    '**/.foreman-stall-marker' > "$template/.gitignore"
  printf 'foreman.conf text eol=lf\n' > "$template/.gitattributes"
}

# Copies the template $1 to $2 (which must not exist yet) and makes it a repository with one
# batch of $3 tickets, none of them done, in one initial commit.
copy_fixture() {
  local template="$1" repo="$2" count="$3" i
  cp -R "$template" "$repo"
  for ((i = 1; i <= count; i++)); do
    printf '# Ticket %s\n\n**Status:** todo\n\nDo the %s-th thing.\n' "$i" "$i" \
      > "$repo/batch/issues/0$i-ticket.md"
  done
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit --quiet -m "tickets"
}

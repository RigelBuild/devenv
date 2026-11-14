#!/usr/bin/env bash
# Check version selection, deterministic mint targets, and collisions.
set -u
script="$(cd "$(dirname "$0")" && pwd)/release-tag.sh"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
fails=0
mkdir -p "$dir/bin" "$dir/repo"
cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"--method POST"*)
    printf '%s\n' "$*" >>"$GH_LOG"
    if [ "${GH_MODE:-create}" = collision ]; then
      : >"$GH_MARKER"
      echo 'Reference already exists' >&2
      echo 'HTTP 422' >&2
      exit 1
    fi
    ;;
  *"--method DELETE"*)
    printf '%s\n' "$*" >>"$GH_LOG"
    ;;
  *"git/ref/tags/"*)
    if [ "${GH_MODE:-create}" = existing ]; then exit 0; fi
    if [ "${GH_MODE:-create}" = collision ] && [ -e "$GH_MARKER" ]; then
      printf '%s\n' "$GH_EXISTING_SHA"
      exit 0
    fi
    exit 1
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$dir/bin/gh"
export PATH="$dir/bin:$PATH"
export GH_LOG="$dir/gh.log"
export GH_MARKER="$dir/gh-marker"
cd "$dir/repo" || exit 1
git init -q -b rigel-release
git config user.name test
git config user.email test@example.invalid
write_version() {
  mkdir -p .github
  printf '%s\n' "$1" >.github/rigel-version
  git add .github/rigel-version
  git commit -q -m "$1"
  git rev-parse HEAD
}
old="$(write_version 1.1.0-rigel.1)"
base="$old"
new="$(write_version 1.1.0-rigel.2)"
noop="$(write_version 1.1.0-rigel.2)"
git tag v1.1.0-rigel.1 "$old"

expect_rc() {
  local name="$1" want="$2"; shift 2
  local rc
  "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL ${name}: rc=${rc} (want ${want})"
    fails=$((fails + 1))
  else
    echo "ok   ${name}"
  fi
}
if "$script" check-pr "$base" "$new" >/dev/null 2>&1; then
  echo 'ok   next tracking version passes PR check'
else
  echo 'FAIL next tracking version PR check'
  fails=$((fails + 1))
fi
mkdir -p "$dir/no-version-repo"
cd "$dir/no-version-repo" || exit 1
git init -q -b test
git config user.name test
git config user.email test@example.invalid
printf 'base\n' >README
git add README
git commit -q -m initial
missing_base="$(git rev-parse HEAD)"
added_initial="$(write_version 1.1.0-rigel.1)"
if "$script" check-pr "$missing_base" "$added_initial" >/dev/null 2>&1; then
  echo 'ok   missing version source accepts initial suffix'
else
  echo 'FAIL missing version source accepts initial suffix'
  fails=$((fails + 1))
fi
skipped_initial="$(write_version 1.1.0-rigel.2)"
expect_rc 'missing version source rejects skipped initial suffix' 1 "$script" check-pr "$missing_base" "$skipped_initial"
cd "$dir/repo" || exit 1
skip="$(write_version 1.1.0-rigel.4)"
expect_rc 'skipped suffix fails PR check' 1 "$script" check-pr "$new" "$skip"
git tag v1.1.0-rigel.2 "$new"
git tag v1.1.0-rigel.9 "$new"
git tag v1.1.0-rigel.10 "$new"
git checkout -q -B suffix-sequence "$new"
eleven="$(write_version 1.1.0-rigel.11)"
if "$script" check-pr "$new" "$eleven" >/dev/null 2>&1; then
  echo 'ok   numeric suffix 11 follows tags 1, 2, 9, and 10'
else
  echo 'FAIL numeric suffix 11 follows tags 1, 2, 9, and 10'
  fails=$((fails + 1))
fi
ten="$(write_version 1.1.0-rigel.10)"
expect_rc 'numeric suffix 10 fails after existing suffix 10' 1 "$script" check-pr "$new" "$ten"
git tag -d v1.1.0-rigel.2 v1.1.0-rigel.9 v1.1.0-rigel.10 >/dev/null
git checkout -q -b vendor-refresh "$new"
printf 'vendorHash = "refreshed";\n' >vendor.nix
git add vendor.nix
git commit -q -m vendor-refresh
noop="$(git rev-parse HEAD)"
expect_rc 'unchanged source passes PR check' 0 "$script" check-pr "$new" "$noop"

if GH_MODE=create "$script" mint "$noop" RigelBuild/devenv >/dev/null 2>&1 && grep -q 'refs/tags/v1.1.0-rigel.2' "$GH_LOG"; then
  echo 'ok   mint creates expected version ref'
else
  echo 'FAIL mint creates expected version ref'
  fails=$((fails + 1))
fi
if grep -q "sha=${new}" "$GH_LOG"; then
  echo 'ok   mint targets the commit that set the version'
else
  echo 'FAIL mint targets the commit that set the version'
  fails=$((fails + 1))
fi
git checkout -q -b side-version "$old"
different="$(write_version 1.1.0-rigel.3)"
git checkout -q vendor-refresh
git merge --no-ff --no-commit "$different" >/dev/null 2>&1
printf '%s\n' 1.1.0-rigel.2 >.github/rigel-version
git add .github/rigel-version
git commit -q -m 'merge different version state'
merge="$(git rev-parse HEAD)"
if [ "$(git rev-parse "${merge}^1")" = "$noop" ] && [ "$(git rev-parse "${merge}^2")" = "$different" ] && [ "$(git show "${merge}^2:.github/rigel-version")" = 1.1.0-rigel.3 ] && GH_LOG="$dir/merge-gh.log" GH_MODE=create "$script" mint "$merge" RigelBuild/devenv >/dev/null 2>&1 && grep -Fq "sha=${new}" "$dir/merge-gh.log"; then
  echo 'ok   merge mint targets version-setting commit on first-parent path'
else
  echo 'FAIL merge mint targets version-setting commit on first-parent path'
  fails=$((fails + 1))
fi
before="$(wc -l <"$GH_LOG")"
if GH_MODE=existing "$script" mint "$noop" RigelBuild/devenv >/dev/null 2>&1 && [ "$(wc -l <"$GH_LOG")" -eq "$before" ]; then
  echo 'ok   existing remote release tag is a no-op'
else
  echo 'FAIL existing remote release tag is a no-op'
  fails=$((fails + 1))
fi
if GH_MODE=collision GH_EXISTING_SHA="$new" "$script" mint "$new" RigelBuild/devenv >/dev/null 2>&1; then
  echo 'ok   same-target 422 succeeds'
else
  echo 'FAIL same-target 422 succeeds'
  fails=$((fails + 1))
fi
rm -f "$GH_MARKER"
if GH_MODE=collision GH_EXISTING_SHA="$old" "$script" mint "$new" RigelBuild/devenv >/dev/null 2>&1; then
  echo 'FAIL conflicting 422 fails'
  fails=$((fails + 1))
else
  echo 'ok   conflicting 422 fails'
fi

workflow="$(dirname "$script")/../workflows/release-tag.yaml"
# Dispatch must mint too; only the ref guard and the job-level PR split may carry an `if`.
if [ "$(yq -r '.jobs.mint.steps[] | select(.name == "Mint release tag if needed") | has("if")' "$workflow")" = false ] \
  && [ "$(yq -r '.jobs.mint.if' "$workflow")" = "github.event_name != 'pull_request'" ] \
  && [ "$(yq -r '.on | has("workflow_dispatch")' "$workflow")" = true ] \
  && [ "$(yq -r '.on.push.branches | join(",")' "$workflow")" = rigel-release ]; then
  echo 'ok   push and dispatch both reach the mint step'
else
  echo 'FAIL push and dispatch both reach the mint step'
  fails=$((fails + 1))
fi

# workflows: write lets GitHub create a tag at a commit whose workflow tree matches no branch tip.
permission_keys="$(yq -r '.jobs.mint.steps[] | select(.name == "Create scoped release App token") | .with | keys | map(select(test("^permission-"))) | sort | join(",")' "$workflow")"
contents_permission="$(yq -r '.jobs.mint.steps[] | select(.name == "Create scoped release App token") | .with."permission-contents"' "$workflow")"
workflows_permission="$(yq -r '.jobs.mint.steps[] | select(.name == "Create scoped release App token") | .with."permission-workflows"' "$workflow")"
if [[ "$permission_keys" == permission-contents,permission-workflows && "$contents_permission" == write && "$workflows_permission" == write ]]; then
  echo 'ok   mint token has contents and workflows write only'
else
  echo 'FAIL mint token has contents and workflows write only'
  fails=$((fails + 1))
fi

[ "$fails" -eq 0 ]

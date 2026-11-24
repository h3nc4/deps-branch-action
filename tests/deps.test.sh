#!/bin/sh
# Runs deps.sh against a stub gh that logs every call and prints canned output set by STUB_* variables.

set -eu

cd "$(dirname "$0")/.."
script="${PWD}/deps.sh"

stub="$(mktemp -d)"
trap 'rm -rf "${stub}"' EXIT
cat >"${stub}/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"${STUB_LOG}"
case "$*" in
"api repos/h3nc4/app --jq .default_branch") echo main ;;
"api repos/h3nc4/app/git/ref/heads/deps --silent") [ "${STUB_DEPS:-yes}" = yes ] ;;
"api repos/h3nc4/app/git/ref/heads/main --jq .object.sha") echo abc123 ;;
"api repos/h3nc4/app/merges"*)
  [ "${STUB_CONFLICT:-no}" = no ] || { echo "HTTP 409: Merge conflict" >&2; exit 1; }
  ;;
"api repos/h3nc4/app/compare/main...deps --jq .files | length") echo "${STUB_FILES:-0}" ;;
"pr list"*) echo "${STUB_PR:-}" ;;
"pr create"*) echo "https://github.com/h3nc4/app/pull/42" ;;
"pr view"*mergeStateStatus*) echo "${STUB_STATE:-BLOCKED}" ;;
"pr view"*) echo "${STUB_TITLE:-update dependencies for week 48}" ;;
"pr merge"*--auto*) [ "${STUB_AUTO_FAIL:-no}" = no ] || { echo "auto-merge refused" >&2; exit 1; } ;;
"pr checks"*) echo "${STUB_CHECKS:-true}" ;;
*) ;;
esac
EOF
chmod +x "${stub}/gh"

failed=0

# run <name> <event> <want status> <want log line or -> <unwanted log line or -> [VAR=value...]
run() {
  name="$1" event="$2" want_status="$3" want="$4" unwanted="$5"
  shift 5
  log="${stub}/log"
  : >"${log}"
  status=0
  env PATH="${stub}:${PATH}" STUB_LOG="${log}" GITHUB_REPOSITORY=h3nc4/app \
    GITHUB_EVENT_NAME="${event}" "$@" sh "${script}" >"${stub}/out" 2>&1 || status=$?
  ok=yes
  [ "${status}" = "${want_status}" ] || ok="exit ${status}, wanted ${want_status}"
  if [ "${ok}" = yes ] && [ "${want}" != - ] && ! grep -qF -- "${want}" "${log}"; then
    ok="no call matching '${want}'"
  fi
  if [ "${ok}" = yes ] && [ "${unwanted}" != - ] && grep -qF -- "${unwanted}" "${log}"; then
    ok="unexpected call matching '${unwanted}'"
  fi
  if [ "${ok}" = yes ]; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: ${ok}"
    sed 's/^/     /' "${log}" "${stub}/out"
    failed=$((failed + 1))
  fi
}

run push_creates_missing_deps push 0 "api repos/h3nc4/app/git/refs -f ref=refs/heads/deps -f sha=abc123" "merges" STUB_DEPS=no
run push_merges_main_into_deps push 0 "api repos/h3nc4/app/merges -f base=deps -f head=main" "pr " STUB_DEPS=yes
run push_conflict_fails_and_changes_nothing push 1 "merges" "git/refs -f" STUB_CONFLICT=yes
run schedule_with_nothing_new_opens_nothing schedule 0 "compare/main...deps" "pr create" STUB_FILES=0
run schedule_opens_and_arms_new_promotion schedule 0 "pr merge 42 -R h3nc4/app --auto --squash --subject update dependencies for week 48 (#42) --body" "--delete-branch" STUB_FILES=3
run schedule_reuses_open_promotion schedule 0 "pr merge 7 -R h3nc4/app --auto --squash" "pr create" STUB_FILES=3 STUB_PR=7
run dispatch_syncs_before_promoting workflow_dispatch 0 "merges -f base=deps -f head=main" - STUB_FILES=0
run promotion_never_deletes_deps schedule 0 "--auto --squash" "--delete-branch" STUB_FILES=1
run other_event_is_refused pull_request 1 - "merges"
run passed_promotion_merges_directly schedule 0 "pr merge 7 -R h3nc4/app --squash --subject" - STUB_FILES=1 STUB_PR=7 STUB_AUTO_FAIL=yes STUB_STATE=CLEAN STUB_CHECKS=true
run unchecked_promotion_is_not_merged schedule 1 - "pr merge 7 -R h3nc4/app --squash --subject" STUB_FILES=1 STUB_PR=7 STUB_AUTO_FAIL=yes STUB_STATE=CLEAN STUB_CHECKS=false
run blocked_promotion_is_not_merged schedule 1 - "pr merge 7 -R h3nc4/app --squash --subject" STUB_FILES=1 STUB_PR=7 STUB_AUTO_FAIL=yes STUB_STATE=BLOCKED

echo "deps.test.sh: ${failed} failures"
[ "${failed}" -eq 0 ]

#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Henrique Almeida <me@h3nc4.com>

set -eu

branch="${DEPS_BRANCH:-deps}"
repo="${GITHUB_REPOSITORY:?}"
base="$(gh api "repos/${repo}" --jq .default_branch)"

sync() {
	if ! gh api "repos/${repo}/git/ref/heads/${branch}" --silent 2>/dev/null; then
		sha="$(gh api "repos/${repo}/git/ref/heads/${base}" --jq .object.sha)"
		gh api "repos/${repo}/git/refs" -f "ref=refs/heads/${branch}" -f "sha=${sha}" --silent
		echo "::notice::created ${branch} at ${sha}"
		return
	fi
	if ! out="$(gh api "repos/${repo}/merges" -f "base=${branch}" -f "head=${base}" \
		-f "commit_message=merge ${base} into ${branch}" 2>&1)"; then
		printf '%s\n' "${out}" >&2
		echo "::error::${base} does not merge into ${branch} cleanly, so ${branch} is left as it was"
		exit 1
	fi
	echo "::notice::${branch} contains ${base}"
}

promote() {
	files="$(gh api "repos/${repo}/compare/${base}...${branch}" --jq '.files | length')"
	if [ "${files}" = 0 ]; then
		echo "::notice::${branch} adds nothing to ${base}"
		return
	fi
	number="$(gh pr list -R "${repo}" --head "${branch}" --base "${base}" --state open \
		--json number --jq '.[0].number // empty')"
	if [ -z "${number}" ]; then
		week="$(date -u +%V)"
		url="$(gh pr create -R "${repo}" --head "${branch}" --base "${base}" \
			--title "update dependencies for week ${week#0}" \
			--body "Promotes the dependency updates merged into ${branch} since the last promotion.")"
		number="${url##*/}"
	fi
	title="$(gh pr view "${number}" -R "${repo}" --json title --jq .title)"
	if out="$(gh pr merge "${number}" -R "${repo}" --auto --squash --subject "${title} (#${number})" --body "" 2>&1)"; then
		echo "::notice::#${number} merges itself once its checks pass"
		return
	fi
	state="$(gh pr view "${number}" -R "${repo}" --json mergeStateStatus --jq .mergeStateStatus)"
	passed="$(gh pr checks "${number}" -R "${repo}" --json bucket \
		--jq '[.[].bucket] | length > 0 and all(. == "pass" or . == "skipping")')" || passed=false
	if [ "${state}" != CLEAN ] || [ "${passed}" != true ]; then
		printf '%s\n' "${out}" >&2
		echo "::error::could not turn on auto-merge for #${number}, which is ${state} with checks passed=${passed}"
		exit 1
	fi
	gh pr merge "${number}" -R "${repo}" --squash --subject "${title} (#${number})" --body ""
	echo "::notice::#${number} had already passed its checks, so it is merged now"
}

case "${GITHUB_EVENT_NAME:?}" in
push) sync ;;
schedule | workflow_dispatch)
	sync
	promote
	;;
*)
	echo "::error::runs on push, schedule or workflow_dispatch, not ${GITHUB_EVENT_NAME}"
	exit 1
	;;
esac

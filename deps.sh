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

# Prints the open pull request from the branch, opening a draft first when there is none. Prints nothing when the branch adds nothing.
open_pr() {
	files="$(gh api "repos/${repo}/compare/${base}...${branch}" --jq '.files | length')"
	[ "${files}" != 0 ] || return 0
	number="$(gh pr list -R "${repo}" --head "${branch}" --base "${base}" --state open \
		--json number --jq '.[0].number // empty')"
	if [ -z "${number}" ]; then
		url="$(gh pr create -R "${repo}" --head "${branch}" --base "${base}" --draft \
			--title "update dependencies" \
			--body "Promotes the dependency updates merged into ${branch} since the last promotion.")"
		number="${url##*/}"
	fi
	echo "${number}"
}

collect() {
	number="$(open_pr)"
	if [ -z "${number}" ]; then
		echo "::notice::${branch} adds nothing to ${base}"
		return
	fi
	echo "::notice::#${number} collects ${branch} until the weekly promotion"
}

promote() {
	number="$(open_pr)"
	if [ -z "${number}" ]; then
		echo "::notice::${branch} adds nothing to ${base}"
		return
	fi
	week="$(date -u +%V)"
	title="update dependencies for week ${week#0}"
	gh pr edit "${number}" -R "${repo}" --title "${title}" >/dev/null
	draft="$(gh pr view "${number}" -R "${repo}" --json isDraft --jq .isDraft)"
	if [ "${draft}" = true ]; then
		gh pr ready "${number}" -R "${repo}"
	fi
	if out="$(gh pr merge "${number}" -R "${repo}" --auto --squash --subject "${title} (#${number})" --body "" 2>&1)"; then
		echo "::notice::#${number} merges itself once its checks pass"
		return
	fi
	state="$(gh pr view "${number}" -R "${repo}" --json mergeStateStatus --jq .mergeStateStatus)"
	case "${state}" in
	BLOCKED | DIRTY | BEHIND | DRAFT)
		printf '%s\n' "${out}" >&2
		echo "::error::could not turn on auto-merge for #${number}, which is ${state}"
		exit 1
		;;
	*) ;;
	esac
	# GitHub refuses auto-merge where the default branch doesn't require checks, so wait for the checks here instead.
	poll="${DEPS_POLL_SECONDS:-30}"
	tries=0
	count=0
	while :; do
		count="$(gh pr checks "${number}" -R "${repo}" --json bucket --jq length 2>/dev/null)" || count=0
		[ "${count}" -gt 0 ] || [ "${tries}" -ge 10 ] && break
		tries=$((tries + 1))
		sleep "${poll}"
	done
	if [ "${count}" -gt 0 ]; then
		timeout 3600 gh pr checks "${number}" -R "${repo}" --watch --interval "${poll}" >/dev/null 2>&1 || :
		passed="$(gh pr checks "${number}" -R "${repo}" --json bucket \
			--jq '[.[].bucket] | all(. == "pass" or . == "skipping")')" || passed=false
		if [ "${passed}" != true ]; then
			echo "::error::#${number} has checks that did not pass, so it is not merged"
			exit 1
		fi
	else
		echo "::notice::#${number} does not start any check, and every update in it passed its own"
	fi
	gh pr merge "${number}" -R "${repo}" --squash --subject "${title} (#${number})" --body ""
	echo "::notice::#${number} is merged"
}

case "${GITHUB_EVENT_NAME:?}" in
push)
	if [ "${GITHUB_REF:-}" = "refs/heads/${branch}" ]; then
		collect
	else
		sync
	fi
	;;
schedule | workflow_dispatch)
	sync
	promote
	;;
*)
	echo "::error::runs on push, schedule or workflow_dispatch, not ${GITHUB_EVENT_NAME}"
	exit 1
	;;
esac

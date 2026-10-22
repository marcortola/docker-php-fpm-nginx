#!/usr/bin/env bash
# Expected issue text quotes Markdown code spans in single quotes.
# shellcheck disable=SC2016
# Fixture tests for ../security-watch.sh, run by the security_watch_tests job in ci.yml.
#
# Each test runs the script with gh, docker and curl replaced by the doubles in bin/, which
# answer from fixtures/ overridden file by file by cases/<case>/, and record every call. A
# test then checks the calls made, the decision file, the step outputs and the issue bodies.
#
# Usage: run.sh [test_name...]
set -euo pipefail
shopt -s inherit_errexit
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../security-watch.sh
readonly here script

# --- harness --------------------------------------------------------------------------------

fail() {
	echo "  $*" >&2
	echo "  --- log ---" >&2
	sed 's/^/  | /' "$work/log" >&2
	echo "  --- calls ---" >&2
	sed 's/^/  | /' "$CALLS" >&2
	exit 1
}

# Prepares a fresh work directory whose fixtures are the case's files over the defaults.
use_case() {
	local name=$1
	work=$(mktemp -d)
	mkdir -p "$work/fixtures" "$work/scan" "$work/rescan" "$work/state" "$work/stub"
	if [ -d "$here/cases/$name" ]; then cp -R "$here/cases/$name/." "$work/fixtures/"; fi
	cp "$here/fixtures/scan/"*.json "$work/scan/"
	cp "$here/fixtures/rescan/"*.json "$work/rescan/"
	if [ -d "$here/cases/$name/scan" ]; then cp "$here/cases/$name/scan/"*.json "$work/scan/"; fi
	if [ -d "$here/cases/$name/rescan" ]; then cp "$here/cases/$name/rescan/"*.json "$work/rescan/"; fi
	: > "$work/log"
	export FIXTURES=$work/fixtures DEFAULTS=$here/fixtures CALLS=$work/calls STUB_STATE=$work/stub
	: > "$CALLS"
	export PATH="$here/bin:$PATH"
	export REPOSITORY=example/repo STATE_DIR=$work/state SCAN_DIR=$work/scan RESCAN_DIR=$work/rescan
	export GITHUB_OUTPUT=$work/output WATCH_RUN_URL=https://github.com/example/repo/actions/runs/900
	export DRY_RUN=false POLL_SECONDS=0 WAIT_MINUTES=120
}

run() { "$script" "$@" 2>> "$work/log" || fail "$1 failed"; }
run_fails() { ! "$script" "$@" 2>> "$work/log" || fail "$1 succeeded; it must fail"; }

fp() { printf '%s' "$1" | sha256sum | cut -c1-16; }

calls() { grep -E "$1" "$CALLS" || true; }
expect_call() { grep -qE "$1" "$CALLS" || fail "no call matches: $1"; }
expect_no_call() { ! grep -qE "$1" "$CALLS" || fail "unexpected call: $(calls "$1")"; }
expect_no_writes() { expect_no_call '^gh (POST|PUT|PATCH|DELETE) '; }
expect_log() { grep -qE "$1" "$work/log" || fail "log lacks: $1"; }
expect_output() { grep -qx "$1=$2" "$GITHUB_OUTPUT" || fail "output $1 is not $2: $(cat "$GITHUB_OUTPUT")"; }
expect_decision() { jq -e "$1" "$STATE_DIR/decision.json" > /dev/null || fail "decision fails $1: $(jq -c . "$STATE_DIR/decision.json")"; }

# The request body of the only call matching a pattern.
body_of() {
	local matches
	matches=$(calls "$1")
	[ "$(grep -c . <<< "$matches")" -eq 1 ] || fail "expected one call matching $1, got: $matches"
	sed -E 's/^gh [A-Z]+ [^ ]+ //' <<< "$matches"
}
expect_body() { jq -e --arg text "$2" '.body | contains($text)' <<< "$1" > /dev/null || fail "body lacks '$2': $(jq -r .body <<< "$1")"; }
expect_body_not() { jq -e --arg text "$2" '.body | contains($text) | not' <<< "$1" > /dev/null || fail "body contains '$2': $(jq -r .body <<< "$1")"; }

# --- findings -------------------------------------------------------------------------------

test_no_newer_upstream() {
	use_case none
	run decide
	expect_output report false
	expect_output rescan false
	expect_decision '.findings == [] and .rebuild == null'
	expect_log 'PHP 8.5: ours 8.5.12 .* upstream 8.5.12: up to date'
	expect_no_call 'dispatches'
	run report
	expect_no_writes
}

test_newer_upstream_without_security_release() {
	use_case newer-upstream-non-security
	run decide
	expect_log 'PHP 8.5: ours 8.5.9 .* upstream 8.5.10: upstream 8.5.10 holds no security release after 8.5.9'
	expect_decision '.findings == []'
	expect_no_call 'dispatches'
	expect_no_writes
}

# 8.5.9 is a security release and 8.5.10 is not; php.net also lists 8.5.11 and 8.5.12, both
# security releases upstream has not shipped (8.5.10 here), which must not count.
test_security_release_mid_range() {
	use_case security-mid-range
	run decide
	expect_output report true
	expect_output rescan false
	expect_decision '.findings | length == 1'
	expect_decision '.findings[0] | .kind == "php" and .ours == "8.5.8" and .upstream == "8.5.10"'
	expect_decision '[.findings[0].releases[].version] == ["8.5.9"]'
	expect_decision '.findings[0].releases[0].url == "https://www.php.net/releases/8_5_9.php"'
	expect_decision ".findings[0].fingerprint == \"$(fp 'php 8.5 8.5.8->8.5.10')\""
	expect_decision '.rebuild == {id: 5001, url: "https://github.com/example/repo/actions/runs/5001", finished: true, conclusion: "success", reused: false}'
	expect_decision '.findings[0].verified == true'
	expect_decision '.findings[0].after == {"marcortola/php-fpm-nginx:8.5": "8.5.10", "marcortola/php-fpm-nginx:8.5-debug": "8.5.10"}'
	expect_call '^gh POST repos/example/repo/actions/workflows/ci.yml/dispatches ref=main return_run_details=true $'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	jq -e '.title == "Security update: PHP 8.5.10" and .labels == ["security-watch"] and .assignees == ["marcortola"]' <<< "$body" > /dev/null ||
		fail "issue fields: $body"
	expect_body "$body" 'The rebuild succeeded and the published images carry the fix.'
	expect_body "$body" 'PHP 8.5.8 -> 8.5.10'
	expect_body "$body" '[PHP 8.5.9](https://www.php.net/releases/8_5_9.php) (30 Jul 2026)'
	expect_body "$body" '`marcortola/php-fpm-nginx:8.5-debug`: PHP 8.5.10'
	expect_body "$body" 'Rebuild: https://github.com/example/repo/actions/runs/5001'
	expect_body "$body" 'Redeploy consumers with your private redeploy script.'
	expect_body "$body" "<!-- security-watch:fingerprint=$(fp 'php 8.5 8.5.8->8.5.10') -->"
	expect_body_not "$body" '8.5.11'
	expect_no_call '^gh POST repos/example/repo/issues/[0-9]+/comments'
	expect_no_call '^gh POST repos/example/repo/labels'
}

test_security_release_not_yet_in_upstream_image() {
	use_case security-not-in-upstream
	run decide
	expect_log 'PHP 8.5: ours 8.5.11 .* upstream 8.5.11: up to date'
	expect_decision '.findings == []'
	expect_no_call 'dispatches'
	expect_no_writes
}

# The real feed mixes tags [], [""] and ["security"], and announcement objects and booleans.
test_feed_shape_variants() {
	use_case feed-shape-variants
	DRY_RUN=true run decide
	expect_decision '[.findings[0].releases[].version] == ["8.5.11", "8.5.12"]'
	expect_decision '.findings[0].releases[0].url == "https://www.php.net/releases/8_5_11.php"'
	expect_decision '.findings[0].releases[1].url == "https://www.php.net/ChangeLog-8.php#8.5.12"'
}

test_malformed_feed_fails() {
	use_case malformed-feed
	run_fails decide
	expect_log 'release feed for 8.5 is malformed'
	expect_no_writes
	[ ! -e "$STATE_DIR/decision.json" ] || fail 'a failed decide wrote a decision'
}

test_truncated_feed_fails() {
	use_case truncated-feed
	run_fails decide
	expect_log 'release feed for 8.5 is malformed'
	expect_no_writes
}

test_unreachable_feed_fails() {
	use_case unreachable-feed
	run_fails decide
	expect_log 'release feed for 8.5 is unreachable'
	expect_no_writes
}

test_failed_inspect_fails() {
	use_case failed-inspect
	run_fails decide
	expect_log 'cannot inspect marcortola/php-fpm-nginx:8.5-debug'
	expect_no_writes
}

# Trivy lists no packages when it cannot detect the OS; that must not read as a clean image.
test_scan_without_detected_os_fails() {
	use_case undetected-os
	run_fails decide
	expect_log 'Trivy reports .* are invalid or incomplete'
	expect_no_writes
}

test_missing_scan_report_fails() {
	use_case none
	rm "$SCAN_DIR/8.2-debug.json"
	run_fails decide
	expect_log 'Trivy reports .* are invalid or incomplete'
	expect_no_writes
}

# --- deduplication --------------------------------------------------------------------------

test_known_fingerprint_on_closed_issue() {
	use_case known-on-closed-issue
	run decide
	expect_log "Finding php 8.5 8.5.8->8.5.10 \[$(fp 'php 8.5 8.5.8->8.5.10')\]: an issue records it; no action"
	expect_output report false
	expect_decision '.findings == []'
	expect_call '^gh GET repos/example/repo/issues\?labels=security-watch&state=all&per_page=100 $'
	expect_no_call 'dispatches'
	run report
	expect_no_writes
}

# A failure comment records its fingerprint too; markers in comments on other issues do not
# count.
test_known_fingerprint_in_comment() {
	use_case known-in-comment
	run decide
	expect_log 'an issue records it; no action'
	expect_decision '.findings == []'
	expect_no_call 'dispatches'
	expect_no_writes
}

# Two tags share a HIGH vulnerability, so two new fingerprints; a MEDIUM one is ignored. The
# open issue with the same title gets a comment; the closed one with another fingerprint
# changes nothing.
test_new_fingerprint() {
	use_case new-fingerprint
	run decide
	expect_output report true
	expect_output rescan true
	expect_decision '[.findings[].key] == ["alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0", "alpine 8.5-debug CVE-2026-0001 libcrypto3 3.5.4-r0"]'
	expect_decision ".findings[0].fingerprint == \"$(fp 'alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0')\""
	expect_call 'dispatches'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues/7/comments ')
	expect_no_call '^gh POST repos/example/repo/issues '
	expect_body "$body" 'The rebuild succeeded and the published images carry the fix.'
	expect_body "$body" '| [CVE-2026-0001](https://avd.aquasec.com/nvd/cve-2026-0001) | libcrypto3 | 3.5.4-r0 | 3.5.8-r0 | HIGH | `8.5`, `8.5-debug` | fixed (3.5.8-r0) |'
	expect_body_not "$body" 'CVE-2026-0002'
	expect_body "$body" 'Redeploy consumers with your private redeploy script.'
	expect_body "$body" "<!-- security-watch:fingerprint=$(fp 'alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0') -->"
	expect_body "$body" "<!-- security-watch:fingerprint=$(fp 'alpine 8.5-debug CVE-2026-0001 libcrypto3 3.5.4-r0') -->"
}

# --- rebuild outcomes -----------------------------------------------------------------------

test_failed_dispatched_run() {
	use_case failed-run
	run decide
	expect_output report true
	expect_output rescan false
	expect_decision '.rebuild.conclusion == "failure" and (.findings[0] | has("verified") | not)'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	jq -e '.title == "Security update: PHP 8.5.10"' <<< "$body" > /dev/null || fail "title: $body"
	expect_body "$body" '**The rebuild failed** (conclusion: `failure`)'
	expect_body "$body" 'Rebuild: https://github.com/example/repo/actions/runs/5001'
	expect_body "$body" "<!-- security-watch:fingerprint=$(fp 'php 8.5 8.5.8->8.5.10') -->"
	expect_body_not "$body" 'carry the fix'
	expect_body_not "$body" 'Redeploy consumers'
	expect_body_not "$body" 'Published after the rebuild'
}

test_unverified_php_rebuild() {
	use_case unverified-php
	run decide
	expect_decision '.rebuild.conclusion == "success" and .findings[0].verified == false'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	expect_body "$body" 'The rebuild succeeded, but the published images do not carry every fix.'
	expect_body "$body" '`marcortola/php-fpm-nginx:8.5`: PHP 8.5.8'
	expect_body_not "$body" 'Redeploy consumers'
}

test_alpine_fix_still_reported_after_rebuild() {
	use_case alpine-still-reported
	run decide
	expect_output rescan true
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	expect_body "$body" 'do not carry every fix'
	expect_body "$body" '| HIGH | `8.5` | still reported (3.5.4-r0) |'
	expect_body_not "$body" 'Redeploy consumers'
}

test_run_not_finished_in_time() {
	use_case run-timeout
	WAIT_MINUTES=0 run decide
	expect_output report true
	expect_decision '.rebuild.finished == false'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	expect_body "$body" '**The rebuild did not finish**'
	expect_body_not "$body" 'Redeploy consumers'
}

# Only a scheduled or dispatched run, still active and created after upstream's last push
# (22:11:44), rebuilds from the new image without cached layers: 6001.
test_reuses_active_rebuild() {
	use_case reuse-active-run
	run decide
	expect_no_call 'dispatches'
	expect_call '^curl https://hub.docker.com/v2/repositories/library/php/tags/8.5-fpm-alpine$'
	[ "$(calls '^gh GET repos/example/repo/actions/runs/6001 ' | wc -l)" -eq 3 ] || fail 'expected three polls of run 6001'
	expect_decision '.rebuild == {id: 6001, url: "https://github.com/example/repo/actions/runs/6001", finished: true, conclusion: "success", reused: true}'
	expect_decision '.findings[0].verified == true'
	run report
	expect_body "$(body_of '^gh POST repos/example/repo/issues ')" '(a run that had already started)'
}

test_alpine_finding_always_dispatches() {
	use_case new-fingerprint
	cp "$here/cases/reuse-active-run/ci-runs.json" "$FIXTURES/"
	run decide
	expect_call 'dispatches'
	expect_no_call 'hub.docker.com'
}

# --- dry run and alerts ---------------------------------------------------------------------

test_dry_run_writes_nothing() {
	use_case security-mid-range
	export DRY_RUN=true
	run decide
	expect_log 'Dry run: 1 new finding\(s\); would dispatch ci.yml on main, then write issues.'
	expect_output report false
	expect_decision '.dry_run == true and .rebuild == null and (.findings | length) == 1'
	run report
	expect_log 'Dry run: no issues written.'
	run alert
	expect_log "Dry run: would open or comment on 'Security watch failing'."
	expect_no_writes
	expect_no_call '^gh GET repos/example/repo/actions/runs/'
}

test_alert_opens_issue() {
	use_case none
	run alert
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	jq -e '.title == "Security watch failing" and .labels == ["security-watch"] and .assignees == ["marcortola"]' <<< "$body" > /dev/null ||
		fail "issue fields: $body"
	expect_body "$body" 'The security watch failed: https://github.com/example/repo/actions/runs/900'
}

test_alert_comments_on_open_issue_and_creates_label() {
	use_case alert-open-issue
	run alert
	expect_call '^gh POST repos/example/repo/labels name=security-watch '
	expect_body "$(body_of '^gh POST repos/example/repo/issues/12/comments ')" 'actions/runs/900'
	expect_no_call '^gh POST repos/example/repo/issues '
}

# --- main -----------------------------------------------------------------------------------

mapfile -t tests < <(if [ $# -gt 0 ]; then printf '%s\n' "$@"; else declare -F | awk '$3 ~ /^test_/ { print $3 }'; fi)
failed=0
for test in "${tests[@]}"; do
	set +e
	(set -e; "$test")
	status=$?
	set -e
	if [ "$status" -eq 0 ]; then
		echo "ok   $test"
	else
		echo "FAIL $test"
		failed=$((failed + 1))
	fi
done
echo "${#tests[@]} tests, $failed failed"
[ "$failed" -eq 0 ]

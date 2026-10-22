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
	export GITHUB_OUTPUT=$work/output WATCH_RUN_URL=https://github.com/example/repo/actions/runs/900 GITHUB_SERVER_URL=https://github.com
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
	expect_body "$body" '<!-- security-watch:php-notified=8.5:8.5.10 -->'
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

# The older of the two tags decides the range, and the finding records both.
test_debug_tag_lagging_base_tag() {
	use_case debug-lagging
	DRY_RUN=true run decide
	expect_log 'PHP 8.5: ours 8.5.8 \(marcortola/php-fpm-nginx:8.5 8.5.10, marcortola/php-fpm-nginx:8.5-debug 8.5.8\)'
	expect_decision '.findings | length == 1'
	expect_decision ".findings[0] | .key == \"php 8.5 8.5.8->8.5.10\" and .ours == \"8.5.8\" and .from == \"8.5.8\""
	expect_decision '.findings[0].before == {"marcortola/php-fpm-nginx:8.5": "8.5.10", "marcortola/php-fpm-nginx:8.5-debug": "8.5.8"}'
	expect_decision '[.findings[0].releases[].version] == ["8.5.9"]'
}

# 8.2.15 predates the oldest of the 20 releases php.net lists (8.2.16), so the range may hold
# security releases the feed does not show.
test_tags_older_than_feed_window() {
	use_case beyond-feed
	run decide
	expect_decision '.findings | length == 1'
	expect_decision '.findings[0] | .key == "php 8.2 8.2.15->8.2.35" and .beyond_feed == true and .verified == true'
	expect_decision '.findings[0].releases[0].version == "8.2.18" and .findings[0].releases[-1].version == "8.2.35"'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	expect_body "$body" 'PHP 8.2.15 -> 8.2.35'
	expect_body "$body" 'PHP 8.2.15 is older than the 20 most recent releases on php.net, so the range may hold more security releases than listed.'
	expect_body "$body" '<!-- security-watch:php-notified=8.2:8.2.35 -->'
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

# Anyone can comment on a public issue; a marker an outsider wrote must not silence a finding.
test_outsider_fingerprint_marker_ignored() {
	use_case outsider-fingerprint
	run decide
	expect_log "Finding php 8.5 8.5.8->8.5.10 \[$(fp 'php 8.5 8.5.8->8.5.10')\]: new"
	expect_decision '.findings | length == 1'
	expect_call 'dispatches'
}

# One of the two tags' findings is recorded already; only the other is acted on.
test_known_and_new_findings_in_one_run() {
	use_case mixed-known
	run decide
	expect_log "Finding alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0 \[$(fp 'alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0')\]: an issue records it; no action"
	expect_log "Finding alpine 8.5-debug CVE-2026-0001 libcrypto3 3.5.4-r0 \[$(fp 'alpine 8.5-debug CVE-2026-0001 libcrypto3 3.5.4-r0')\]: new"
	expect_decision '[.findings[].key] == ["alpine 8.5-debug CVE-2026-0001 libcrypto3 3.5.4-r0"]'
	expect_call 'dispatches'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	expect_body "$body" '| HIGH | `8.5-debug` | fixed (3.5.8-r0) |'
	expect_body "$body" "<!-- security-watch:fingerprint=$(fp 'alpine 8.5-debug CVE-2026-0001 libcrypto3 3.5.4-r0') -->"
	expect_body_not "$body" "$(fp 'alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0')"
}

# A workflow-authored body quotes poisoned release text holding a fingerprint of the 8.2 finding
# and a notice up to 8.5.12, mid-line and at the start or end of a line with other text. Only
# whole marker lines count, so 8.2 is still new and 8.5 is notified up to 8.5.10 only.
test_markers_mid_line_ignored() {
	use_case mid-line-markers
	DRY_RUN=true run decide
	expect_log "Finding php 8.2 8.2.33->8.2.35 \[$(fp 'php 8.2 8.2.33->8.2.35')\]: new"
	expect_log 'PHP 8.5: .* published since the last notice \(notified up to 8.5.10\)'
	expect_decision '[.findings[].key] == ["php 8.2 8.2.33->8.2.35", "php-published 8.5 8.5.10->8.5.12"]'
	expect_no_writes
}

# An edit in the web interface stores the body with CRLF line endings; its markers still count.
test_markers_on_crlf_lines_count() {
	use_case crlf-markers
	DRY_RUN=true run decide
	expect_log 'PHP 8.5: .* \(notified up to 8.5.6\)'
	expect_log "Finding php 8.5 8.5.8->8.5.10 \[$(fp 'php 8.5 8.5.8->8.5.10')\]: an issue records it; no action"
	expect_decision '.findings == []'
}

# The php.net date and announcement of 8.5.9 and a Trivy PrimaryURL carry line breaks followed by
# markers. The bodies keep that text inert: no marker line but the workflow's own, and no HTML
# comment the reader cannot see, so the next run is not notified up to 8.5.99.
test_external_text_cannot_plant_markers() {
	use_case poisoned-text
	cp "$here/cases/new-fingerprint/issues.json" "$FIXTURES/"
	run decide
	expect_decision '[.findings[].key] == ["php 8.5 8.5.8->8.5.10", "alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0"]'
	run report
	local bodies
	bodies=$(calls '^gh POST repos/example/repo/issues' | sed -E 's/^gh [A-Z]+ [^ ]+ //' | jq -s -c 'map(.body)')
	[ "$(jq length <<< "$bodies")" -eq 2 ] || fail "expected two bodies: $bodies"
	jq -e --arg php "$(fp 'php 8.5 8.5.8->8.5.10')" --arg alpine "$(fp 'alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0')" '
		[.[] | split("\n")[] | select(test("<!--"))] | sort == ([
			"<!-- security-watch:fingerprint=\($php) -->",
			"<!-- security-watch:php-notified=8.5:8.5.10 -->",
			"<!-- security-watch:fingerprint=\($alpine) -->"
		] | sort)' <<< "$bodies" > /dev/null || fail "bodies hold other comment lines: $bodies"
	jq -e 'all(.[]; test("\r") | not)' <<< "$bodies" > /dev/null || fail "a body holds a carriage return: $bodies"
	jq -e 'any(.[]; contains("(30 Jul 2026 &lt;!-- security-watch:php-notified=8.5:8.5.99 --> )"))' <<< "$bodies" > /dev/null ||
		fail "the poisoned date is not shown inert: $bodies"
	jq -e 'any(.[]; contains("(https://avd.aquasec.com/nvd/cve-2026-0001  &lt;!-- security-watch:fingerprint=bbbbbbbbbbbbbbbb --> )"))' <<< "$bodies" > /dev/null ||
		fail "the poisoned URL is not shown inert: $bodies"
	run decide
	expect_log 'PHP 8.5: .* up to date with upstream 8.5.10 \(notified up to 8.5.10\)'
}

# A rerun of the report job finds the issue its first attempt opened and writes nothing more.
test_report_rerun_is_idempotent() {
	use_case security-mid-range
	run decide
	run report
	run report
	expect_log "An issue already records every finding of 'Security update: PHP 8.5.10'; skipping."
	[ "$(calls '^gh POST repos/example/repo/issues ' | wc -l)" -eq 1 ] || fail 'expected one opened issue'
	expect_no_call '^gh POST repos/example/repo/issues/[0-9]+/comments'
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
	expect_body_not "$body" 'php-notified'
}

# --- releases published since the last notice -----------------------------------------------

# The weekly rebuild published 8.5.11 and 8.5.12, both security releases, before the watch saw
# the tags lag. The highest notice is 8.5.10 (8.5.9 sorts above it as text, not as a version).
# 8.2 has no notice, so its tags are the baseline and nothing is written for it.
test_security_release_published_by_another_rebuild() {
	use_case published-since-notice
	run decide
	expect_log 'PHP 8.5: .* published since the last notice \(notified up to 8.5.10\)'
	expect_output report true
	expect_output rescan false
	expect_decision '.rebuild == null and (.findings | length) == 1'
	expect_decision '.findings[0] | .notify_only == true and .key == "php-published 8.5 8.5.10->8.5.12" and .from == "8.5.10" and .to == "8.5.12"'
	expect_decision '[.findings[0].releases[].version] == ["8.5.11", "8.5.12"]'
	expect_no_call 'dispatches'
	expect_no_call 'actions/runs'
	expect_no_call 'hub.docker.com'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	jq -e '.title == "Security update: PHP 8.5.12"' <<< "$body" > /dev/null || fail "title: $body"
	expect_body "$body" 'already published the fix, so no rebuild was needed.'
	expect_body "$body" 'PHP 8.5.10 -> 8.5.12 in `marcortola/php-fpm-nginx:8.5`'
	expect_body "$body" '- [PHP 8.5.11](https://www.php.net/releases/8_5_11.php) (24 Sep 2026)'
	expect_body "$body" '`marcortola/php-fpm-nginx:8.5-debug`: PHP 8.5.12'
	expect_body "$body" 'Redeploy consumers with your private redeploy script.'
	expect_body "$body" "<!-- security-watch:fingerprint=$(fp 'php-published 8.5 8.5.10->8.5.12') -->"
	expect_body "$body" '<!-- security-watch:php-notified=8.5:8.5.12 -->'
	expect_body_not "$body" 'Rebuild:'
	expect_body_not "$body" '8.2'
	# The next run sees the new notice and stays quiet.
	run decide
	expect_log 'No new findings.'
	[ "$(calls '^gh POST ' | wc -l)" -eq 1 ] || fail 'the second run wrote again'
}

# 8.5.10 is not a security release, so a notice up to 8.5.9 needs no successor.
test_non_security_release_after_notice_is_not_notified() {
	use_case notified-non-security
	run decide
	expect_log 'PHP 8.5: ours 8.5.10 .* up to date with upstream 8.5.10 \(notified up to 8.5.9\)'
	expect_decision '.findings == []'
	expect_output report false
	expect_no_writes
}

# An outsider's comment claims 8.5.12 was notified; the workflow's own notice says 8.5.10.
test_outsider_notified_marker_ignored() {
	use_case outsider-notified
	DRY_RUN=true run decide
	expect_log 'Dry run: 1 new finding\(s\), all already published; would write issues.'
	expect_decision '.findings[0] | .notify_only == true and .from == "8.5.10"'
	expect_no_writes
}

# Our tags lag upstream 8.5.12, and the weekly rebuild had published 8.5.9 since the notice up
# to 8.5.8: the rebuild notice lists every security release since that notice.
test_lag_finding_lists_releases_since_last_notice() {
	use_case lag-since-notice
	run decide
	expect_decision '.findings[0] | .key == "php 8.5 8.5.10->8.5.12" and .from == "8.5.8" and (.notify_only | not)'
	expect_decision '[.findings[0].releases[].version] == ["8.5.9", "8.5.11", "8.5.12"]'
	expect_call 'dispatches'
	run report
	local body
	body=$(body_of '^gh POST repos/example/repo/issues ')
	expect_body "$body" 'PHP 8.5.8 -> 8.5.12'
	expect_body "$body" 'The rebuild succeeded and the published images carry the fix.'
	expect_body "$body" '<!-- security-watch:php-notified=8.5:8.5.12 -->'
}

# The weekly rebuild published 8.5.11 and 8.5.12 since the notice up to 8.5.10, and 8.2 lags
# upstream 8.2.35: one rebuild serves 8.2, and 8.5 gets a notice without one. The rebuild leaves
# the 8.5 tags alone, so they are not inspected again and their notice shows what was published.
test_published_and_lagging_branches_in_one_run() {
	use_case published-and-lagging
	run decide
	expect_output report true
	expect_output rescan false
	expect_decision '[.findings[].key] == ["php 8.2 8.2.33->8.2.35", "php-published 8.5 8.5.10->8.5.12"]'
	[ "$(calls 'dispatches' | wc -l)" -eq 1 ] || fail 'expected one dispatch'
	expect_log 'Dispatched ci.yml run 5001 for 1 new finding\(s\).'
	expect_call '^curl https://hub.docker.com/v2/repositories/library/php/tags/8.2-fpm-alpine$'
	expect_no_call 'hub.docker.com/.*/8.5-fpm-alpine'
	expect_decision '.rebuild == {id: 5001, url: "https://github.com/example/repo/actions/runs/5001", finished: true, conclusion: "success", reused: false}'
	expect_decision '.findings[0] | .verified == true and .after == {"marcortola/php-fpm-nginx:8.2": "8.2.35", "marcortola/php-fpm-nginx:8.2-debug": "8.2.35"}'
	expect_decision '.findings[1] | .notify_only == true and .verified == true and .after == .before'
	# verify_php re-inspects the rebuilt 8.2 tags only.
	expect_log 'PHP 8.2 after the rebuild'
	! grep -q 'PHP 8.5 after the rebuild' "$work/log" || fail 'verify_php inspected the notify-only 8.5 finding'
	[ "$(calls '^docker inspect marcortola/php-fpm-nginx:8.2$' | wc -l)" -eq 2 ] || fail 'expected two inspections of the 8.2 tag'
	[ "$(calls '^docker inspect marcortola/php-fpm-nginx:8.5$' | wc -l)" -eq 1 ] || fail 'expected one inspection of the 8.5 tag'
	run report
	local php82 php85
	php82=$(calls '^gh POST repos/example/repo/issues ' | sed -E 's/^gh [A-Z]+ [^ ]+ //' | jq -c 'select(.title == "Security update: PHP 8.2.35")')
	php85=$(calls '^gh POST repos/example/repo/issues ' | sed -E 's/^gh [A-Z]+ [^ ]+ //' | jq -c 'select(.title == "Security update: PHP 8.5.12")')
	if [ -z "$php82" ] || [ -z "$php85" ]; then fail "issues: $(calls '^gh POST repos/example/repo/issues ')"; fi
	[ "$(calls '^gh POST repos/example/repo/issues ' | wc -l)" -eq 2 ] || fail 'expected two issues'
	expect_body "$php82" 'The rebuild succeeded and the published images carry the fix.'
	expect_body "$php82" 'PHP 8.2.33 -> 8.2.35'
	expect_body "$php82" 'Rebuild: https://github.com/example/repo/actions/runs/5001'
	expect_body "$php82" '<!-- security-watch:php-notified=8.2:8.2.35 -->'
	expect_body_not "$php82" '8.5'
	expect_body "$php85" 'already published the fix, so no rebuild was needed.'
	expect_body "$php85" 'PHP 8.5.10 -> 8.5.12'
	expect_body "$php85" '`marcortola/php-fpm-nginx:8.5`: PHP 8.5.12'
	expect_body "$php85" '<!-- security-watch:php-notified=8.5:8.5.12 -->'
	expect_body_not "$php85" 'Rebuild:'
	expect_body_not "$php85" '8.2'
}

# --- rebuild outcomes -----------------------------------------------------------------------

# Both branches lag and an Alpine package is fixable: one rebuild serves every finding, and each
# issue group gets its own issue.
test_both_branches_and_alpine_in_one_run() {
	use_case multi-findings
	run decide
	expect_output rescan true
	expect_decision '[.findings[].key] == ["php 8.2 8.2.33->8.2.35", "php 8.5 8.5.8->8.5.10", "alpine 8.5 CVE-2026-0001 libcrypto3 3.5.4-r0", "alpine 8.5-debug CVE-2026-0001 libcrypto3 3.5.4-r0"]'
	expect_log 'Dispatched ci.yml run 5001 for 4 new finding\(s\).'
	[ "$(calls 'dispatches' | wc -l)" -eq 1 ] || fail 'expected one dispatch'
	expect_decision 'all(.findings[] | select(.kind == "php"); .verified == true)'
	run report
	[ "$(calls '^gh POST repos/example/repo/issues ' | sed -E 's/^gh [A-Z]+ [^ ]+ //' | jq -s -c 'map(.title) | sort')" = \
		'["Security update: Alpine packages (8.5)","Security update: PHP 8.2.35","Security update: PHP 8.5.10"]' ] ||
		fail "issue titles: $(calls '^gh POST repos/example/repo/issues ')"
	expect_no_call '^gh POST repos/example/repo/issues/[0-9]+/comments'
}

test_dispatch_without_run_id_fails() {
	use_case dispatch-without-run-id
	run_fails decide
	expect_log 'dispatching ci.yml returned no run id'
	expect_no_call 'actions/runs/'
	expect_no_call '^gh POST repos/example/repo/issues'
	[ ! -e "$STATE_DIR/decision.json" ] || fail 'a failed decide wrote a decision'
}

# A failed poll of an already dispatched run is retried rather than failing the watch.
test_transient_poll_error_recovers() {
	use_case transient-poll
	run decide
	expect_log 'cannot read ci.yml run 5001; retrying'
	[ "$(calls '^gh GET repos/example/repo/actions/runs/5001 ' | wc -l)" -eq 2 ] || fail 'expected two polls of run 5001'
	expect_decision '.rebuild == {id: 5001, url: "https://github.com/example/repo/actions/runs/5001", finished: true, conclusion: "success", reused: false}'
	expect_decision '.findings[0].verified == true'
}

# A run that cannot be read until the deadline is reported as unfinished, with its URL.
test_unreadable_run_until_deadline_is_unfinished() {
	use_case transient-poll
	echo '["fail"]' > "$FIXTURES/run-5001.json"
	WAIT_MINUTES=0 run decide
	expect_log 'ci.yml run 5001 is still unknown after 0 minutes'
	expect_decision '.rebuild == {id: 5001, url: "https://github.com/example/repo/actions/runs/5001", finished: false, conclusion: null, reused: false}'
	run report
	expect_body "$(body_of '^gh POST repos/example/repo/issues ')" '**The rebuild did not finish**'
}

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
	expect_body "$body" 'Once a rebuild of ci.yml succeeds and publishes the fix, redeploy consumers with your private redeploy script.'
	expect_body_not "$body" 'php-notified'
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
	expect_body "$body" 'Once a rebuild of ci.yml succeeds and publishes the fix, redeploy consumers with your private redeploy script.'
	expect_body_not "$body" 'php-notified'
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
	expect_body "$body" 'Once a rebuild of ci.yml succeeds and publishes the fix, redeploy consumers with your private redeploy script.'
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
	expect_body "$body" 'Once a rebuild of ci.yml succeeds and publishes the fix, redeploy consumers with your private redeploy script.'
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
	expect_body "$body" 'The watch may have dispatched a rebuild before it failed. Check the ci.yml runs at https://github.com/example/repo/actions/workflows/ci.yml, and if one succeeded, redeploy consumers with your private redeploy script.'
}

test_alert_comments_on_open_issue_and_creates_label() {
	use_case alert-open-issue
	run alert
	expect_call '^gh POST repos/example/repo/labels name=security-watch '
	expect_body "$(body_of '^gh POST repos/example/repo/issues/12/comments ')" 'actions/runs/900'
	expect_no_call '^gh POST repos/example/repo/issues '
}

# A passing run says so on the failure issue and closes it; the next passing run finds nothing
# open and writes nothing.
test_recover_closes_failure_issue() {
	use_case alert-open-issue
	run recover
	expect_body "$(body_of '^gh POST repos/example/repo/issues/12/comments ')" \
		'The security watch passes again: https://github.com/example/repo/actions/runs/900'
	expect_call '^gh PATCH repos/example/repo/issues/12 state=closed state_reason=completed $'
	# The comment comes first, so it is part of the notification that the issue closed.
	[ "$(grep -nE '^gh (POST|PATCH) ' "$CALLS" | cut -d' ' -f2 | tr '\n' ' ')" = 'POST PATCH ' ] ||
		fail "unexpected writes: $(calls '^gh (POST|PATCH) ')"
	expect_log 'Closed issue #12: Security watch failing'
	run recover
	expect_log 'No open failure issue to close.'
	[ "$(calls '^gh (POST|PATCH) ' | wc -l)" -eq 2 ] || fail 'the second run wrote again'
}

# Only the workflow's own open failure issue counts: not an outsider's issue with that title, a
# closed failure issue, or another open security-watch issue.
test_recover_closes_only_own_open_failure_issue() {
	use_case recover-mixed
	run recover
	expect_call '^gh POST repos/example/repo/issues/15/comments '
	expect_call '^gh PATCH repos/example/repo/issues/15 state=closed state_reason=completed $'
	[ "$(calls '^gh (POST|PATCH) ' | wc -l)" -eq 2 ] || fail "unexpected writes: $(calls '^gh (POST|PATCH) ')"
}

test_recover_without_failure_issue() {
	use_case none
	run recover
	expect_log 'No open failure issue to close.'
	expect_no_writes
}

test_recover_dry_run_writes_nothing() {
	use_case alert-open-issue
	DRY_RUN=true run recover
	expect_log "Dry run: would comment on and close issue #12: Security watch failing"
	expect_no_writes
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

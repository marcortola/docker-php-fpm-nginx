#!/usr/bin/env bash
# Decision logic of .github/workflows/security-watch.yml. It lives here rather than in the
# workflow so that .github/scripts/tests/run.sh can drive it against fixtures: every network
# access goes through gh, curl or docker, which the tests replace with stubs on PATH.
#
# Usage: security-watch.sh decide|report|alert
#
#   decide  Collects PHP and Alpine package findings, drops those a security-watch issue
#           already records, rebuilds every tag through ci.yml for the rest, waits for the run
#           and re-inspects the published PHP versions. Writes $STATE_DIR/decision.json and the
#           step outputs `report` and `rescan`.
#   report  Opens or comments on one issue per finding group in $STATE_DIR/decision.json,
#           verifying Alpine package fixes against the Trivy reports in $RESCAN_DIR.
#   alert   Opens or comments on the "Security watch failing" issue.
#
# Environment: REPOSITORY (owner/name), STATE_DIR, SCAN_DIR (decide), RESCAN_DIR (report, when
# the decision has Alpine findings and a successful rebuild), WATCH_RUN_URL, DRY_RUN
# (true|false), GITHUB_OUTPUT. POLL_SECONDS and WAIT_MINUTES tune the wait for ci.yml.
set -euo pipefail
# Without this, a failure inside $(...) would not stop the function running in it, and a
# failed fetch would read as an empty result.
shopt -s inherit_errexit

readonly LABEL=security-watch
readonly IMAGE=${IMAGE:-marcortola/php-fpm-nginx}
readonly PHP_VERSIONS=${PHP_VERSIONS:-8.2 8.5}
readonly ASSIGNEE=${ASSIGNEE:-marcortola}
readonly DRY_RUN=${DRY_RUN:-false}
readonly POLL_SECONDS=${POLL_SECONDS:-60}
readonly WAIT_MINUTES=${WAIT_MINUTES:-120}
readonly WATCH_RUN_URL=${WATCH_RUN_URL:-}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

require() {
	local name
	for name in "$@"; do
		[ -n "${!name:-}" ] || die "$name is not set"
	done
}

output() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

dry_run() { [ "$DRY_RUN" = true ]; }

# A short hash of a finding's identity. Issues carry it in a hidden marker, so a finding that
# any issue (open or closed) already records is never acted on again.
fingerprint() { printf '%s' "$1" | sha256sum | cut -c1-16; }

marker() { printf '<!-- security-watch:fingerprint=%s -->' "$1"; }

# PHP_VERSION from the linux/amd64 config of an image on its registry.
php_version_of() {
	local ref=$1 config version
	config=$(docker buildx imagetools inspect --format '{{json .Image}}' "$ref") ||
		die "cannot inspect $ref"
	version=$(jq -er '
		if has("linux/amd64") then ."linux/amd64" else . end
		| .config.Env[] | select(startswith("PHP_VERSION=")) | ltrimstr("PHP_VERSION=")' \
		<<< "$config") || die "$ref has no PHP_VERSION in its linux/amd64 config"
	[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$ref has PHP_VERSION '$version'"
	printf '%s\n' "$version"
}

# The 20 most recent releases of one PHP branch. Entries vary in shape (tags may be [] or [""],
# announcement a boolean or an object), which the checks tolerate; anything that is not a map
# of this branch's versions to release objects fails the run rather than reading as "no
# security release".
fetch_feed() {
	local php=$1 feed
	feed=$(curl -fsS --retry 3 --retry-all-errors --max-time 60 \
		"https://www.php.net/releases/index.php?json&version=$php&max=20") ||
		die "the php.net release feed for $php is unreachable"
	jq -e --arg php "$php" '
		type == "object" and length > 0 and all(to_entries[];
			(.key | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.key | startswith($php + "."))
			and (.value | type == "object")
			and ((.value.tags // []) | type == "array" and all(.[]; type == "string")))' \
		<<< "$feed" > /dev/null 2>&1 || die "the php.net release feed for $php is malformed"
	printf '%s\n' "$feed"
}

# A PHP finding exists when our tags lag upstream php:<php>-fpm-alpine and a release in
# (ours, upstream] is a security release. A security release php.net announced that upstream
# has not built yet is no finding: a later watch run sees it once upstream ships it.
php_findings() {
	local php version upstream base debug ours feed result findings='[]'
	for php in $PHP_VERSIONS; do
		upstream=$(php_version_of "php:$php-fpm-alpine")
		base=$(php_version_of "$IMAGE:$php")
		debug=$(php_version_of "$IMAGE:$php-debug")
		for version in "$upstream" "$base" "$debug"; do
			[[ $version == "$php".* ]] || die "PHP $version found where $php.x was expected"
		done
		ours=$(printf '%s\n' "$base" "$debug" | sort -V | head -n 1)
		feed=$(fetch_feed "$php")
		result=$(jq -n --argjson feed "$feed" --arg php "$php" --arg image "$IMAGE" \
			--arg upstream "$upstream" --arg base "$base" --arg debug "$debug" --arg ours "$ours" '
			def v: split(".") | map(tonumber);
			($ours | v) as $o | ($upstream | v) as $u
			| ([$feed | keys[] | v] | min) as $oldest
			| [$feed | to_entries[] | select((.key | v) > $o and (.key | v) <= $u)
				| select(any((.value.tags // [])[]; . == "security"))
				| {
					version: .key,
					date: (.value.date // ""),
					url: (if (.value.announcement | type) == "object"
							and (.value.announcement.English | type) == "string"
						then "https://www.php.net" + .value.announcement.English
						else "https://www.php.net/ChangeLog-\($php | split(".")[0]).php#\(.key)" end)
				}] as $security
			| if $o >= $u then
				{reason: "up to date with upstream \($upstream)"}
			elif ($security | length) == 0 and $o >= $oldest then
				{reason: "upstream \($upstream) holds no security release after \($ours)"}
			else {
				reason: "security release in (\($ours), \($upstream)]",
				finding: {
					kind: "php",
					php: $php,
					issue: "Security update: PHP \($upstream)",
					key: "php \($php) \($ours)->\($upstream)",
					ours: $ours,
					upstream: $upstream,
					before: {($image + ":" + $php): $base, ($image + ":" + $php + "-debug"): $debug},
					releases: ($security | sort_by(.version | v)),
					beyond_feed: ($o < $oldest)
				}
			} end')
		log "PHP $php: ours $ours ($IMAGE:$php $base, $IMAGE:$php-debug $debug), upstream $upstream: $(jq -r .reason <<< "$result")"
		findings=$(jq -c --argjson result "$result" '. + [$result.finding // empty]' <<< "$findings")
	done
	printf '%s\n' "$findings"
}

# Fails unless the directory holds one valid Trivy report on an Alpine OS per published tag.
# A report whose OS Trivy did not detect lists no packages, which must not read as clean.
check_reports() {
	local dir=$1 tags=() php
	for php in $PHP_VERSIONS; do tags+=("$php" "$php-debug"); done
	compgen -G "$dir/*.json" > /dev/null || die "no Trivy reports in $dir"
	cat "$dir"/*.json | jq -s -e --arg image "$IMAGE" --args '
		all(.[]; .SchemaVersion == 2 and (.ArtifactName | type == "string")
			and .Metadata.OS.Family == "alpine" and (.Results | type == "array"))
		and ([.[] | .ArtifactName] | sort) == ([$ARGS.positional[] | "\($image):\(.)"] | sort)' \
		"${tags[@]}" > /dev/null 2>&1 || die "the Trivy reports in $dir are invalid or incomplete"
}

# Every fixable HIGH or CRITICAL OS package vulnerability, one finding per tag and package.
alpine_findings() {
	check_reports "$SCAN_DIR"
	jq -s --arg image "$IMAGE" '
		[.[] | (.ArtifactName | ltrimstr($image + ":")) as $tag
			| .Results[] | select(.Class == "os-pkgs") | (.Vulnerabilities // [])[]
			| select(.Severity == "HIGH" or .Severity == "CRITICAL")
			| select((.FixedVersion // "") != "")
			| {
				kind: "alpine",
				php: ($tag | sub("-debug$"; "")),
				tag: $tag,
				id: .VulnerabilityID,
				pkg: .PkgName,
				installed: .InstalledVersion,
				fixed: .FixedVersion,
				severity: .Severity,
				url: (.PrimaryURL // "")
			}]
		| unique_by([.tag, .id, .pkg, .installed])
		| map(. + {
			issue: "Security update: Alpine packages (\(.php))",
			key: "alpine \(.tag) \(.id) \(.pkg) \(.installed)"
		})' "$SCAN_DIR"/*.json
}

add_fingerprints() {
	local findings key fingerprints=()
	findings=$(cat)
	while IFS= read -r key; do
		fingerprints+=("$(fingerprint "$key")")
	done < <(jq -r '.[].key' <<< "$findings")
	jq --args '[to_entries[] | .value + {fingerprint: $ARGS.positional[.key]}]' \
		"${fingerprints[@]}" <<< "$findings"
}

# Fingerprints recorded by any security-watch issue, open or closed, in its body or comments.
# Listed through the REST API: the search API does not index HTML comments reliably.
known_fingerprints() {
	gh api --paginate "repos/$REPOSITORY/issues?labels=$LABEL&state=all&per_page=100" |
		jq -s 'add // []' > "$STATE_DIR/issues.json"
	gh api --paginate "repos/$REPOSITORY/issues/comments?per_page=100" |
		jq -s 'add // []' > "$STATE_DIR/comments.json"
	jq -n --slurpfile issues "$STATE_DIR/issues.json" --slurpfile comments "$STATE_DIR/comments.json" '
		($issues[0] | map(.url)) as $urls
		| [($issues[0][] | .body), ($comments[0][] | select(.issue_url as $u | $urls | index($u)) | .body)]
		| [.[] | strings | scan("<!-- security-watch:fingerprint=([0-9a-f]{16}) -->")[0]]
		| unique'
}

epoch_jq='def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;'

# A ci.yml run that already rebuilds from the current upstream image: queued or running on main,
# without the layer cache (scheduled or dispatched; a push build reuses cached apk layers), and
# created after upstream last pushed every PHP image the findings need. Alpine findings always
# need a fresh run, since nothing dates the package fix.
active_rebuild() {
	local new=$1 php after=0 pushed
	if jq -e 'any(.[]; .kind == "alpine")' <<< "$new" > /dev/null; then
		return 0
	fi
	for php in $(jq -r '[.[].php] | unique | .[]' <<< "$new"); do
		pushed=$(curl -fsS --retry 3 --retry-all-errors --max-time 60 \
			"https://hub.docker.com/v2/repositories/library/php/tags/$php-fpm-alpine" |
			jq -er "$epoch_jq"' .tag_last_pushed // .last_updated | epoch') ||
			die "cannot read when php:$php-fpm-alpine was last pushed"
		if [ "$pushed" -gt "$after" ]; then after=$pushed; fi
	done
	gh api "repos/$REPOSITORY/actions/workflows/ci.yml/runs?branch=main&per_page=30" |
		jq -r --argjson after "$after" "$epoch_jq"'
			[.workflow_runs[]
				| select(.status != "completed")
				| select(.event == "schedule" or .event == "workflow_dispatch")
				| select((.created_at | epoch) > $after)]
			| sort_by(.created_at) | last | .id // empty'
}

dispatch_rebuild() {
	gh api -X POST "repos/$REPOSITORY/actions/workflows/ci.yml/dispatches" \
		-f ref=main -F return_run_details=true | jq -er '.workflow_run_id' ||
		die "dispatching ci.yml returned no run id"
}

# Waits for a ci.yml run; prints {id, url, finished, conclusion}.
wait_for_run() {
	local id=$1 deadline=$((SECONDS + WAIT_MINUTES * 60)) run status
	while :; do
		run=$(gh api "repos/$REPOSITORY/actions/runs/$id")
		status=$(jq -er .status <<< "$run")
		if [ "$status" = completed ]; then
			jq '{id, url: .html_url, finished: true, conclusion}' <<< "$run"
			return
		fi
		if [ "$SECONDS" -ge "$deadline" ]; then
			log "ci.yml run $id is still $status after $WAIT_MINUTES minutes"
			jq '{id, url: .html_url, finished: false, conclusion: null}' <<< "$run"
			return
		fi
		log "ci.yml run $id is $status; waiting"
		sleep "$POLL_SECONDS"
	done
}

# Marks each PHP finding verified when both its published tags now carry upstream's version.
verify_php() {
	local findings=$1 index php tag version after
	for index in $(jq -r 'to_entries[] | select(.value.kind == "php") | .key' <<< "$findings"); do
		php=$(jq -r ".[$index].php" <<< "$findings")
		after='{}'
		for tag in "$php" "$php-debug"; do
			version=$(php_version_of "$IMAGE:$tag")
			after=$(jq -c --arg ref "$IMAGE:$tag" --arg version "$version" '. + {($ref): $version}' <<< "$after")
		done
		findings=$(jq --argjson index "$index" --argjson after "$after" '
			def v: split(".") | map(tonumber);
			.[$index] |= (. + {
				after: $after,
				verified: (.upstream as $u | all($after[]; v >= ($u | v)))
			})' <<< "$findings")
		log "PHP $php after the rebuild: $(jq -c . <<< "$after")"
	done
	printf '%s\n' "$findings"
}

write_decision() { # findings, rebuild
	jq --argjson rebuild "$2" --arg dry_run "$DRY_RUN" \
		--arg watch "$WATCH_RUN_URL" '{
			dry_run: ($dry_run == "true"),
			watch_run_url: $watch,
			rebuild: $rebuild,
			findings: .
		}' <<< "$1" > "$STATE_DIR/decision.json"
}

cmd_decide() {
	require REPOSITORY STATE_DIR SCAN_DIR
	mkdir -p "$STATE_DIR"
	local php alpine findings known new count run_id reused=false rebuild rescan=false
	php=$(php_findings)
	alpine=$(alpine_findings)
	findings=$(printf '%s\n' "$php" "$alpine" | jq -s 'add' | add_fingerprints)
	known=$(known_fingerprints)
	new=$(jq --argjson known "$known" '[.[] | select(.fingerprint as $f | $known | index($f) | not)]' <<< "$findings")
	jq -r --argjson known "$known" '.[] |
		"Finding \(.key) [\(.fingerprint)]: \(if (.fingerprint as $f | $known | index($f)) then "an issue records it; no action" else "new" end)"' \
		<<< "$findings" >&2
	count=$(jq length <<< "$new")
	if [ "$count" -eq 0 ]; then
		log 'No new findings.'
		write_decision '[]' null
		output report false
		output rescan false
		return
	fi

	run_id=$(active_rebuild "$new")
	if dry_run; then
		if [ -n "$run_id" ]; then
			log "Dry run: $count new finding(s); would wait for ci.yml run $run_id, then write issues."
		else
			log "Dry run: $count new finding(s); would dispatch ci.yml on main, then write issues."
		fi
		write_decision "$new" null
		output report false
		output rescan false
		return
	fi
	if [ -n "$run_id" ]; then
		reused=true
		log "ci.yml run $run_id already rebuilds from the current upstream image; waiting for it."
	else
		run_id=$(dispatch_rebuild)
		log "Dispatched ci.yml run $run_id for $count new finding(s)."
	fi
	rebuild=$(wait_for_run "$run_id" | jq --argjson reused "$reused" '. + {reused: $reused}')
	log "ci.yml run $run_id: $(jq -c . <<< "$rebuild")"
	if jq -e '.conclusion == "success"' <<< "$rebuild" > /dev/null; then
		new=$(verify_php "$new")
		if jq -e 'any(.[]; .kind == "alpine")' <<< "$new" > /dev/null; then
			rescan=true
		fi
	fi
	write_decision "$new" "$rebuild"
	output report true
	output rescan "$rescan"
}

# Marks each Alpine finding verified when the rescan of its tag no longer reports the
# vulnerability for that package, and records the package version the tag now ships.
verify_alpine() {
	local decision=$1
	check_reports "$RESCAN_DIR"
	jq --arg image "$IMAGE" --slurpfile reports <(cat "$RESCAN_DIR"/*.json) '
		($reports | map({key: (.ArtifactName | ltrimstr($image + ":")), value: .}) | from_entries) as $by_tag
		| .findings |= map(if .kind != "alpine" then . else
			. as $f
			| ($by_tag[$f.tag].Results | map(select(.Class == "os-pkgs"))) as $results
			| . + {
				verified: ([$results[] | (.Vulnerabilities // [])[]
					| select(.VulnerabilityID == $f.id and .PkgName == $f.pkg)] | length == 0),
				now: ([$results[] | (.Packages // [])[] | select(.Name == $f.pkg) | .Version] | first // null)
			} end)' <<< "$decision"
}

# shellcheck disable=SC2016 # a jq program; its $names are jq variables
render_body_jq='
def state:
	if $rebuild.finished != true then "unfinished"
	elif $rebuild.conclusion != "success" then "failed"
	elif all($group[]; .verified == true) then "fixed"
	else "unverified" end;
def php_section:
	$group[] | (
		"PHP \(.ours) -> \(.upstream) in `\($image):\(.php)` and `\($image):\(.php)-debug`. Security releases in that range:",
		"",
		(.releases[] | "- [PHP \(.version)](\(.url))\(if .date != "" then " (\(.date))" else "" end)"),
		(if .beyond_feed then "", "Our tags were older than the 20 most recent releases on php.net, so the range may hold more security releases." else empty end),
		"",
		(if .after then
			"Published after the rebuild:", "",
			(.after | to_entries[] | "- `\(.key)`: PHP \(.value)")
		else empty end)
	);
# One row per vulnerable package version across tags, at most 100 rows, so that a badly stale
# image still fits GitHub'\''s 65536-character body. The markers below list every finding.
def alpine_section:
	($rebuild.conclusion == "success") as $after
	| ($group | group_by([.id, .pkg, .installed, .fixed]) | map({
		id: .[0].id, url: .[0].url, pkg: .[0].pkg, installed: .[0].installed, fixed: .[0].fixed,
		severity: .[0].severity, tags: (map(.tag) | unique), now: (map(.now // empty) | unique),
		verified: all(.[]; .verified == true)
	}) | sort_by(.pkg, .id)) as $rows
	| "| Vulnerability | Package | Installed | Fixed in | Severity | Tags |\(if $after then " After the rebuild |" else "" end)",
	"| --- | --- | --- | --- | --- | --- |\(if $after then " --- |" else "" end)",
	($rows[:100][] | "| \(if .url != "" then "[\(.id)](\(.url))" else .id end) | \(.pkg) | \(.installed) | \(.fixed) | \(.severity) | \(.tags | map("`\(.)`") | join(", ")) |\(if $after then " \(if .verified then "fixed" else "still reported" end)\(if .now != [] then " (\(.now | join(", ")))" else "" end) |" else "" end)"),
	(if ($rows | length) > 100 then "", "\(($rows | length) - 100) more rows are omitted; the watch run log lists every finding." else empty end);
state as $state
| [
	(if $state == "fixed" then "The rebuild succeeded and the published images carry the fix."
	elif $state == "failed" then "**The rebuild failed** (conclusion: `\($rebuild.conclusion)`). The published images may still be vulnerable. The watch does not retry these findings: fix the cause and rebuild with `gh workflow run ci.yml --ref main`."
	elif $state == "unfinished" then "**The rebuild did not finish** while the watch waited. The published images may still be vulnerable. The watch does not retry these findings: check the run, and rebuild with `gh workflow run ci.yml --ref main` if it failed."
	else "**The rebuild succeeded, but the published images do not carry every fix.** The watch does not retry these findings: check the images and the run below." end),
	"",
	(if $group[0].kind == "php" then php_section else alpine_section end),
	"",
	"Rebuild: \($rebuild.url)\(if $rebuild.reused then " (a run that had already started)" else "" end)",
	"Watch run: \($watch)",
	(if $state == "fixed" then "", "Redeploy consumers with your private redeploy script." else empty end),
	"",
	($group[] | "<!-- security-watch:fingerprint=\(.fingerprint) -->")
] | join("\n")'

ensure_label() {
	if ! gh api --paginate "repos/$REPOSITORY/labels?per_page=100" |
		jq -s -e --arg label "$LABEL" 'add // [] | any(.[]; .name == $label)' > /dev/null; then
		gh api -X POST "repos/$REPOSITORY/labels" -f name="$LABEL" -f color=b60205 \
			-f description='Opened by .github/workflows/security-watch.yml' > /dev/null
	fi
}

# Comments on the open security-watch issue with this title, or opens one. Body edits do not
# notify anyone, so every state change is a new issue or comment.
post() {
	local title=$1 body=$2 number url
	number=$(gh api --paginate "repos/$REPOSITORY/issues?labels=$LABEL&state=open&per_page=100" |
		jq -s -r --arg title "$title" 'add // [] | map(select(.title == $title and (.pull_request | not)))
			| sort_by(.number) | last | .number // empty')
	if [ -n "$number" ]; then
		jq -n --arg body "$body" '{body: $body}' |
			gh api -X POST "repos/$REPOSITORY/issues/$number/comments" --input - > /dev/null
		log "Commented on issue #$number: $title"
	else
		url=$(jq -n --arg title "$title" --arg body "$body" --arg label "$LABEL" --arg assignee "$ASSIGNEE" \
			'{title: $title, body: $body, labels: [$label], assignees: [$assignee]}' |
			gh api -X POST "repos/$REPOSITORY/issues" --input - | jq -r .html_url)
		log "Opened $url: $title"
	fi
}

cmd_report() {
	require REPOSITORY STATE_DIR
	local decision title body
	decision=$(cat "$STATE_DIR/decision.json")
	if jq -e '.dry_run' <<< "$decision" > /dev/null; then
		log 'Dry run: no issues written.'
		return
	fi
	if jq -e '.findings == [] or .rebuild == null' <<< "$decision" > /dev/null; then
		log 'Nothing to report.'
		return
	fi
	if jq -e '.rebuild.conclusion == "success" and any(.findings[]; .kind == "alpine")' <<< "$decision" > /dev/null; then
		require RESCAN_DIR
		decision=$(verify_alpine "$decision")
	fi
	ensure_label
	while IFS= read -r title; do
		body=$(jq -r --arg title "$title" --arg image "$IMAGE" '
			.rebuild as $rebuild | .watch_run_url as $watch
			| [.findings[] | select(.issue == $title)] as $group
			| '"$render_body_jq" <<< "$decision")
		post "$title" "$body"
	done < <(jq -r '[.findings[].issue] | unique | .[]' <<< "$decision")
}

cmd_alert() {
	require REPOSITORY WATCH_RUN_URL
	local title='Security watch failing' body
	body="The security watch failed: $WATCH_RUN_URL

Until it passes again, new PHP security releases and Alpine package fixes are neither detected nor rebuilt."
	if dry_run; then
		log "Dry run: would open or comment on '$title'."
		return
	fi
	ensure_label
	post "$title" "$body"
}

case "${1:-}" in
	decide) cmd_decide ;;
	report) cmd_report ;;
	alert) cmd_alert ;;
	*) die "usage: $0 decide|report|alert" ;;
esac

# shellcheck shell=bash
# Shared by the test doubles in this directory. A case directory ($FIXTURES) overrides the
# default fixtures ($DEFAULTS) file by file; a file named <fixture>.fail makes the call fail
# as an unreachable or failing service would.

fixture() {
	local name=$1 dir
	if [ -e "$FIXTURES/$name.fail" ]; then
		echo "stub: $name fails as configured" >&2
		return 22
	fi
	for dir in "$FIXTURES" "$DEFAULTS"; do
		if [ -f "$dir/$name" ]; then
			cat "$dir/$name"
			return
		fi
	done
	echo "stub: no fixture $name" >&2
	return 1
}

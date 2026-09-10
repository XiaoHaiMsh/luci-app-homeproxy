#!/bin/sh

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_DIR="$REPO_ROOT/luci-app-homeproxy/root/etc/homeproxy/dashboard"

GH_API="https://api.github.com"

log() {
	printf '[homeproxy] %s\n' "$*"
}

skip() {
	log "[$1] Skip: $2"
}

curl_get() {
	if [ -n "$GITHUB_TOKEN" ]; then
		curl -fsSL --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 \
			-H "Authorization: Bearer $GITHUB_TOKEN" "$1"
	else
		curl -fsSL --connect-timeout 8 --max-time 20 --retry 2 --retry-delay 2 "$1"
	fi
}

json_first_sha() {
	if command -v jq >"/dev/null" 2>&1; then
		jq -r '.[0].sha // empty' 2>"/dev/null"
	else
		grep -o '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' | head -n1 | sed -E 's/.*"([0-9a-f]+)"$/\1/'
	fi
}

mkdir -p "$DASHBOARD_DIR" 2>"/dev/null"

update_dashboard() {
	repo="SagerNet/sing-box-dashboard"
	branch="gh-pages"

	commit_info="$(curl_get "$GH_API/repos/$repo/commits?sha=$branch&per_page=1")"
	[ -n "$commit_info" ] || { skip "dashboard" "Failed to access GitHub API, keeping local version"; return 0; }

	commit_sha="$(printf '%s' "$commit_info" | json_first_sha)"
	[ -n "$commit_sha" ] || { skip "dashboard" "Failed to parse latest version, keeping local version"; return 0; }
	dashboard_ver="$commit_sha"

	local_ver="$(cat "$DASHBOARD_DIR/dashboard.ver" 2>"/dev/null")"
	if [ "$local_ver" = "$dashboard_ver" ] && [ -s "$DASHBOARD_DIR/index.html" ]; then
		skip "dashboard" "Already up to date (version $dashboard_ver)"
		return 0
	fi

	tmp_zip="$(mktemp)"
	tmp_extract="$(mktemp -d)"

	curl -fsSL --connect-timeout 8 --max-time 60 --retry 2 --retry-delay 2 \
		"https://codeload.github.com/$repo/zip/$commit_sha" -o "$tmp_zip"
	if [ ! -s "$tmp_zip" ]; then
		rm -f "$tmp_zip"; rm -rf "$tmp_extract"
		skip "dashboard" "Download failed, keeping local version"
		return 0
	fi

	if ! unzip -q -o "$tmp_zip" -d "$tmp_extract"; then
		rm -f "$tmp_zip"; rm -rf "$tmp_extract"
		skip "dashboard" "Extraction failed, keeping local version"
		return 0
	fi

	index_file="$(find "$tmp_extract" -maxdepth 2 -name 'index.html' | head -n1)"
	if [ -z "$index_file" ]; then
		rm -f "$tmp_zip"; rm -rf "$tmp_extract"
		skip "dashboard" "Invalid archive contents, keeping local version"
		return 0
	fi
	src_dir="$(dirname "$index_file")"

	rm -rf "$DASHBOARD_DIR"
	mkdir -p "$DASHBOARD_DIR"
	cp -a "$src_dir"/. "$DASHBOARD_DIR"/
	find "$DASHBOARD_DIR" -type d -exec chmod 755 {} \;
	find "$DASHBOARD_DIR" -type f -exec chmod 644 {} \;

	printf '%s\n' "$dashboard_ver" >"$DASHBOARD_DIR/dashboard.ver"
	log "[dashboard] Updated to version $dashboard_ver"

	rm -f "$tmp_zip"
	rm -rf "$tmp_extract"
}

update_dashboard

sh "$SCRIPT_DIR/update-cache.sh"

log "All checks completed"
exit 0

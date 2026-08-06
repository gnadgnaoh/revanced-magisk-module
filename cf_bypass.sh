#!/usr/bin/env bash
if [ -z "${cf_user_agent:-}" ]; then
	cf_user_agent=$(wget -qO- https://www.whatismybrowser.com/guides/the-latest-user-agent/firefox 2>/dev/null \
		| tr '\n' ' ' | sed 's#</tr>#\n#g' \
		| grep 'Firefox (Standard)' \
		| sed -n 's/.*<span class="code">\([^<]*Android[^<]*\)<\/span>.*/\1/p') || cf_user_agent=
	[ -z "$cf_user_agent" ] && cf_user_agent='Mozilla/5.0 (Android 16; Mobile; rv:146.0) Gecko/146.0 Firefox/146.0'
fi
user_agent="$cf_user_agent"
FS_COOKIES="${FS_COOKIES:-}"

green_log()  { pr "$1"; }
red_log()    { epr "$1"; }
yellow_log() { wpr "$1"; }

_fs_get() {
	local url=$1
	local max_retries=3
	local attempt
	for attempt in $(seq 1 $max_retries); do
		local response
		response=$(curl -s -X POST 'http://localhost:8191/v1' \
			-H 'Content-Type: application/json' \
			-d "{\"cmd\":\"request.get\",\"url\":\"$url\",\"maxTimeout\":15000}")
		local status
		status=$(echo "$response" | jq -r '.status // empty')
		if [[ "$status" == "ok" ]]; then
			html=$(echo "$response" | jq -r '.solution.response // empty')
			export FS_COOKIES
			FS_COOKIES=$(echo "$response" | jq -r '[.solution.cookies[] | .name + "=" + .value] | join("; ")')
			user_agent=$(echo "$response" | jq -r '.solution.userAgent // empty')
			return 0
		fi
		yellow_log "[!] FlareSolverr attempt $attempt/$max_retries failed: $url"
		sleep 5
	done
	red_log "[-] FlareSolverr failed after $max_retries attempts: $url"
	return 1
}

_cfb_get() {
	local url=$1
	local max_retries=3
	local attempt
	for attempt in $(seq 1 $max_retries); do
		local response_file
		rm -f /tmp/cfb_response_headers.txt
		response_file=$(mktemp)
		local http_code
		http_code=$(curl -s -o "$response_file" -w '%{http_code}' \
			-D /tmp/cfb_response_headers.txt \
			-G --data-urlencode "url=$url" \
			--max-time 120 \
			"http://localhost:8000/html")
		if [[ "$http_code" == "200" ]]; then
			html=$(cat "$response_file")
			if [[ -n "$html" ]]; then
				export FS_COOKIES
				FS_COOKIES=$(grep -i '^x-cf-bypasser-cookies:' /tmp/cfb_response_headers.txt 2>/dev/null | cut -d':' -f2- | xargs)
				local cfb_ua
				cfb_ua=$(grep -i '^x-cf-bypasser-user-agent:' /tmp/cfb_response_headers.txt 2>/dev/null | cut -d':' -f2- | xargs)
				[[ -n "$cfb_ua" ]] && user_agent="$cfb_ua"
				rm -f "$response_file" /tmp/cfb_response_headers.txt
				return 0
			fi
		else
			yellow_log "[!] CFB attempt $attempt/$max_retries: HTTP $http_code: $url"
		fi
	done
	return 1
}

_FFS_FAILED=0
_cf_get() {
	if [[ "$_FFS_FAILED" -eq 0 ]]; then
		_fs_get "$@" && return 0
		yellow_log "[!] FlareSolverr failed, falling back to CFB"
		_FFS_FAILED=1
	fi
	_cfb_get "$@"
}

cf_req() {
	local url=$1 op=$2
	if [ "$op" = "-" ]; then
		local html=""
		_cf_get "$url" || return 1
		printf '%s' "$html"
		return 0
	fi
	if [ -f "$op" ]; then return 0; fi
	local cookie_args=()
	[ -n "$FS_COOKIES" ] && cookie_args=(--header "Cookie: $FS_COOKIES")
	local dlp
	dlp="$(dirname "$op")/tmp.$(basename "$op")"
	if ! wget -nv -O "$dlp" \
		--header="User-Agent: $user_agent" \
		"${cookie_args[@]}" \
		--timeout=120 \
		"$url"; then
		rm -f "$dlp"
		epr "cf_req download failed: $url"
		return 1
	fi
	mv -f "$dlp" "$op"
}

_cf_with_req() {
	local _orig_req
	_orig_req="$(declare -f req)"
	req() { cf_req "$@"; }
	"$@"
	local rc=$?
	unset -f req
	[ -n "$_orig_req" ] && eval "$_orig_req"
	return $rc
}

get_apkmirror_cf_resp()     { _cf_with_req get_apkmirror_resp "$@"; }
get_apkmirror_cf_pkg_name() { get_apkmirror_pkg_name "$@"; }   # thuần parse, không request
get_apkmirror_cf_vers()     { _cf_with_req get_apkmirror_vers "$@"; }
dl_apkmirror_cf()           { _cf_with_req dl_apkmirror "$@"; }
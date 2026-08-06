#!/usr/bin/env bash
# =============================================================================
# cf_bypass.sh
# Cloudflare bypass được PORT NGUYÊN VẸN từ repo:
#   Revanced-And-Revanced-Extended-Non-Root (src/build/utils.sh)
#
# Logic bypass (FlareSolverr -> CFB fallback) được giữ 100% như bản gốc.
# Chỉ bổ sung phần "keo dán" để khớp interface nguồn tải của
# revanced-magisk-module (get_<src>_resp / get_<src>_pkg_name /
# get_<src>_vers / dl_<src>).
#
# Nguồn mới được đăng ký với tên: apkmirror_cf
#   -> trong config.toml dùng khóa:  apkmirror_cf-dlurl = "..."
# =============================================================================

# ------------------------------------------------------------------ deps ----
# pup: parser HTML mà logic gốc của repo1 dựa vào (repo2 dùng htmlq, nhưng để
# GIỮ NGUYÊN logic bypass repo1 ta mang luôn pup sang thay vì dịch selector).
CF_PUP="${CWD:-$(pwd)}/pup"
CF_APKEDITOR="${APKEDITOR:-}"

# user_agent: y hệt repo1 (tự dò UA Firefox mới nhất, fallback cứng nếu fail).
if [ -z "${cf_user_agent:-}" ]; then
	cf_user_agent=$(wget -qO- https://www.whatismybrowser.com/guides/the-latest-user-agent/firefox 2>/dev/null \
		| tr '\n' ' ' | sed 's#</tr>#\n#g' \
		| grep 'Firefox (Standard)' \
		| sed -n 's/.*<span class="code">\([^<]*Android[^<]*\)<\/span>.*/\1/p') || cf_user_agent=
	[ -z "$cf_user_agent" ] && cf_user_agent='Mozilla/5.0 (Android 16; Mobile; rv:146.0) Gecko/146.0 Firefox/146.0'
fi
# user_agent là biến mà các hàm _fs_get/_cfb_get bên dưới cập nhật (giữ tên gốc).
user_agent="$cf_user_agent"

cf_setup_pup() {
	if [ ! -x "$CF_PUP" ]; then
		pr "[cf] setting up pup"
		wget -q -O "${CWD:-$(pwd)}/pup.zip" \
			https://github.com/ericchiang/pup/releases/download/v0.4.0/pup_v0.4.0_linux_amd64.zip || {
			epr "[cf] failed to download pup"; return 1; }
		unzip -o "${CWD:-$(pwd)}/pup.zip" -d "${CWD:-$(pwd)}/" >/dev/null 2>&1
		chmod +x "$CF_PUP" 2>/dev/null || :
	fi
	pup="$CF_PUP"
}

# Log shims: repo1 dùng green/red/yellow_log; repo2 dùng pr/epr/wpr.
green_log()  { pr "$1"; }
red_log()    { epr "$1"; }
yellow_log() { wpr "$1"; }

# =========================== BYPASS CORE (repo1) =============================
# --- _fs_get: FlareSolverr (cổng 8191). GIỮ NGUYÊN từ repo1. -----------------
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

# --- _cfb_get: CloudflareBypassForScraping (cổng 8000). GIỮ NGUYÊN từ repo1. -
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

# --- _cf_get: điều phối FlareSolverr -> CFB. GIỮ NGUYÊN từ repo1. ------------
_FFS_FAILED=0
_cf_get() {
	if [[ "$_FFS_FAILED" -eq 0 ]]; then
		_fs_get "$@" && return 0
		yellow_log "[!] FlareSolverr failed, falling back to CFB"
		_FFS_FAILED=1
	fi
	_cfb_get "$@"
}

# --- cf_wget: tải file nhị phân dùng cookie/UA lấy từ bypass. (repo1 style) --
cf_wget() {
	local url=$1 out=$2 referer=$3
	local cookie_args=()
	[[ -n "$FS_COOKIES" ]] && cookie_args=(--header "Cookie: $FS_COOKIES")
	wget -nv -O "$out" \
		--header="User-Agent: $user_agent" \
		${referer:+--referer="$referer"} \
		"${cookie_args[@]}" \
		--timeout=120 \
		"$url" || { rm -f "$out"; return 1; }
}

# ===================== SHIMS cho interface revanced-magisk ===================
# State giữa các bước (giống biến html/FS_COOKIES của repo1).
__APKMCF_LISTURL__=""
__APKMCF_HTML__=""
__APKMCF_PKG__=""

# get_apkmirror_cf_resp <list_url>
# Nạp trang danh sách phiên bản qua bypass, lưu HTML + list_url.
get_apkmirror_cf_resp() {
	cf_setup_pup || return 1
	__APKMCF_LISTURL__="$1"
	_cf_get "$1" || return 1
	__APKMCF_HTML__="$html"
	return 0
}

# get_apkmirror_cf_pkg_name
# APKMirror uploads page nhúng package id trong thuộc tính data-* của link.
get_apkmirror_cf_pkg_name() {
	local p
	p=$(echo "$__APKMCF_HTML__" | grep -oP 'data-appcategory[^>]*' | head -1)
	# Fallback: rút từ id="...":  <a ... id=PKG" class="accent_color
	p=$(echo "$__APKMCF_HTML__" | sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' | head -1)
	if [ -z "$p" ]; then
		# Fallback cuối: lấy từ config nếu người dùng khai báo pkg_name.
		p="${__APKMCF_PKG__}"
	fi
	echo "$p"
	[ -n "$p" ]
}

# get_apkmirror_cf_vers
# Trả về danh sách version (mỗi dòng 1 version), loại beta/alpha — như repo1.
get_apkmirror_cf_vers() {
	echo "$__APKMCF_HTML__" \
		| "$pup" 'h5.appRowTitle a.fontBlack json{}' 2>/dev/null \
		| jq -r '.[] | select(.text | test("(?i)beta|alpha") | not) | .text' \
		| grep -oP '\d+(\.\d+)+' \
		| sort -Vr | uniq
}

# dl_apkmirror_cf <list_url> <version> <output> <arch> <dpi> <get_latest>
# Đây là phần lõi: tái sử dụng NGUYÊN logic get_apk() (pup + _cf_get) của repo1,
# rút gọn về đúng những bước cần cho một (version, arch, dpi) cụ thể.
dl_apkmirror_cf() {
	local list_url=$1 version=${2} output=$3 arch=$4 dpi=$5
	local base_url="https://www.apkmirror.com"
	local html="$__APKMCF_HTML__"

	if [ -f "${output}.apkm" ]; then
		merge_splits "${output}.apkm" "${output}"
		return 0
	fi
	[ "$arch" = "arm-v7a" ] && arch="armeabi-v7a"

	# 1) Tìm link trang phiên bản khớp version trên trang danh sách.
	local version_href
	version_href=$(echo "$html" | "$pup" 'h5.appRowTitle a.fontBlack json{}' 2>/dev/null | \
		jq -r --arg v "$version" '.[] | select(.text | contains($v)) | .href' | head -1)
	if [ -z "$version_href" ]; then
		# thử duyệt vài trang uploads (giữ logic phân trang của repo1)
		local page_num page_url
		for page_num in $(seq 1 10); do
			page_url="$list_url"
			[ "$page_num" -gt 1 ] && page_url="${list_url%%\?*}/page/$page_num/?${list_url#*\?}"
			_cf_get "$page_url" || return 1
			version_href=$(echo "$html" | "$pup" 'h5.appRowTitle a.fontBlack json{}' 2>/dev/null | \
				jq -r --arg v "$version" '.[] | select(.text | contains($v)) | .href' | head -1)
			[ -n "$version_href" ] && break
		done
	fi
	[ -z "$version_href" ] && { red_log "[-] apkmirror_cf: version $version not found"; return 1; }

	# 2) Mở trang phiên bản -> bảng variant.
	_cf_get "$base_url$version_href" || return 1

	local type_badge="APK" is_bundle=false
	local vtable_html rows variant_href=""
	vtable_html=$(echo "$html" | "$pup" 'div.variants-table')
	rows=$(echo "$vtable_html" | tr '\n' ' ' | sed 's/<div class="table-row/\n<div class="table-row/g')

	local dpi_fallback=("120-640dpi" "120-480dpi" "480-640dpi" "480dpi")
	local try_type filtered_rows dpi_filtered fb_dpi matched_type=""
	for try_type in APK BUNDLE; do
		filtered_rows=$(echo "$rows" | grep -iP "apkm-badge[^>]*>\s*$try_type\s*<")
		[ -n "$arch" ] && filtered_rows=$(echo "$filtered_rows" | grep -i "$arch")
		if [ -n "$dpi" ]; then
			dpi_filtered=$(echo "$filtered_rows" | grep -i "$dpi")
			if [ -z "$dpi_filtered" ]; then
				for fb_dpi in "${dpi_fallback[@]}"; do
					dpi_filtered=$(echo "$filtered_rows" | grep -i "$fb_dpi")
					[ -n "$dpi_filtered" ] && { yellow_log "[!] DPI fallback: $dpi -> $fb_dpi"; break; }
				done
			fi
			filtered_rows="$dpi_filtered"
		fi
		variant_href=$(echo "$filtered_rows" | grep -oP 'accent_color[^>]*href="\K[^"]+' | head -1)
		if [ -n "$variant_href" ]; then
			matched_type="$try_type"
			[ "$try_type" = "BUNDLE" ] && is_bundle=true
			break
		fi
	done
	[ -z "$variant_href" ] && { red_log "[-] apkmirror_cf: no variant (arch=$arch dpi=$dpi)"; return 1; }
	variant_href=$(echo "$variant_href" | sed 's/&amp;/\&/g')

	# 3) Trang variant -> nút download.
	_cf_get "$base_url$variant_href" || return 1
	local all_dl_btns dl_btn_href
	all_dl_btns=$(echo "$html" | "$pup" 'a.downloadButton attr{href}')
	if [ "$matched_type" = "BUNDLE" ]; then
		dl_btn_href=$(echo "$all_dl_btns" | grep -v 'forcebaseapk' | head -1)
	else
		dl_btn_href=$(echo "$all_dl_btns" | grep 'forcebaseapk' | head -1)
	fi
	[ -z "$dl_btn_href" ] && dl_btn_href=$(echo "$all_dl_btns" | head -1)
	[ -z "$dl_btn_href" ] && { red_log "[-] apkmirror_cf: no download button"; return 1; }
	dl_btn_href=$(echo "$dl_btn_href" | sed 's/&amp;/\&/g')

	# 4) Trang tải cuối -> link file thật.
	_cf_get "$base_url$dl_btn_href" || return 1
	local final_href
	final_href=$(echo "$html" | "$pup" 'a#download-link attr{href}' | head -1)
	[ -z "$final_href" ] && final_href=$(echo "$html" | grep -oP 'id="download-link"[^>]*href="\K[^"]+' | head -1)
	[ -z "$final_href" ] && { red_log "[-] apkmirror_cf: no final link"; return 1; }
	final_href=$(echo "$final_href" | sed 's/&amp;/\&/g')

	# 5) Tải bằng cookie/UA của bypass.
	if [ "$is_bundle" = true ]; then
		cf_wget "$base_url$final_href" "${output}.apkm" "$base_url$dl_btn_href" || return 1
		merge_splits "${output}.apkm" "$output"
	else
		cf_wget "$base_url$final_href" "${output}" "$base_url$dl_btn_href" || return 1
	fi
	green_log "[+] apkmirror_cf: downloaded $(basename "$output")"
}

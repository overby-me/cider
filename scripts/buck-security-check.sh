#!/usr/bin/env bash
# Run the Security cone inside the buck2-built Darling.
#
# Security is the largest cone the port builds that had never executed a single
# instruction: 38 static archives, 5 dylibs and a 9.3MB framework binary. Its exported
# symbols list is what pulls the archive members onto the link at all -- nothing in
# Security_obj references SSLRead, so without the list ld drops libsecurity_ssl entirely --
# which puts "it links" and "its code runs" further apart here than anywhere else.
#
# tests/buck2/guest/sec_probe.c is self-contained on purpose: a published digest and a
# certificate embedded as DER, so it needs no network, no keychain on disk and no clock
# that agrees with anybody. It walks up from the smallest thing in the cone to the largest:
#
#   CC_SHA256                       libcommonCrypto
#   SecRandomCopyBytes              Security's own entry points
#   CFDataCreate                    CoreFoundation underneath it
#   SecCertificateCreateWithData    the ASN.1 and x509 archives
#   SecCertificateCopySubjectSummary   decoding a name back out of the parsed cert
#
# Usage:  scripts/buck-security-check.sh [<scratch dir>]
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '%s\n' "$*" >&2; }

root=${1:-/tmp/darling-sec-$(id -u)}
rt="$root/rt"
prefix="$root/prefix"

command -v buck2 >/dev/null || {
	say "missing buck2 -- run inside \`nix develop\`"
	exit 2
}

say "== building the prefix and the probe =="
out=$(buck2 build //buck/prefix:darling_prefix //tests/buck2/guest:sec_probe \
	--show-output 2>/dev/null)
art=$(awk '/darling_prefix/ {print $2}' <<<"$out")
bin=$(awk '/sec_probe/ {print $2}' <<<"$out")
for f in "$art" "$bin"; do
	[ -e "$f" ] || {
		say "missing build output: $f"
		exit 1
	}
done

for p in /proc/[0-9]*; do
	ex=$(readlink "$p/exe" 2>/dev/null) || continue
	case "$ex" in "$root"/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;; esac
done

say "== materializing into $rt =="
chmod -R u+w "$rt" 2>/dev/null || true
rm -rf "$rt" "$prefix" "$prefix.workdir"
mkdir -p "$rt" "$prefix"
# `cp -a`, never `cp -aL`: the prefix installs Volumes/DarlingEmulatedDrive -> /.
cp -a "$art"/. "$rt"/
chmod -R u+w "$rt"
cp "$bin" "$rt/libexec/darling/usr/bin/sec_probe"
chmod +x "$rt/libexec/darling/usr/bin/sec_probe"

say "== running the probe inside the container =="
out=$(
	DPREFIX="$prefix" \
		DARLING_NO_LAUNCHD=1 \
		DSERVER_LIBEXEC_PATH="$rt/libexec/darling" \
		DSERVER_MLDR_PATH="$rt/libexec/darling/usr/libexec/darling/mldr" \
		timeout 200 "$rt/bin/darling" shell /usr/bin/sec_probe 2>&1
) || true

printf '%s\n' "$out" | grep "SEC_PROBE" || true

fail=0
expect() {
	case "$out" in
	*"$1"*) say "ok   $2" ;;
	*) say "FAIL $2"; fail=1 ;;
	esac
}
# Each step is asserted separately, so a regression says WHICH layer broke rather than
# that the cone stopped working.
expect "SEC_PROBE sha256=correct" "libcommonCrypto computes the published SHA-256 of abc"
expect "SEC_PROBE random rc=0 nonzero=1" "SecRandomCopyBytes returns entropy"
expect "SEC_PROBE cfdata=801" "CoreFoundation wraps the DER bytes"
expect "SEC_PROBE certificate=parsed" "SecCertificateCreateWithData parses a real certificate"
expect "SEC_PROBE subject=darling-buck2-probe" "the certificate's subject decodes back out"
expect "SEC_PROBE_DONE" "the probe ran to completion"

[ "$fail" = 0 ] && {
	say "PASS: the Security cone runs"
	exit 0
}
say "FAIL: see above"
exit 1

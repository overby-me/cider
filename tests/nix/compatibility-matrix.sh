#!/usr/bin/env bash
# tests/nix/compatibility-matrix.sh — Nix package compatibility test matrix
#
# Systematically tests building an expanding set of Nixpkgs packages inside
# Darling and tracks pass/fail rates over time.  Produces a JSON report and
# a human-readable summary.
#
# Usage:
#   ./tests/nix/compatibility-matrix.sh                    # run all tiers
#   ./tests/nix/compatibility-matrix.sh --tier 1           # only tier 1
#   ./tests/nix/compatibility-matrix.sh --tier 1,2         # tiers 1 and 2
#   ./tests/nix/compatibility-matrix.sh --packages hello,jq  # specific packages
#   ./tests/nix/compatibility-matrix.sh --json             # JSON-only output
#   ./tests/nix/compatibility-matrix.sh --output report.json  # write to file
#   ./tests/nix/compatibility-matrix.sh --timeout 600      # per-package timeout
#   ./tests/nix/compatibility-matrix.sh --compare prev.json  # compare with previous
#   ./tests/nix/compatibility-matrix.sh --help
#
# Environment variables:
#   CIDER_NIX            Path to the cider-nix wrapper (default: auto-detect)
#                        (DARLING_NIX is still honoured)
#   DARLING              Path to the cider binary (default: cider)
#   DPREFIX              Darling prefix path (default: auto)
#   NIX_SYSTEM           Target system (default: x86_64-darwin)
#   COMPAT_NIXPKGS       Nixpkgs expression (default: <nixpkgs>)
#   COMPAT_TIMEOUT       Per-package build timeout in seconds (default: 300)
#   COMPAT_SUBSTITUTERS  Extra substituters (default: https://cache.nixos.org)
#
# The script is designed to be run periodically (e.g., in CI) and its JSON
# output can be compared across runs to detect regressions and progress.
#
# See: PLAN.md (Tasks 6.5, 7.6)

set -euo pipefail

# ── Colour output ────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" RESET=""
fi

# ── Package tiers ────────────────────────────────────────────────────

# Tier 1 — Must pass: simple packages, mostly fetched from binary cache
TIER1_PACKAGES=(
    hello
    which
    yes
)

# Tier 2 — Should pass: simple C programs, moderate complexity
TIER2_PACKAGES=(
    tree
    jq
    gnugrep
    gnused
    gawk
    coreutils
    bash
)

# Tier 3 — Stretch: complex builds, many dependencies
TIER3_PACKAGES=(
    curl
    git
    openssl
    pkg-config
    cmake
    python3
    nodejs
)

# Tier 4 — Aspirational: very complex builds (expected to fail initially)
TIER4_PACKAGES=(
    go
    rustc
    llvm
    ghc
)

# ── Configuration defaults ───────────────────────────────────────────

CIDER_NIX="${CIDER_NIX:-${DARLING_NIX:-}}"
DARLING="${CIDER:-${DARLING:-cider}}"
NIX_SYSTEM="${NIX_SYSTEM:-x86_64-darwin}"
COMPAT_NIXPKGS="${COMPAT_NIXPKGS:-<nixpkgs>}"
COMPAT_TIMEOUT="${COMPAT_TIMEOUT:-300}"
COMPAT_SUBSTITUTERS="${COMPAT_SUBSTITUTERS:-https://cache.nixos.org}"

# CLI state
SELECTED_TIERS=""
SELECTED_PACKAGES=""
JSON_ONLY=0
OUTPUT_FILE=""
COMPARE_FILE=""
VERBOSE=0
DRY_RUN=0

# ── Helpers ──────────────────────────────────────────────────────────

log() {
    if [[ "$JSON_ONLY" -eq 0 ]]; then
        echo "$*" >&2
    fi
}

debug() {
    if [[ "$VERBOSE" -ge 1 && "$JSON_ONLY" -eq 0 ]]; then
        echo "${CYAN}[debug]${RESET} $*" >&2
    fi
}

die() {
    echo "${RED}ERROR:${RESET} $*" >&2
    exit 1
}

# Auto-detect the cider-nix wrapper script
find_cider_nix() {
    if [[ -n "$CIDER_NIX" ]]; then
        echo "$CIDER_NIX"
        return
    fi

    # Look relative to this script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root
    repo_root="$(cd "$script_dir/../.." && pwd)"

    if [[ -x "$repo_root/scripts/cider-nix" ]]; then
        echo "$repo_root/scripts/cider-nix"
        return
    fi

    # Fallback: use cider directly
    echo ""
}

# Run a Nix command inside Darling
nix_in_cider() {
    local cider_nix
    cider_nix="$(find_cider_nix)"

    if [[ -n "$cider_nix" ]]; then
        "$cider_nix" "$@"
    else
        local prefix_args=()
        if [[ -n "${DPREFIX:-}" ]]; then
            prefix_args=(--prefix "$DPREFIX")
        fi
        "$DARLING" "${prefix_args[@]}" shell bash -lc '
            for p in \
                /Users/root/.nix-profile/etc/profile.d/nix.sh \
                /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
                /nix/var/nix/profiles/default/etc/profile.d/nix.sh; do
                if [ -e "$p" ]; then . "$p"; break; fi
            done
            exec "$@"
        ' -- "$@"
    fi
}

# Get packages for a specific tier
get_tier_packages() {
    local tier="$1"
    case "$tier" in
        1) echo "${TIER1_PACKAGES[@]}" ;;
        2) echo "${TIER2_PACKAGES[@]}" ;;
        3) echo "${TIER3_PACKAGES[@]}" ;;
        4) echo "${TIER4_PACKAGES[@]}" ;;
        *) die "Unknown tier: $tier" ;;
    esac
}

# Get the tier for a given package
get_package_tier() {
    local pkg="$1"
    local p
    for p in "${TIER1_PACKAGES[@]}"; do [[ "$p" == "$pkg" ]] && echo 1 && return; done
    for p in "${TIER2_PACKAGES[@]}"; do [[ "$p" == "$pkg" ]] && echo 2 && return; done
    for p in "${TIER3_PACKAGES[@]}"; do [[ "$p" == "$pkg" ]] && echo 3 && return; done
    for p in "${TIER4_PACKAGES[@]}"; do [[ "$p" == "$pkg" ]] && echo 4 && return; done
    echo 0  # Unknown tier
}

# JSON-escape a string
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    echo "$s"
}

# ── Build test logic ─────────────────────────────────────────────────

# Test building a single package.
# Outputs a JSON object on stdout.
test_package() {
    local pkg="$1"
    local tier
    tier=$(get_package_tier "$pkg")

    local status="unknown"
    local duration=0
    local output_path=""
    local error_msg=""
    local from_cache="unknown"
    local log_file
    log_file=$(mktemp "/tmp/compat-${pkg}-XXXXXX.log")

    log "  ${BOLD}Testing:${RESET} ${CYAN}${pkg}${RESET} (tier $tier) ..."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        status="skipped"
        duration=0
        error_msg="dry run"
    else
        local start_time
        start_time=$(date +%s)

        # Attempt the build with a timeout
        if timeout "$COMPAT_TIMEOUT" \
            nix_in_cider nix-build "$COMPAT_NIXPKGS" \
                -A "$pkg" \
                --system "$NIX_SYSTEM" \
                --no-out-link \
                --option substituters "$COMPAT_SUBSTITUTERS" \
                >"$log_file" 2>&1; then
            status="pass"
            output_path=$(tail -1 "$log_file" | grep -o '/nix/store/[^ ]*' | head -1) || true
            # Check if it was a cache hit (substituted) or built locally
            if grep -q "copying path.*from.*cache" "$log_file" 2>/dev/null; then
                from_cache="yes"
            elif grep -q "building.*\.drv" "$log_file" 2>/dev/null; then
                from_cache="no"
            fi
        else
            local rc=$?
            status="fail"
            if [[ "$rc" -eq 124 ]]; then
                error_msg="timeout after ${COMPAT_TIMEOUT}s"
            else
                # Extract the first meaningful error line
                error_msg=$(grep -E '(error:|FATAL|signal [0-9]+|Unimplemented syscall|killed|cannot)' "$log_file" | head -3 | tr '\n' ' ') || true
                if [[ -z "$error_msg" ]]; then
                    error_msg="exit code $rc (see log)"
                fi
            fi
        fi

        local end_time
        end_time=$(date +%s)
        duration=$((end_time - start_time))
    fi

    # Log result with colour
    case "$status" in
        pass)
            local cache_note=""
            [[ "$from_cache" == "yes" ]] && cache_note=" (from cache)"
            log "    ${GREEN}✓ PASS${RESET} (${duration}s)${cache_note}"
            ;;
        fail)
            log "    ${RED}✗ FAIL${RESET} (${duration}s): $error_msg"
            if [[ "$VERBOSE" -ge 1 ]]; then
                log "    Log: $log_file"
            fi
            ;;
        skipped)
            log "    ${YELLOW}⊘ SKIP${RESET}"
            ;;
    esac

    # Clean up log file on success (keep on failure for debugging)
    if [[ "$status" == "pass" || "$status" == "skipped" ]]; then
        rm -f "$log_file"
        log_file=""
    fi

    # Output JSON object
    cat << ENDJSON
    {
      "package": "$(json_escape "$pkg")",
      "tier": $tier,
      "status": "$(json_escape "$status")",
      "duration": $duration,
      "from_cache": "$(json_escape "$from_cache")",
      "output_path": "$(json_escape "${output_path:-}")",
      "error": "$(json_escape "${error_msg:-}")",
      "log_file": "$(json_escape "${log_file:-}")"
    }
ENDJSON
}

# ── Comparison logic ─────────────────────────────────────────────────

# Compare current results with a previous run's JSON report
compare_results() {
    local current_file="$1"
    local previous_file="$2"

    if [[ ! -f "$previous_file" ]]; then
        log "${YELLOW}WARNING:${RESET} Previous report not found: $previous_file"
        return
    fi

    log ""
    log "${BOLD}═══ Comparison with previous run ═══${RESET}"

    # Extract package statuses from both files using grep/awk
    # (avoiding jq dependency)
    local prev_results curr_results
    prev_results=$(grep -oP '"package":\s*"[^"]*"|"status":\s*"[^"]*"' "$previous_file" | paste - - | sed 's/"package": "//;s/".*"status": "/\t/;s/"//g')
    curr_results=$(grep -oP '"package":\s*"[^"]*"|"status":\s*"[^"]*"' "$current_file" | paste - - | sed 's/"package": "//;s/".*"status": "/\t/;s/"//g')

    local regressions=0
    local improvements=0

    while IFS=$'\t' read -r pkg curr_status; do
        local prev_status
        prev_status=$(echo "$prev_results" | awk -F'\t' -v p="$pkg" '$1 == p { print $2 }') || true

        if [[ -z "$prev_status" ]]; then
            log "  ${CYAN}NEW${RESET}        $pkg: $curr_status"
        elif [[ "$prev_status" == "pass" && "$curr_status" == "fail" ]]; then
            log "  ${RED}REGRESSION${RESET} $pkg: pass → fail"
            regressions=$((regressions + 1))
        elif [[ "$prev_status" == "fail" && "$curr_status" == "pass" ]]; then
            log "  ${GREEN}FIXED${RESET}      $pkg: fail → pass"
            improvements=$((improvements + 1))
        fi
    done <<< "$curr_results"

    log ""
    if [[ "$regressions" -gt 0 ]]; then
        log "  ${RED}${BOLD}$regressions regression(s) detected!${RESET}"
    fi
    if [[ "$improvements" -gt 0 ]]; then
        log "  ${GREEN}${BOLD}$improvements improvement(s) detected!${RESET}"
    fi
    if [[ "$regressions" -eq 0 && "$improvements" -eq 0 ]]; then
        log "  No changes detected."
    fi
}

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat >&2 << 'EOF'
Usage: compatibility-matrix.sh [OPTIONS]

Test building Nixpkgs packages inside Darling and report results.

Options:
  --tier TIERS         Comma-separated tier numbers to test (default: all)
                       Tiers: 1=must-pass, 2=should-pass, 3=stretch, 4=aspirational
  --packages PKGS      Comma-separated package names to test (overrides --tier)
  --timeout SECS       Per-package build timeout (default: 300)
  --output FILE        Write JSON report to FILE (default: stdout + stderr)
  --json               Suppress human-readable output; only emit JSON to stdout
  --compare FILE       Compare results with a previous JSON report
  --verbose, -v        Show debug output and preserve failure logs
  --dry-run            List packages that would be tested without building
  --list               List all packages and their tiers, then exit
  --help, -h           Show this help

Environment:
  CIDER_NIX            Path to cider-nix wrapper (auto-detected)
                       (DARLING_NIX is still honoured)
  DARLING              Path to cider binary (default: cider)
  DPREFIX              Darling prefix path (default: auto)
  NIX_SYSTEM           Target system (default: x86_64-darwin)
  COMPAT_NIXPKGS       Nixpkgs expression (default: <nixpkgs>)
  COMPAT_TIMEOUT       Per-package timeout (default: 300)
  COMPAT_SUBSTITUTERS  Binary cache URL (default: https://cache.nixos.org)

Examples:
  # Test tier 1 packages (should be quick — mostly binary substitution)
  ./tests/nix/compatibility-matrix.sh --tier 1

  # Test specific packages with verbose output
  ./tests/nix/compatibility-matrix.sh --packages hello,jq -v

  # Full run with JSON report and comparison
  ./tests/nix/compatibility-matrix.sh --output today.json --compare yesterday.json

  # CI mode: JSON only, fail on regressions
  ./tests/nix/compatibility-matrix.sh --json --tier 1,2

See: PLAN.md (Task 6.5)
EOF
}

# ── CLI parsing ──────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tier)
                SELECTED_TIERS="$2"
                shift 2
                ;;
            --packages)
                SELECTED_PACKAGES="$2"
                shift 2
                ;;
            --timeout)
                COMPAT_TIMEOUT="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --json)
                JSON_ONLY=1
                shift
                ;;
            --compare)
                COMPARE_FILE="$2"
                shift 2
                ;;
            --verbose | -v)
                VERBOSE=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --list)
                echo "Tier 1 (must pass):    ${TIER1_PACKAGES[*]}"
                echo "Tier 2 (should pass):  ${TIER2_PACKAGES[*]}"
                echo "Tier 3 (stretch):      ${TIER3_PACKAGES[*]}"
                echo "Tier 4 (aspirational): ${TIER4_PACKAGES[*]}"
                exit 0
                ;;
            --help | -h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1 (try --help)"
                ;;
        esac
    done
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    # Build the list of packages to test
    local packages=()

    if [[ -n "$SELECTED_PACKAGES" ]]; then
        IFS=',' read -ra packages <<< "$SELECTED_PACKAGES"
    elif [[ -n "$SELECTED_TIERS" ]]; then
        IFS=',' read -ra tiers <<< "$SELECTED_TIERS"
        for tier in "${tiers[@]}"; do
            local tier_pkgs
            tier_pkgs=$(get_tier_packages "$tier")
            # shellcheck disable=SC2206
            packages+=($tier_pkgs)
        done
    else
        # All tiers
        packages+=("${TIER1_PACKAGES[@]}")
        packages+=("${TIER2_PACKAGES[@]}")
        packages+=("${TIER3_PACKAGES[@]}")
        packages+=("${TIER4_PACKAGES[@]}")
    fi

    if [[ ${#packages[@]} -eq 0 ]]; then
        die "No packages selected"
    fi

    # Quick sanity check (unless dry run)
    if [[ "$DRY_RUN" -eq 0 ]]; then
        debug "Verifying Darling is functional ..."
        if ! "$DARLING" shell true &>/dev/null; then
            die "Cannot run 'cider shell true' — is Darling installed and the prefix initialised?"
        fi
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local hostname_str
    hostname_str=$(hostname 2>/dev/null || echo "unknown")

    log ""
    log "${BOLD}═══ Nix Compatibility Test Matrix ═══${RESET}"
    log "  Date:      $timestamp"
    log "  System:    $NIX_SYSTEM"
    log "  Packages:  ${#packages[@]}"
    log "  Timeout:   ${COMPAT_TIMEOUT}s per package"
    log ""

    # Collect JSON results
    local results_json=""
    local total=0
    local passed=0
    local failed=0
    local skipped=0

    for pkg in "${packages[@]}"; do
        local result
        result=$(test_package "$pkg")
        total=$((total + 1))

        # Extract status for counters
        local status
        status=$(echo "$result" | grep -o '"status": *"[^"]*"' | head -1 | cut -d'"' -f4)
        case "$status" in
            pass)    passed=$((passed + 1)) ;;
            fail)    failed=$((failed + 1)) ;;
            skipped) skipped=$((skipped + 1)) ;;
        esac

        # Accumulate JSON
        if [[ -n "$results_json" ]]; then
            results_json="${results_json},
${result}"
        else
            results_json="$result"
        fi
    done

    # Assemble the full JSON report
    local full_json
    full_json=$(cat << ENDJSON
{
  "metadata": {
    "timestamp": "$timestamp",
    "hostname": "$(json_escape "$hostname_str")",
    "system": "$(json_escape "$NIX_SYSTEM")",
    "nixpkgs": "$(json_escape "$COMPAT_NIXPKGS")",
    "timeout_per_package": $COMPAT_TIMEOUT,
    "cider": "$(json_escape "$DARLING")"
  },
  "summary": {
    "total": $total,
    "passed": $passed,
    "failed": $failed,
    "skipped": $skipped,
    "pass_rate": "$(awk "BEGIN { if ($total - $skipped > 0) printf \"%.1f\", $passed / ($total - $skipped) * 100; else print \"0.0\" }")%"
  },
  "results": [
$results_json
  ]
}
ENDJSON
)

    # Output the report
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$full_json" > "$OUTPUT_FILE"
        log ""
        log "JSON report written to: $OUTPUT_FILE"
    fi

    if [[ "$JSON_ONLY" -eq 1 ]]; then
        echo "$full_json"
    fi

    # Summary
    log ""
    log "${BOLD}═══ Summary ═══${RESET}"
    log "  Total:   $total"
    log "  ${GREEN}Passed:  $passed${RESET}"
    log "  ${RED}Failed:  $failed${RESET}"
    if [[ "$skipped" -gt 0 ]]; then
        log "  ${YELLOW}Skipped: $skipped${RESET}"
    fi

    local tested=$((total - skipped))
    if [[ "$tested" -gt 0 ]]; then
        local rate
        rate=$(awk "BEGIN { printf \"%.1f\", $passed / $tested * 100 }")
        log "  Pass rate: ${BOLD}${rate}%${RESET} ($passed/$tested)"
    fi

    # Comparison
    local report_file="${OUTPUT_FILE:-}"
    if [[ -n "$COMPARE_FILE" ]]; then
        if [[ -z "$report_file" ]]; then
            # Write to a temp file for comparison
            report_file=$(mktemp /tmp/compat-current-XXXXXX.json)
            echo "$full_json" > "$report_file"
        fi
        compare_results "$report_file" "$COMPARE_FILE"
        if [[ -z "$OUTPUT_FILE" ]]; then
            rm -f "$report_file"
        fi
    fi

    log ""

    # Exit with failure if any tier-1 package failed (for CI use)
    if [[ "$failed" -gt 0 ]]; then
        local tier1_failures=0
        for pkg in "${TIER1_PACKAGES[@]}"; do
            if echo "$full_json" | grep -q "\"package\": \"$pkg\"" && \
               echo "$full_json" | grep -A5 "\"package\": \"$pkg\"" | grep -q '"status": "fail"'; then
                tier1_failures=$((tier1_failures + 1))
            fi
        done
        if [[ "$tier1_failures" -gt 0 ]]; then
            log "${RED}${BOLD}$tier1_failures tier-1 package(s) failed — this is a critical regression!${RESET}"
            exit 2
        fi
        exit 1
    fi

    exit 0
}

main "$@"

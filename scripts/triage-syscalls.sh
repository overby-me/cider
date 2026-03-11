#!/usr/bin/env bash
# triage-syscalls.sh — Automated syscall triage for Darling + Nix
#
# This script runs various Nix operations inside a Darling prefix and
# captures "Unimplemented syscall" messages, ENOSYS errors, and other
# indicators of missing kernel functionality. The output is a table
# suitable for pasting into plan/syscall-triage.md.
#
# Usage:
#   ./scripts/triage-syscalls.sh [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix (default: ~/.darling or $DPREFIX)
#   --output <file>       Write results to file (default: stdout)
#   --strace              Also run strace on darlingserver (requires root)
#   --xtrace              Enable DARLING_XTRACE for detailed Darwin tracing
#   --operations <list>   Comma-separated list of operations to test
#                         (default: all). Available: version,eval,store,
#                         touch,mv,curl,install,build,channel
#   --timeout <secs>      Timeout per operation (default: 60)
#   --help                Show this help
#
# Output:
#   A Markdown-formatted table of discovered syscalls, with columns:
#     Syscall # | Caller | Operation | Message | Count
#
# Prerequisites:
#   - Darling must be installed and `darling shell echo ok` must work
#   - For Nix-related tests, Nix must be installed in the prefix
#     (run scripts/install-nix-in-darling.sh first)
#
# See: plan/03-phase1-syscalls.md (Task 1.7)
#      plan/syscall-triage.md

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────

DARLING_PREFIX="${DPREFIX:-$HOME/.darling}"
OUTPUT_FILE=""
USE_STRACE=0
USE_XTRACE=0
OPERATIONS="version,eval,store,touch,mv,curl,build"
TIMEOUT=60
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Temp directory for logs
TRIAGE_TMP=""

# Known syscall number → name mapping (macOS/XNU BSD syscalls)
# Source: src/external/xnu/bsd/kern/syscalls.master
# This covers the most commonly-seen unimplemented syscalls.
declare -A SYSCALL_NAMES=(
    [1]="exit"
    [2]="fork"
    [3]="read"
    [4]="write"
    [5]="open"
    [6]="close"
    [7]="wait4"
    [9]="link"
    [10]="unlink"
    [12]="chdir"
    [15]="chmod"
    [16]="chown"
    [20]="getpid"
    [23]="setuid"
    [24]="getuid"
    [25]="geteuid"
    [27]="recvmsg"
    [28]="sendmsg"
    [29]="recvfrom"
    [30]="accept"
    [33]="access"
    [36]="sync"
    [37]="kill"
    [39]="getppid"
    [41]="dup"
    [42]="pipe"
    [43]="getegid"
    [46]="sigaction"
    [47]="getgid"
    [48]="sigprocmask"
    [49]="getlogin"
    [50]="setlogin"
    [51]="acct"
    [53]="sigaltstack"
    [54]="ioctl"
    [56]="revoke"
    [57]="symlink"
    [58]="readlink"
    [59]="execve"
    [60]="umask"
    [61]="chroot"
    [65]="msync"
    [66]="vfork"
    [73]="munmap"
    [74]="mprotect"
    [75]="madvise"
    [78]="mincore"
    [79]="getgroups"
    [80]="setgroups"
    [82]="setpgid"
    [83]="setitimer"
    [85]="swapon"
    [86]="getitimer"
    [89]="getdtablesize"
    [90]="dup2"
    [92]="fcntl"
    [93]="select"
    [95]="fsync"
    [96]="setpriority"
    [97]="socket"
    [98]="connect"
    [100]="getpriority"
    [104]="bind"
    [105]="setsockopt"
    [106]="listen"
    [111]="sigsuspend"
    [116]="gettimeofday"
    [117]="getrusage"
    [118]="getsockopt"
    [120]="readv"
    [121]="writev"
    [122]="settimeofday"
    [123]="fchown"
    [124]="fchmod"
    [128]="rename"
    [131]="flock"
    [132]="mkfifo"
    [133]="sendto"
    [134]="shutdown"
    [135]="socketpair"
    [136]="mkdir"
    [137]="rmdir"
    [138]="utimes"
    [139]="futimes"
    [140]="adjtime"
    [142]="gethostuuid"
    [147]="setsid"
    [151]="getpgid"
    [152]="setprivexec"
    [153]="pread"
    [154]="pwrite"
    [157]="statfs"
    [158]="fstatfs"
    [159]="unmount"
    [165]="mount"
    [167]="csops"
    [169]="csops_audittoken"
    [170]="fdatasync"
    [173]="waitid"
    [180]="kdebug_trace64"
    [181]="kdebug_trace"
    [182]="kdebug_typefilter"
    [183]="setgid"
    [184]="setegid"
    [185]="seteuid"
    [187]="stat"
    [188]="fstat"
    [189]="lstat"
    [190]="pathconf"
    [191]="fpathconf"
    [194]="getrlimit"
    [195]="setrlimit"
    [196]="getdirentries"
    [197]="mmap"
    [199]="lseek"
    [200]="truncate"
    [201]="ftruncate"
    [202]="sysctl"
    [203]="mlock"
    [204]="munlock"
    [205]="undelete"
    [216]="mkcomplex"
    [220]="getattrlist"
    [221]="setattrlist"
    [222]="getdirentriesattr"
    [223]="exchangedata"
    [225]="searchfs"
    [226]="delete"
    [227]="copyfile"
    [228]="fgetattrlist"
    [229]="fsetattrlist"
    [230]="poll"
    [233]="getxattr"
    [234]="fgetxattr"
    [235]="setxattr"
    [236]="fsetxattr"
    [237]="removexattr"
    [238]="fremovexattr"
    [239]="listxattr"
    [240]="flistxattr"
    [241]="fsctl"
    [242]="initgroups"
    [243]="posix_spawn"
    [244]="ffsctl"
    [247]="nfsclnt"
    [248]="fhopen"
    [250]="minherit"
    [266]="shm_open"
    [267]="shm_unlink"
    [268]="sem_open"
    [269]="sem_close"
    [270]="sem_unlink"
    [271]="sem_wait"
    [272]="sem_trywait"
    [273]="sem_post"
    [274]="sysctlbyname"
    [277]="open_extended"
    [278]="umask_extended"
    [279]="stat_extended"
    [280]="lstat_extended"
    [281]="fstat_extended"
    [282]="chmod_extended"
    [283]="fchmod_extended"
    [284]="access_extended"
    [285]="settid"
    [286]="gettid"
    [288]="kqueue"
    [289]="kevent"
    [296]="mlockall"
    [297]="munlockall"
    [301]="issetugid"
    [302]="__pthread_kill"
    [303]="__pthread_sigmask"
    [305]="__disable_threadsignal"
    [310]="__semwait_signal"
    [311]="proc_info"
    [322]="getsid"
    [324]="pread_nocancel"
    [325]="pwrite_nocancel"
    [327]="aio_suspend"
    [336]="proc_rlimit_control"
    [338]="iopolicysys"
    [339]="process_policy"
    [340]="mlockall"
    [341]="munlockall"
    [343]="issetugid"
    [344]="__pthread_chdir"
    [345]="__pthread_fchdir"
    [346]="audit"
    [347]="auditon"
    [350]="getaudit_addr"
    [351]="setaudit_addr"
    [357]="getentropy"
    [360]="getattrlistbulk"
    [361]="clonefileat"
    [362]="openat"
    [363]="openat_nocancel"
    [364]="renameat"
    [366]="faccessat"
    [367]="fchmodat"
    [368]="fchownat"
    [369]="fstatat"
    [370]="fstatat64"
    [371]="linkat"
    [372]="unlinkat"
    [373]="readlinkat"
    [374]="symlinkat"
    [375]="mkdirat"
    [376]="getattrlistat"
    [377]="proc_trace_log"
    [378]="bsdthread_ctl"
    [380]="openbyid_np"
    [381]="recvmsg_x"
    [382]="sendmsg_x"
    [384]="guarded_open_np"
    [385]="guarded_close_np"
    [386]="guarded_kqueue_np"
    [387]="change_fdguard_np"
    [388]="usrctl"
    [389]="proc_rlimit_control"
    [394]="coalition"
    [395]="coalition_info"
    [396]="necp_match_policy"
    [397]="getattrlistbulk"
    [398]="clonefileat"
    [399]="openat"
    [400]="openat_nocancel"
    [401]="renameat"
    [403]="faccessat"
    [404]="fchmodat"
    [405]="fchownat"
    [406]="fstatat"
    [407]="fstatat64"
    [408]="linkat"
    [409]="unlinkat"
    [410]="readlinkat"
    [411]="symlinkat"
    [412]="mkdirat"
    [413]="getattrlistat"
    [414]="proc_trace_log"
    [415]="bsdthread_ctl"
    [417]="openbyid_np"
    [418]="recvmsg_x"
    [419]="sendmsg_x"
    [420]="thread_selfusage"
    [421]="csrctl"
    [422]="guarded_open_dprotected_np"
    [423]="guarded_write_np"
    [424]="guarded_pwrite_np"
    [425]="guarded_writev_np"
    [426]="renameatx_np"
    [427]="mremap_encrypted"
    [428]="netagent_trigger"
    [429]="stack_snapshot_with_config"
    [430]="microstackshot"
    [431]="grab_pgo_data"
    [432]="persona"
    [438]="fs_snapshot"
    [441]="terminate_with_payload"
    [442]="abort_with_payload"
    [443]="necp_session_open"
    [444]="necp_session_action"
    [449]="fclonefileat"
    [450]="fs_snapshot"
    [452]="terminate_with_payload"
    [453]="abort_with_payload"
    [462]="clonefile"
    [463]="close_nocancel"
    [464]="accept_nocancel"
    [468]="msync_nocancel"
    [469]="fcntl_nocancel"
    [470]="select_nocancel"
    [471]="fsgetpath"
    [473]="pselect"
    [474]="pselect_nocancel"
    [475]="read_nocancel"
    [476]="write_nocancel"
    [477]="open_dprotected_np"
    [480]="kevent_qos"
    [481]="kevent_id"
    [482]="__mac_execve"
    [483]="__mac_syscall"
    [484]="__mac_get_file"
    [485]="__mac_set_file"
    [486]="__mac_get_link"
    [487]="__mac_set_link"
    [488]="renameatx_np"
    [489]="setxattr"
    [500]="getentropy"
    [515]="ulock_wait"
    [516]="ulock_wake"
    [517]="fclonefileat"
    [518]="fs_snapshot"
    [519]="terminate_with_payload"
    [520]="abort_with_payload"
)

# ── Colors ──────────────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

# ── Helpers ─────────────────────────────────────────────────────────────────

log()   { echo -e "${GREEN}[triage]${RESET} $*" >&2; }
warn()  { echo -e "${YELLOW}[triage] WARNING:${RESET} $*" >&2; }
err()   { echo -e "${RED}[triage] ERROR:${RESET} $*" >&2; }
debug() { echo -e "${DIM}[triage] $*${RESET}" >&2; }
fatal() { err "$@"; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^# See:/p' "$0" | sed 's/^# \?//'
    exit 0
}

# Run a command inside the Darling prefix, capturing all output
dsh() {
    local logfile="$1"
    shift
    timeout "$TIMEOUT" darling shell "$@" >"$logfile" 2>&1 || true
}

# Run a command inside the Darling prefix with bash -lc
dsh_bash() {
    local logfile="$1"
    shift
    timeout "$TIMEOUT" darling shell bash -lc "$*" >"$logfile" 2>&1 || true
}

# Run with DARLING_XTRACE if requested
dsh_traced() {
    local logfile="$1"
    shift
    local env_args=()
    if [ "$USE_XTRACE" -eq 1 ]; then
        env_args=(env DARLING_XTRACE=1)
    fi
    timeout "$TIMEOUT" "${env_args[@]}" darling shell "$@" >"$logfile" 2>&1 || true
}

dsh_bash_traced() {
    local logfile="$1"
    shift
    local env_args=()
    if [ "$USE_XTRACE" -eq 1 ]; then
        env_args=(env DARLING_XTRACE=1)
    fi
    timeout "$TIMEOUT" "${env_args[@]}" darling shell bash -lc "$*" >"$logfile" 2>&1 || true
}

# Resolve a syscall number to its name
syscall_name() {
    local num="$1"
    if [[ -v "SYSCALL_NAMES[$num]" ]]; then
        echo "${SYSCALL_NAMES[$num]}"
    else
        echo "unknown_$num"
    fi
}

# ── Argument Parsing ────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            DARLING_PREFIX="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --strace)
            USE_STRACE=1
            shift
            ;;
        --xtrace)
            USE_XTRACE=1
            shift
            ;;
        --operations)
            OPERATIONS="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            fatal "Unknown option: $1 (try --help)"
            ;;
    esac
done

# ── Setup ───────────────────────────────────────────────────────────────────

TRIAGE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/darling-triage.XXXXXX")
cleanup() {
    if [ -n "$TRIAGE_TMP" ] && [ -d "$TRIAGE_TMP" ]; then
        rm -rf "$TRIAGE_TMP"
    fi
}
trap cleanup EXIT

log "${BOLD}Darling Syscall Triage${RESET}"
log "Prefix:     $DARLING_PREFIX"
log "Operations: $OPERATIONS"
log "Timeout:    ${TIMEOUT}s per operation"
log "XTrace:     $([ "$USE_XTRACE" -eq 1 ] && echo "enabled" || echo "disabled")"
log "Strace:     $([ "$USE_STRACE" -eq 1 ] && echo "enabled" || echo "disabled")"
log "Temp dir:   $TRIAGE_TMP"
echo "" >&2

# ── Preflight ───────────────────────────────────────────────────────────────

if ! command -v darling &>/dev/null; then
    fatal "darling not found in PATH. Build it first with: nix build .#darling"
fi

log "Checking darling shell..."
if ! timeout 30 darling shell echo "ok" &>/dev/null; then
    fatal "darling shell is not functional. Try: darling shell echo ok"
fi
log "  darling shell: ${GREEN}OK${RESET}"

# Check if Nix is available
HAS_NIX=0
if timeout 15 darling shell bash -lc 'command -v nix' &>/dev/null; then
    HAS_NIX=1
    log "  Nix in prefix: ${GREEN}found${RESET}"
else
    warn "Nix not found in prefix. Nix-specific operations will be skipped."
    warn "Run scripts/install-nix-in-darling.sh first for full triage."
fi

echo "" >&2

# ── Strace setup ────────────────────────────────────────────────────────────

STRACE_PID=""
STRACE_LOG=""

start_strace() {
    if [ "$USE_STRACE" -eq 0 ]; then
        return
    fi

    local server_pid
    server_pid=$(pidof darlingserver 2>/dev/null || true)
    if [ -z "$server_pid" ]; then
        warn "darlingserver not running; cannot attach strace"
        return
    fi

    STRACE_LOG="$TRIAGE_TMP/strace.log"
    strace -f -p "$server_pid" -e trace=all -o "$STRACE_LOG" &
    STRACE_PID=$!
    sleep 1
    debug "strace attached to darlingserver (pid=$server_pid)"
}

stop_strace() {
    if [ -n "$STRACE_PID" ]; then
        kill "$STRACE_PID" 2>/dev/null || true
        wait "$STRACE_PID" 2>/dev/null || true
        STRACE_PID=""
    fi
}

# ── Operations ──────────────────────────────────────────────────────────────

# Each operation function takes a log directory and produces a log file
# named <operation>.log inside that directory.

op_version() {
    local logdir="$1"

    log "  Testing: ${BLUE}darling shell echo ok${RESET}"
    dsh_traced "$logdir/echo.log" echo "hello from darling"

    log "  Testing: ${BLUE}sw_vers${RESET}"
    dsh_traced "$logdir/sw_vers.log" sw_vers

    log "  Testing: ${BLUE}uname -a${RESET}"
    dsh_traced "$logdir/uname.log" uname -a

    if [ "$HAS_NIX" -eq 1 ]; then
        log "  Testing: ${BLUE}nix --version${RESET}"
        dsh_bash_traced "$logdir/nix_version.log" "nix --version"

        log "  Testing: ${BLUE}nix-env --version${RESET}"
        dsh_bash_traced "$logdir/nix_env_version.log" "nix-env --version"

        log "  Testing: ${BLUE}nix-store --version${RESET}"
        dsh_bash_traced "$logdir/nix_store_version.log" "nix-store --version"
    fi
}

op_eval() {
    local logdir="$1"

    if [ "$HAS_NIX" -eq 0 ]; then
        warn "  Skipping eval tests (Nix not installed)"
        return
    fi

    log "  Testing: ${BLUE}nix-instantiate --eval -E '1 + 1'${RESET}"
    dsh_bash_traced "$logdir/eval_simple.log" "nix-instantiate --eval -E '1 + 1'"

    log "  Testing: ${BLUE}nix eval --expr '1 + 1'${RESET}"
    dsh_bash_traced "$logdir/eval_nix3.log" "nix eval --expr '1 + 1'"

    log "  Testing: ${BLUE}builtins.currentSystem${RESET}"
    dsh_bash_traced "$logdir/eval_system.log" "nix eval --expr 'builtins.currentSystem'"

    log "  Testing: ${BLUE}nix eval (complex expression)${RESET}"
    dsh_bash_traced "$logdir/eval_complex.log" \
        "nix eval --expr 'let f = x: if x <= 1 then 1 else x * f (x - 1); in f 10'"

    log "  Testing: ${BLUE}nix eval (import)${RESET}"
    dsh_bash_traced "$logdir/eval_import.log" \
        "nix eval --expr 'builtins.length (builtins.attrNames builtins)'"
}

op_store() {
    local logdir="$1"

    if [ "$HAS_NIX" -eq 0 ]; then
        warn "  Skipping store tests (Nix not installed)"
        return
    fi

    log "  Testing: ${BLUE}nix-store --verify${RESET}"
    dsh_bash_traced "$logdir/store_verify.log" "nix-store --verify --no-build 2>&1 || nix-store --verify"

    log "  Testing: ${BLUE}nix-store --dump-db${RESET}"
    dsh_bash_traced "$logdir/store_dump_db.log" "nix-store --dump-db | head -50"

    log "  Testing: ${BLUE}nix-store --gc --print-dead${RESET}"
    dsh_bash_traced "$logdir/store_gc_dead.log" "nix-store --gc --print-dead 2>&1 | head -20"
}

op_touch() {
    local logdir="$1"

    log "  Testing: ${BLUE}touch /tmp/triage_test${RESET} (built-in)"
    dsh_traced "$logdir/touch_builtin.log" /usr/bin/touch /tmp/triage_test_builtin

    log "  Testing: ${BLUE}touch -t (timestamp)${RESET}"
    dsh_traced "$logdir/touch_timestamp.log" /usr/bin/touch -t 202301011200 /tmp/triage_test_ts

    if [ "$HAS_NIX" -eq 1 ]; then
        log "  Testing: ${BLUE}Nix coreutils touch${RESET}"
        dsh_bash_traced "$logdir/touch_nix.log" \
            "if type -P touch >/dev/null; then touch /tmp/triage_test_nix; else echo 'touch not on PATH'; fi"
    fi

    # Clean up
    dsh "$TRIAGE_TMP/touch_cleanup.log" rm -f /tmp/triage_test_builtin /tmp/triage_test_ts /tmp/triage_test_nix
}

op_mv() {
    local logdir="$1"

    log "  Testing: ${BLUE}mv (built-in)${RESET}"
    dsh_traced "$logdir/mv_builtin_setup.log" /usr/bin/touch /tmp/triage_mv_src
    dsh_traced "$logdir/mv_builtin.log" /bin/mv /tmp/triage_mv_src /tmp/triage_mv_dst

    if [ "$HAS_NIX" -eq 1 ]; then
        log "  Testing: ${BLUE}Nix coreutils mv${RESET}"
        dsh_bash_traced "$logdir/mv_nix_setup.log" "touch /tmp/triage_mv_nix_src"
        dsh_bash_traced "$logdir/mv_nix.log" \
            "if type -P mv >/dev/null; then mv /tmp/triage_mv_nix_src /tmp/triage_mv_nix_dst; else echo 'mv not on PATH'; fi"
    fi

    # Clean up
    dsh "$TRIAGE_TMP/mv_cleanup.log" rm -f /tmp/triage_mv_src /tmp/triage_mv_dst /tmp/triage_mv_nix_src /tmp/triage_mv_nix_dst
}

op_curl() {
    local logdir="$1"

    log "  Testing: ${BLUE}curl --version${RESET}"
    dsh_traced "$logdir/curl_version.log" curl --version

    log "  Testing: ${BLUE}curl https://cache.nixos.org/nix-cache-info${RESET}"
    dsh_traced "$logdir/curl_https.log" curl -sfI https://cache.nixos.org/nix-cache-info

    log "  Testing: ${BLUE}curl http (plain)${RESET}"
    dsh_traced "$logdir/curl_http.log" curl -sfI http://example.com/
}

op_build() {
    local logdir="$1"

    if [ "$HAS_NIX" -eq 0 ]; then
        warn "  Skipping build tests (Nix not installed)"
        return
    fi

    log "  Testing: ${BLUE}trivial derivation build${RESET}"
    dsh_bash_traced "$logdir/build_trivial.log" \
        "nix-build --no-out-link --expr 'derivation { name = \"triage-test\"; builder = \"/bin/bash\"; args = [\"-c\" \"echo ok > \\\$out\"]; system = \"x86_64-darwin\"; }' 2>&1"

    log "  Testing: ${BLUE}sandbox-exec passthrough${RESET}"
    dsh_traced "$logdir/sandbox_exec.log" \
        /usr/bin/sandbox-exec -f /dev/null -D _GLOBAL_TMP_DIR=/tmp /bin/echo "sandbox-exec passthrough ok"
}

op_channel() {
    local logdir="$1"

    if [ "$HAS_NIX" -eq 0 ]; then
        warn "  Skipping channel tests (Nix not installed)"
        return
    fi

    log "  Testing: ${BLUE}nix-channel --list${RESET}"
    dsh_bash_traced "$logdir/channel_list.log" "nix-channel --list"
}

op_install() {
    local logdir="$1"

    if [ "$HAS_NIX" -eq 0 ]; then
        warn "  Skipping install tests (Nix not installed)"
        return
    fi

    log "  Testing: ${BLUE}nix-env --query --installed${RESET}"
    dsh_bash_traced "$logdir/env_query.log" "nix-env --query --installed 2>&1 || true"
}

# ── Run Operations ──────────────────────────────────────────────────────────

IFS=',' read -ra OPS <<< "$OPERATIONS"

LOGDIR="$TRIAGE_TMP/logs"
mkdir -p "$LOGDIR"

start_strace

for op in "${OPS[@]}"; do
    op=$(echo "$op" | tr -d '[:space:]')
    opdir="$LOGDIR/$op"
    mkdir -p "$opdir"

    log "${BOLD}Running operation: $op${RESET}"

    case "$op" in
        version)  op_version "$opdir" ;;
        eval)     op_eval "$opdir" ;;
        store)    op_store "$opdir" ;;
        touch)    op_touch "$opdir" ;;
        mv)       op_mv "$opdir" ;;
        curl)     op_curl "$opdir" ;;
        build)    op_build "$opdir" ;;
        channel)  op_channel "$opdir" ;;
        install)  op_install "$opdir" ;;
        *)
            warn "Unknown operation: $op (skipping)"
            ;;
    esac

    echo "" >&2
done

stop_strace

# ── Analysis ────────────────────────────────────────────────────────────────

log "${BOLD}Analyzing results...${RESET}"

# Patterns to search for in the logs
PATTERNS=(
    'Unimplemented syscall'
    'unimplemented syscall'
    'ENOSYS'
    'not.implemented'
    'STUB'
    'Function not implemented'
    'Segmentation fault'
    'Bus error'
    'Abort trap'
    'Illegal instruction'
    'Bad system call'
    'Bad file descriptor'
)

PATTERN_REGEX=$(IFS='|'; echo "${PATTERNS[*]}")

# Collect all findings into a single file
FINDINGS="$TRIAGE_TMP/findings.txt"
: > "$FINDINGS"

# Process each log file
while IFS= read -r -d '' logfile; do
    relpath="${logfile#"$LOGDIR"/}"
    operation="${relpath%%/*}"
    testname="${relpath#*/}"
    testname="${testname%.log}"

    if grep -qiE "$PATTERN_REGEX" "$logfile" 2>/dev/null; then
        while IFS= read -r line; do
            echo "$operation|$testname|$line" >> "$FINDINGS"
        done < <(grep -iE "$PATTERN_REGEX" "$logfile" 2>/dev/null || true)
    fi
done < <(find "$LOGDIR" -name '*.log' -print0 2>/dev/null)

# Also check strace log if available
if [ -n "$STRACE_LOG" ] && [ -f "$STRACE_LOG" ]; then
    while IFS= read -r line; do
        echo "strace|darlingserver|$line" >> "$FINDINGS"
    done < <(grep -iE 'ENOSYS|ENOTSUP' "$STRACE_LOG" 2>/dev/null | head -100 || true)
fi

# ── Extract syscall numbers ─────────────────────────────────────────────────

SYSCALLS_FILE="$TRIAGE_TMP/syscalls.txt"
: > "$SYSCALLS_FILE"

# Pattern: "Unimplemented syscall (NNN)" or "Unimplemented syscall NNN"
while IFS= read -r line; do
    if [[ "$line" =~ [Uu]nimplemented[[:space:]]syscall[[:space:]]*\(?([0-9]+)\)? ]]; then
        num="${BASH_REMATCH[1]}"
        name=$(syscall_name "$num")
        op="${line%%|*}"
        echo "$num|$name|$op|$line" >> "$SYSCALLS_FILE"
    fi
done < "$FINDINGS"

# ── Other issues (non-syscall) ──────────────────────────────────────────────

OTHER_FILE="$TRIAGE_TMP/other_issues.txt"
: > "$OTHER_FILE"

while IFS= read -r line; do
    if [[ ! "$line" =~ [Uu]nimplemented[[:space:]]syscall ]]; then
        echo "$line" >> "$OTHER_FILE"
    fi
done < "$FINDINGS"

# ── Generate Report ─────────────────────────────────────────────────────────

generate_report() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat <<EOF
# Syscall Triage Report

Generated: $timestamp
Darling prefix: $DARLING_PREFIX
Operations tested: $OPERATIONS
XTrace: $([ "$USE_XTRACE" -eq 1 ] && echo "enabled" || echo "disabled")
Strace: $([ "$USE_STRACE" -eq 1 ] && echo "enabled" || echo "disabled")
Nix available: $([ "$HAS_NIX" -eq 1 ] && echo "yes" || echo "no")

---

## Unimplemented Syscalls

EOF

    if [ -s "$SYSCALLS_FILE" ]; then
        echo "| Syscall # | Name | Operation | Count | Sample Message |"
        echo "|-----------|------|-----------|-------|----------------|"

        # Deduplicate and count occurrences
        sort "$SYSCALLS_FILE" | while IFS='|' read -r num name op full_line; do
            echo "$num|$name|$op"
        done | sort | uniq -c | sort -rn | while read -r count entry; do
            IFS='|' read -r num name op <<< "$entry"
            # Get the first sample message for this syscall
            sample=$(grep "^${num}|" "$SYSCALLS_FILE" | head -1 | cut -d'|' -f4-)
            # Truncate long messages
            if [ ${#sample} -gt 80 ]; then
                sample="${sample:0:77}..."
            fi
            # Escape pipe chars in the message for markdown
            sample="${sample//|/\\|}"
            echo "| $num | \`$name\` | $op | $count | $sample |"
        done

        echo ""
    else
        echo "*No unimplemented syscalls detected.* :tada:"
        echo ""
        echo "This either means:"
        echo "1. All tested operations use fully-implemented syscalls, or"
        echo "2. The operations didn't exercise enough codepaths (try --xtrace or more operations)"
        echo ""
    fi

    cat <<EOF
## Other Issues

EOF

    if [ -s "$OTHER_FILE" ]; then
        echo "| Category | Operation | Test | Message |"
        echo "|----------|-----------|------|---------|"

        while IFS='|' read -r op test msg; do
            # Categorize the issue
            local category="Unknown"
            case "$msg" in
                *[Ss]egmentation*fault*|*SIGSEGV*)  category="**SEGFAULT**" ;;
                *[Bb]us*error*|*SIGBUS*)             category="**BUS ERROR**" ;;
                *[Aa]bort*|*SIGABRT*)                category="**ABORT**" ;;
                *[Ii]llegal*instruction*|*SIGILL*)   category="**SIGILL**" ;;
                *ENOSYS*)                            category="ENOSYS" ;;
                *STUB*|*[Ss]tub*)                    category="Stub" ;;
                *[Nn]ot.implemented*)                category="Not impl" ;;
                *[Bb]ad*file*descriptor*)             category="Bad FD" ;;
                *)                                    category="Other" ;;
            esac

            # Truncate long messages
            local short_msg="$msg"
            if [ ${#short_msg} -gt 80 ]; then
                short_msg="${short_msg:0:77}..."
            fi
            short_msg="${short_msg//|/\\|}"

            echo "| $category | $op | $test | $short_msg |"
        done < "$OTHER_FILE"

        echo ""
    else
        echo "*No other issues detected.*"
        echo ""
    fi

    cat <<EOF
## Summary

- **Total log files analyzed**: $(find "$LOGDIR" -name '*.log' 2>/dev/null | wc -l)
- **Files with findings**: $([ -s "$FINDINGS" ] && wc -l < "$FINDINGS" || echo 0) lines
- **Unique unimplemented syscalls**: $([ -s "$SYSCALLS_FILE" ] && cut -d'|' -f1 "$SYSCALLS_FILE" | sort -u | wc -l || echo 0)
- **Other issues**: $([ -s "$OTHER_FILE" ] && wc -l < "$OTHER_FILE" || echo 0)

## Recommended Actions

EOF

    if [ -s "$SYSCALLS_FILE" ]; then
        echo "### Must Fix (causes crashes / blocks Nix operations)"
        echo ""

        # List unique syscalls sorted by number
        local seen_nums=""
        while IFS='|' read -r num name op _; do
            if [[ ! " $seen_nums " =~ " $num " ]]; then
                seen_nums="$seen_nums $num"
                echo "- **Syscall $num** (\`$name\`): Add to syscall triage table in \`plan/syscall-triage.md\`"
            fi
        done < <(sort -t'|' -k1,1n "$SYSCALLS_FILE" | sort -t'|' -k1,1n -u)

        echo ""
    fi

    cat <<EOF
### Next Steps

1. Add any new syscalls to \`plan/syscall-triage.md\`
2. For each "Must fix" syscall, determine the best implementation strategy:
   - Full translation to Linux equivalent
   - Stub returning ENOTSUP (if caller handles gracefully)
   - Stub returning 0 (if call is informational/optional)
3. Re-run this triage after implementing fixes to verify they work
4. Run with \`--xtrace\` for more detailed tracing if needed

## Raw Logs

Log files are saved in: \`$TRIAGE_TMP/logs/\`

EOF

    # List all log files and whether they had issues
    echo "| Log File | Status | Size |"
    echo "|----------|--------|------|"
    while IFS= read -r -d '' logfile; do
        local relpath="${logfile#"$LOGDIR"/}"
        local size
        size=$(wc -c < "$logfile")
        local status="${GREEN}clean${RESET}"
        if grep -qiE "$PATTERN_REGEX" "$logfile" 2>/dev/null; then
            status="${RED}issues found${RESET}"
        elif [ "$size" -eq 0 ]; then
            status="${YELLOW}empty${RESET}"
        fi
        echo "| \`$relpath\` | $status | ${size}B |"
    done < <(find "$LOGDIR" -name '*.log' -print0 2>/dev/null | sort -z)

    echo ""
    echo "---"
    echo "*Generated by \`scripts/triage-syscalls.sh\` — see [plan/syscall-triage.md](../plan/syscall-triage.md)*"
}

# ── Output ──────────────────────────────────────────────────────────────────

REPORT="$TRIAGE_TMP/report.md"
generate_report > "$REPORT"

if [ -n "$OUTPUT_FILE" ]; then
    cp "$REPORT" "$OUTPUT_FILE"
    log "Report saved to: ${BOLD}$OUTPUT_FILE${RESET}"
else
    echo "" >&2
    log "${BOLD}═══ Triage Report ═══${RESET}"
    echo "" >&2
    cat "$REPORT"
fi

# Print a short summary to stderr regardless
echo "" >&2
UNIQUE_SYSCALLS=$([ -s "$SYSCALLS_FILE" ] && cut -d'|' -f1 "$SYSCALLS_FILE" | sort -u | wc -l || echo 0)
OTHER_COUNT=$([ -s "$OTHER_FILE" ] && wc -l < "$OTHER_FILE" || echo 0)

if [ "$UNIQUE_SYSCALLS" -eq 0 ] && [ "$OTHER_COUNT" -eq 0 ]; then
    log "${GREEN}${BOLD}No issues found!${RESET} All tested operations passed cleanly."
else
    log "Found ${RED}${BOLD}$UNIQUE_SYSCALLS${RESET} unimplemented syscall(s) and ${YELLOW}${BOLD}$OTHER_COUNT${RESET} other issue(s)."
fi
log "Full logs: $TRIAGE_TMP/logs/"
[ -n "$OUTPUT_FILE" ] && log "Report: $OUTPUT_FILE"

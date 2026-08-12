#!/usr/bin/env nu
# triage-syscalls.nu: automated syscall triage for Darling + Nix
#
# This script runs various Nix operations inside a Darling prefix and
# captures "Unimplemented syscall" messages, ENOSYS errors, and other
# indicators of missing kernel functionality. The output is a table
# suitable for pasting into docs/changelog.md.
#
# Usage:
#   ./scripts/triage-syscalls.nu [OPTIONS]
#
# Options:
#   --prefix <path>       Darling prefix (default: ~/.cider or $DPREFIX)
#   --output <file>       Write results to file (default: stdout)
#   --strace              Also run strace on ciderd (requires root)
#   --xtrace              Insert libxtrace into the guest for detailed Darwin tracing
#   --operations <list>   Comma-separated list of operations to test
#                         (default: all). Available: version,eval,store,
#                         touch,mv,curl,install,build,channel
#   --timeout <secs>      Timeout per operation (default: 60)
#
# Output:
#   A Markdown-formatted table of discovered syscalls, with columns:
#     Syscall # | Caller | Operation | Message | Count
#
# Prerequisites:
#   - Darling must be installed and cider shell echo ok must work
#   - For Nix-related tests, Nix must be installed in the prefix
#     (run scripts/install-nix-in-cider.nu first)
#
# Converted from bash (task #40) and verified against it with cider, timeout,
# pidof and strace stubbed on PATH, no container: clean logs, logs carrying
# unimplemented syscalls (known and unknown numbers, both message shapes), each
# of the nine non-syscall categories, a message over the 80 character truncation
# limit, a message containing a pipe, empty logs, --output, --xtrace, --strace,
# --operations subsets, an unknown operation, --timeout, and a prefix without
# Nix. The report body, the exit code and the argv of every cider invocation
# all match.
#
# find, sort, uniq and grep stay external. The report is ordered by GNU sort
# (numeric with a reversed byte-order tiebreak) and the findings are collected in
# readdir order, neither of which a nushell sort reproduces; reimplementing them
# would change the report rather than convert the script.
#
# One deviation: --help prints nushell's own signature help rather than the
# header block, and an unknown option is rejected by the nushell parser with
# exit 1 where bash printed its own message and exited 1 as well.
#
# See: docs/changelog.md (Task 1.7)

# Known syscall number to name mapping (macOS/XNU BSD syscalls)
# Source: vendor/pins/xnu/bsd/kern/syscalls.master
# This covers the most commonly-seen unimplemented syscalls.
def syscall_names [] {
    {
    "1": "exit", "2": "fork", "3": "read", "4": "write", "5": "open", "6": "close"
    "7": "wait4", "9": "link", "10": "unlink", "12": "chdir", "15": "chmod", "16": "chown"
    "20": "getpid", "23": "setuid", "24": "getuid", "25": "geteuid", "27": "recvmsg", "28": "sendmsg"
    "29": "recvfrom", "30": "accept", "33": "access", "36": "sync", "37": "kill", "39": "getppid"
    "41": "dup", "42": "pipe", "43": "getegid", "46": "sigaction", "47": "getgid", "48": "sigprocmask"
    "49": "getlogin", "50": "setlogin", "51": "acct", "53": "sigaltstack", "54": "ioctl", "56": "revoke"
    "57": "symlink", "58": "readlink", "59": "execve", "60": "umask", "61": "chroot", "65": "msync"
    "66": "vfork", "73": "munmap", "74": "mprotect", "75": "madvise", "78": "mincore", "79": "getgroups"
    "80": "setgroups", "82": "setpgid", "83": "setitimer", "85": "swapon", "86": "getitimer", "89": "getdtablesize"
    "90": "dup2", "92": "fcntl", "93": "select", "95": "fsync", "96": "setpriority", "97": "socket"
    "98": "connect", "100": "getpriority", "104": "bind", "105": "setsockopt", "106": "listen", "111": "sigsuspend"
    "116": "gettimeofday", "117": "getrusage", "118": "getsockopt", "120": "readv", "121": "writev", "122": "settimeofday"
    "123": "fchown", "124": "fchmod", "128": "rename", "131": "flock", "132": "mkfifo", "133": "sendto"
    "134": "shutdown", "135": "socketpair", "136": "mkdir", "137": "rmdir", "138": "utimes", "139": "futimes"
    "140": "adjtime", "142": "gethostuuid", "147": "setsid", "151": "getpgid", "152": "setprivexec", "153": "pread"
    "154": "pwrite", "157": "statfs", "158": "fstatfs", "159": "unmount", "165": "mount", "167": "csops"
    "169": "csops_audittoken", "170": "fdatasync", "173": "waitid", "180": "kdebug_trace64", "181": "kdebug_trace", "182": "kdebug_typefilter"
    "183": "setgid", "184": "setegid", "185": "seteuid", "187": "stat", "188": "fstat", "189": "lstat"
    "190": "pathconf", "191": "fpathconf", "194": "getrlimit", "195": "setrlimit", "196": "getdirentries", "197": "mmap"
    "199": "lseek", "200": "truncate", "201": "ftruncate", "202": "sysctl", "203": "mlock", "204": "munlock"
    "205": "undelete", "216": "mkcomplex", "220": "getattrlist", "221": "setattrlist", "222": "getdirentriesattr", "223": "exchangedata"
    "225": "searchfs", "226": "delete", "227": "copyfile", "228": "fgetattrlist", "229": "fsetattrlist", "230": "poll"
    "233": "getxattr", "234": "fgetxattr", "235": "setxattr", "236": "fsetxattr", "237": "removexattr", "238": "fremovexattr"
    "239": "listxattr", "240": "flistxattr", "241": "fsctl", "242": "initgroups", "243": "posix_spawn", "244": "ffsctl"
    "247": "nfsclnt", "248": "fhopen", "250": "minherit", "266": "shm_open", "267": "shm_unlink", "268": "sem_open"
    "269": "sem_close", "270": "sem_unlink", "271": "sem_wait", "272": "sem_trywait", "273": "sem_post", "274": "sysctlbyname"
    "277": "open_extended", "278": "umask_extended", "279": "stat_extended", "280": "lstat_extended", "281": "fstat_extended", "282": "chmod_extended"
    "283": "fchmod_extended", "284": "access_extended", "285": "settid", "286": "gettid", "288": "kqueue", "289": "kevent"
    "296": "mlockall", "297": "munlockall", "301": "issetugid", "302": "__pthread_kill", "303": "__pthread_sigmask", "305": "__disable_threadsignal"
    "310": "__semwait_signal", "311": "proc_info", "322": "getsid", "324": "pread_nocancel", "325": "pwrite_nocancel", "327": "aio_suspend"
    "336": "proc_rlimit_control", "338": "iopolicysys", "339": "process_policy", "340": "mlockall", "341": "munlockall", "343": "issetugid"
    "344": "__pthread_chdir", "345": "__pthread_fchdir", "346": "audit", "347": "auditon", "350": "getaudit_addr", "351": "setaudit_addr"
    "357": "getentropy", "360": "getattrlistbulk", "361": "clonefileat", "362": "openat", "363": "openat_nocancel", "364": "renameat"
    "366": "faccessat", "367": "fchmodat", "368": "fchownat", "369": "fstatat", "370": "fstatat64", "371": "linkat"
    "372": "unlinkat", "373": "readlinkat", "374": "symlinkat", "375": "mkdirat", "376": "getattrlistat", "377": "proc_trace_log"
    "378": "bsdthread_ctl", "380": "openbyid_np", "381": "recvmsg_x", "382": "sendmsg_x", "384": "guarded_open_np", "385": "guarded_close_np"
    "386": "guarded_kqueue_np", "387": "change_fdguard_np", "388": "usrctl", "389": "proc_rlimit_control", "394": "coalition", "395": "coalition_info"
    "396": "necp_match_policy", "397": "getattrlistbulk", "398": "clonefileat", "399": "openat", "400": "openat_nocancel", "401": "renameat"
    "403": "faccessat", "404": "fchmodat", "405": "fchownat", "406": "fstatat", "407": "fstatat64", "408": "linkat"
    "409": "unlinkat", "410": "readlinkat", "411": "symlinkat", "412": "mkdirat", "413": "getattrlistat", "414": "proc_trace_log"
    "415": "bsdthread_ctl", "417": "openbyid_np", "418": "recvmsg_x", "419": "sendmsg_x", "420": "thread_selfusage", "421": "csrctl"
    "422": "guarded_open_dprotected_np", "423": "guarded_write_np", "424": "guarded_pwrite_np", "425": "guarded_writev_np", "426": "renameatx_np", "427": "mremap_encrypted"
    "428": "netagent_trigger", "429": "stack_snapshot_with_config", "430": "microstackshot", "431": "grab_pgo_data", "432": "persona", "438": "fs_snapshot"
    "441": "terminate_with_payload", "442": "abort_with_payload", "443": "necp_session_open", "444": "necp_session_action", "449": "fclonefileat", "450": "fs_snapshot"
    "452": "terminate_with_payload", "453": "abort_with_payload", "462": "clonefile", "463": "close_nocancel", "464": "accept_nocancel", "468": "msync_nocancel"
    "469": "fcntl_nocancel", "470": "select_nocancel", "471": "fsgetpath", "473": "pselect", "474": "pselect_nocancel", "475": "read_nocancel"
    "476": "write_nocancel", "477": "open_dprotected_np", "480": "kevent_qos", "481": "kevent_id", "482": "__mac_execve", "483": "__mac_syscall"
    "484": "__mac_get_file", "485": "__mac_set_file", "486": "__mac_get_link", "487": "__mac_set_link", "488": "renameatx_np", "489": "setxattr"
    "500": "getentropy", "515": "ulock_wait", "516": "ulock_wake", "517": "fclonefileat", "518": "fs_snapshot", "519": "terminate_with_payload"
    "520": "abort_with_payload"
    }
}

def syscall_name [num: string] {
    (syscall_names) | get -o $num | default $"unknown_($num)"
}

def colours [] {
    if (is-terminal --stdout) and (($env | get -o NO_COLOR | default "") | is-empty) {
        {red: (ansi red), green: (ansi green), yellow: (ansi yellow), blue: (ansi blue)
         bold: (ansi attr_bold), dim: (ansi attr_dimmed), reset: (ansi reset)}
    } else {
        {red: "", green: "", yellow: "", blue: "", bold: "", dim: "", reset: ""}
    }
}

# Every one of these went to stderr in the bash version, including log.
def log_ [c: record, msg: string] { print -e $"($c.green)[triage]($c.reset) ($msg)" }
def warn [c: record, msg: string] { print -e $"($c.yellow)[triage] WARNING:($c.reset) ($msg)" }
def err_ [c: record, msg: string] { print -e $"($c.red)[triage] ERROR:($c.reset) ($msg)" }
def debug_ [c: record, msg: string] { print -e $"($c.dim)[triage] ($msg)($c.reset)" }

# Run a command inside the Darling prefix, capturing all output.
def dsh [ctx: record, logfile: string, argv: list<string>] {
    try { ^timeout $ctx.timeout cider shell ...$argv out+err> $logfile }
}

# Run a command inside the Darling prefix with bash -lc.
def dsh_bash [ctx: record, logfile: string, cmd: string] {
    try { ^timeout $ctx.timeout cider shell bash -lc $cmd out+err> $logfile }
}

# Run with the syscall tracer inserted, if requested.
#
# This used to set a variable named DARLING_XTRACE, which NOTHING has ever read: not the
# loader, not the server, not xtrace itself, not upstream. The flag was inert, so a triage run
# made with --xtrace produced no trace and looked like a syscall that was never reached.
# scripts/buck-env-names-check.nu exists to stop that recurring, and it treats the name written
# as an ASSIGNMENT as the advertisement, which is why this comment names it in prose instead.
#
# The tracer is a constructor library. darwin/xtrace/xtracelib.cpp declares xtrace_setup with
# __attribute__((constructor)), so it starts tracing as soon as it is LOADED, and the only
# thing that loads it is dyld insertion. Nothing in the tree wires that up automatically,
# which is why it has to be done here explicitly.
const XTRACE_LIB = "/usr/lib/cider/libxtrace.dylib"

def dsh_traced [ctx: record, logfile: string, argv: list<string>] {
    if $ctx.xtrace {
        try { ^timeout $ctx.timeout env $"DYLD_INSERT_LIBRARIES=($XTRACE_LIB)" cider shell ...$argv out+err> $logfile }
    } else {
        try { ^timeout $ctx.timeout cider shell ...$argv out+err> $logfile }
    }
}

def dsh_bash_traced [ctx: record, logfile: string, cmd: string] {
    if $ctx.xtrace {
        try { ^timeout $ctx.timeout env $"DYLD_INSERT_LIBRARIES=($XTRACE_LIB)" cider shell bash -lc $cmd out+err> $logfile }
    } else {
        try { ^timeout $ctx.timeout cider shell bash -lc $cmd out+err> $logfile }
    }
}

# ── Operations ──────────────────────────────────────────────────────────────
#
# Each operation function takes a log directory and produces log files inside it.

def op_version [ctx: record, logdir: string] {
    let c = $ctx.c
    log_ $c $"  Testing: ($c.blue)cider shell echo ok($c.reset)"
    dsh_traced $ctx $"($logdir)/echo.log" ["echo" "hello from cider"]

    log_ $c $"  Testing: ($c.blue)sw_vers($c.reset)"
    dsh_traced $ctx $"($logdir)/sw_vers.log" ["sw_vers"]

    log_ $c $"  Testing: ($c.blue)uname -a($c.reset)"
    dsh_traced $ctx $"($logdir)/uname.log" ["uname" "-a"]

    if $ctx.has_nix {
        log_ $c $"  Testing: ($c.blue)nix --version($c.reset)"
        dsh_bash_traced $ctx $"($logdir)/nix_version.log" "nix --version"

        log_ $c $"  Testing: ($c.blue)nix-env --version($c.reset)"
        dsh_bash_traced $ctx $"($logdir)/nix_env_version.log" "nix-env --version"

        log_ $c $"  Testing: ($c.blue)nix-store --version($c.reset)"
        dsh_bash_traced $ctx $"($logdir)/nix_store_version.log" "nix-store --version"
    }
}

def op_eval [ctx: record, logdir: string] {
    let c = $ctx.c
    if not $ctx.has_nix {
        warn $c "  Skipping eval tests (Nix not installed)"
        return
    }

    log_ $c $"  Testing: ($c.blue)nix-instantiate --eval -E '1 + 1'($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/eval_simple.log" "nix-instantiate --eval -E '1 + 1'"

    log_ $c $"  Testing: ($c.blue)nix eval --expr '1 + 1'($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/eval_nix3.log" "nix eval --expr '1 + 1'"

    log_ $c $"  Testing: ($c.blue)builtins.currentSystem($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/eval_system.log" "nix eval --expr 'builtins.currentSystem'"

    log_ $c $"  Testing: ($c.blue)nix eval \(complex expression\)($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/eval_complex.log" "nix eval --expr 'let f = x: if x <= 1 then 1 else x * f (x - 1); in f 10'"

    log_ $c $"  Testing: ($c.blue)nix eval \(import\)($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/eval_import.log" "nix eval --expr 'builtins.length (builtins.attrNames builtins)'"
}

def op_store [ctx: record, logdir: string] {
    let c = $ctx.c
    if not $ctx.has_nix {
        warn $c "  Skipping store tests (Nix not installed)"
        return
    }

    log_ $c $"  Testing: ($c.blue)nix-store --verify($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/store_verify.log" "nix-store --verify --no-build 2>&1 || nix-store --verify"

    log_ $c $"  Testing: ($c.blue)nix-store --dump-db($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/store_dump_db.log" "nix-store --dump-db | head -50"

    log_ $c $"  Testing: ($c.blue)nix-store --gc --print-dead($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/store_gc_dead.log" "nix-store --gc --print-dead 2>&1 | head -20"
}

def op_touch [ctx: record, logdir: string] {
    let c = $ctx.c
    log_ $c $"  Testing: ($c.blue)touch /tmp/triage_test($c.reset) \(built-in\)"
    dsh_traced $ctx $"($logdir)/touch_builtin.log" ["/usr/bin/touch" "/tmp/triage_test_builtin"]

    log_ $c $"  Testing: ($c.blue)touch -t \(timestamp\)($c.reset)"
    dsh_traced $ctx $"($logdir)/touch_timestamp.log" ["/usr/bin/touch" "-t" "202301011200" "/tmp/triage_test_ts"]

    if $ctx.has_nix {
        log_ $c $"  Testing: ($c.blue)Nix coreutils touch($c.reset)"
        dsh_bash_traced $ctx $"($logdir)/touch_nix.log" "if type -P touch >/dev/null; then touch /tmp/triage_test_nix; else echo 'touch not on PATH'; fi"
    }

    # Clean up
    dsh $ctx $"($ctx.tmp)/touch_cleanup.log" ["rm" "-f" "/tmp/triage_test_builtin" "/tmp/triage_test_ts" "/tmp/triage_test_nix"]
}

def op_mv [ctx: record, logdir: string] {
    let c = $ctx.c
    log_ $c $"  Testing: ($c.blue)mv \(built-in\)($c.reset)"
    dsh_traced $ctx $"($logdir)/mv_builtin_setup.log" ["/usr/bin/touch" "/tmp/triage_mv_src"]
    dsh_traced $ctx $"($logdir)/mv_builtin.log" ["/bin/mv" "/tmp/triage_mv_src" "/tmp/triage_mv_dst"]

    if $ctx.has_nix {
        log_ $c $"  Testing: ($c.blue)Nix coreutils mv($c.reset)"
        dsh_bash_traced $ctx $"($logdir)/mv_nix_setup.log" "touch /tmp/triage_mv_nix_src"
        dsh_bash_traced $ctx $"($logdir)/mv_nix.log" "if type -P mv >/dev/null; then mv /tmp/triage_mv_nix_src /tmp/triage_mv_nix_dst; else echo 'mv not on PATH'; fi"
    }

    # Clean up
    dsh $ctx $"($ctx.tmp)/mv_cleanup.log" ["rm" "-f" "/tmp/triage_mv_src" "/tmp/triage_mv_dst" "/tmp/triage_mv_nix_src" "/tmp/triage_mv_nix_dst"]
}

def op_curl [ctx: record, logdir: string] {
    let c = $ctx.c
    log_ $c $"  Testing: ($c.blue)curl --version($c.reset)"
    dsh_traced $ctx $"($logdir)/curl_version.log" ["curl" "--version"]

    log_ $c $"  Testing: ($c.blue)curl https://cache.nixos.org/nix-cache-info($c.reset)"
    dsh_traced $ctx $"($logdir)/curl_https.log" ["curl" "-sfI" "https://cache.nixos.org/nix-cache-info"]

    log_ $c $"  Testing: ($c.blue)curl http \(plain\)($c.reset)"
    dsh_traced $ctx $"($logdir)/curl_http.log" ["curl" "-sfI" "http://example.com/"]
}

def op_build [ctx: record, logdir: string] {
    let c = $ctx.c
    if not $ctx.has_nix {
        warn $c "  Skipping build tests (Nix not installed)"
        return
    }

    log_ $c $"  Testing: ($c.blue)trivial derivation build($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/build_trivial.log" (
        r##'nix-build --no-out-link --expr 'derivation { name = "triage-test"; builder = "/bin/bash"; args = ["-c" "echo ok > \$out"]; system = "x86_64-darwin"; }' 2>&1'##
    )

    log_ $c $"  Testing: ($c.blue)sandbox-exec passthrough($c.reset)"
    dsh_traced $ctx $"($logdir)/sandbox_exec.log" ["/usr/bin/sandbox-exec" "-f" "/dev/null" "-D" "_GLOBAL_TMP_DIR=/tmp" "/bin/echo" "sandbox-exec passthrough ok"]
}

def op_channel [ctx: record, logdir: string] {
    let c = $ctx.c
    if not $ctx.has_nix {
        warn $c "  Skipping channel tests (Nix not installed)"
        return
    }

    log_ $c $"  Testing: ($c.blue)nix-channel --list($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/channel_list.log" "nix-channel --list"
}

def op_install [ctx: record, logdir: string] {
    let c = $ctx.c
    if not $ctx.has_nix {
        warn $c "  Skipping install tests (Nix not installed)"
        return
    }

    log_ $c $"  Testing: ($c.blue)nix-env --query --installed($c.reset)"
    dsh_bash_traced $ctx $"($logdir)/env_query.log" "nix-env --query --installed 2>&1 || true"
}

# ── Analysis helpers ────────────────────────────────────────────────────────

# find, not ls or glob: the findings are collected in readdir order, which is
# what the bash version wrote and what the report then reflects.
def find_logs [logdir: string, sorted: bool] {
    let raw = if $sorted {
        (^find $logdir -name '*.log' -print0 | ^sort -z | into string)
    } else {
        (^find $logdir -name '*.log' -print0 | into string)
    }
    $raw | split row (char --integer 0) | where {|f| ($f | str length) > 0 }
}

# ${#s} and ${s:0:77} count characters in a UTF-8 locale, which is what str
# length and str substring do.
def truncate80 [s: string] {
    if ($s | str length) > 80 { (($s | str substring 0..<77) + "...") } else { $s }
}

def escape_pipes [s: string] { $s | str replace --all "|" "\\|" }

def categorize [msg: string] {
    # bash used a case with GLOB patterns, first match wins. The dot in
    # not.implemented is literal in a glob, so a message saying "not implemented"
    # with a space falls through to Other. Kept.
    #
    # A list rather than an else-if chain: nushell needs } else if on the closing
    # brace line, and a chain that wide is unreadable.
    let rules = [
        ['[Ss]egmentation.*fault|SIGSEGV' "**SEGFAULT**"]
        ['[Bb]us.*error|SIGBUS' "**BUS ERROR**"]
        ['[Aa]bort|SIGABRT' "**ABORT**"]
        ['[Ii]llegal.*instruction|SIGILL' "**SIGILL**"]
        ['ENOSYS' "ENOSYS"]
        ['STUB|[Ss]tub' "Stub"]
        ['[Nn]ot\.implemented' "Not impl"]
        ['[Bb]ad.*file.*descriptor' "Bad FD"]
    ]
    let hits = ($rules | where {|r| $msg =~ ($r | get 0) })
    if ($hits | is-empty) { "Other" } else { $hits | first | get 1 }
}

def main [
    --prefix: string = ""       # Darling prefix (default: ~/.cider or $DPREFIX)
    --output: string = ""       # write results to file (default: stdout)
    --strace                    # also run strace on ciderd (requires root)
    --xtrace                    # insert libxtrace into the guest for detailed Darwin tracing
    --operations: string = "version,eval,store,touch,mv,curl,build"  # comma-separated
    --timeout: int = 60         # timeout per operation, seconds
] {
    let c = (colours)
    let cider_prefix = if ($prefix | is-not-empty) {
        $prefix
    } else {
        ($env | get -o DPREFIX | default ($env.HOME | path join ".cider"))
    }

    # ── Setup ───────────────────────────────────────────────────────────────
    let triage_tmp = (mktemp -d --tmpdir-path ($env | get -o TMPDIR | default "/tmp") "cider-triage.XXXXXX")

    log_ $c $"($c.bold)Darling Syscall Triage($c.reset)"
    log_ $c $"Prefix:     ($cider_prefix)"
    log_ $c $"Operations: ($operations)"
    log_ $c $"Timeout:    ($timeout)s per operation"
    log_ $c $"XTrace:     (if $xtrace { 'enabled' } else { 'disabled' })"
    log_ $c $"Strace:     (if $strace { 'enabled' } else { 'disabled' })"
    log_ $c $"Temp dir:   ($triage_tmp)"
    print -e ""

    # ── Preflight ───────────────────────────────────────────────────────────
    if (which cider | is-empty) {
        err_ $c "cider not found in PATH. Build it first with: nix build .#cider"
        rm -rf $triage_tmp
        exit 1
    }

    log_ $c "Checking cider shell..."
    let shell_ok = (try { ^timeout 30 cider shell echo "ok" out+err> /dev/null; true } catch { false })
    if not $shell_ok {
        err_ $c "cider shell is not functional. Try: cider shell echo ok"
        rm -rf $triage_tmp
        exit 1
    }
    log_ $c $"  cider shell: ($c.green)OK($c.reset)"

    # Check if Nix is available
    let has_nix = (try { ^timeout 15 cider shell bash -lc 'command -v nix' out+err> "/dev/null"; true } catch { false })
    if $has_nix {
        log_ $c $"  Nix in prefix: ($c.green)found($c.reset)"
    } else {
        warn $c "Nix not found in prefix. Nix-specific operations will be skipped."
        warn $c "Run scripts/install-nix-in-cider.nu first for full triage."
    }
    print -e ""

    let ctx = {c: $c, timeout: $timeout, xtrace: $xtrace, has_nix: $has_nix, tmp: $triage_tmp}

    # ── Strace setup ────────────────────────────────────────────────────────
    let logdir = $"($triage_tmp)/logs"
    mkdir $logdir

    mut strace_pid = ""
    mut strace_log = ""
    if $strace {
        let server_pid = (try { (^pidof ciderd | str trim) } catch { "" })
        if ($server_pid | is-empty) {
            warn $c "ciderd not running; cannot attach strace"
        } else {
            $strace_log = $"($triage_tmp)/strace.log"
            let job = (job spawn { ^strace -f -p $server_pid -e trace=all -o $"($triage_tmp)/strace.log" })
            $strace_pid = ($job | into string)
            sleep 1sec
            debug_ $c $"strace attached to ciderd \(pid=($server_pid)\)"
        }
    }

    # ── Run operations ──────────────────────────────────────────────────────
    for op_raw in ($operations | split row ",") {
        let op = ($op_raw | str replace --all --regex '\s' '')
        let opdir = $"($logdir)/($op)"
        mkdir $opdir

        log_ $c $"($c.bold)Running operation: ($op)($c.reset)"

        match $op {
            "version" => (op_version $ctx $opdir)
            "eval" => (op_eval $ctx $opdir)
            "store" => (op_store $ctx $opdir)
            "touch" => (op_touch $ctx $opdir)
            "mv" => (op_mv $ctx $opdir)
            "curl" => (op_curl $ctx $opdir)
            "build" => (op_build $ctx $opdir)
            "channel" => (op_channel $ctx $opdir)
            "install" => (op_install $ctx $opdir)
            _ => { warn $c $"Unknown operation: ($op) \(skipping\)" }
        }

        print -e ""
    }

    if ($strace_pid | is-not-empty) {
        job kill ($strace_pid | into int)
    }

    # ── Analysis ────────────────────────────────────────────────────────────
    log_ $c $"($c.bold)Analyzing results...($c.reset)"

    let patterns = [
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
    ]
    let pattern_regex = ($patterns | str join "|")

    # Collect all findings into a single file
    let findings_file = $"($triage_tmp)/findings.txt"
    mut findings = []

    for logfile in (find_logs $logdir false) {
        let relpath = ($logfile | str replace $"($logdir)/" "")
        let operation = ($relpath | split row "/" | first)
        let testname = (($relpath | split row "/" | skip 1 | str join "/") | str replace -r '\.log$' '')

        let hits = (try { (^grep -iE $pattern_regex $logfile | into string) } catch { "" })
        if ($hits | is-not-empty) {
            for line in ($hits | str replace -r '\n$' '' | split row "\n") {
                $findings = ($findings | append $"($operation)|($testname)|($line)")
            }
        }
    }

    # Also check strace log if available
    if ($strace_log | is-not-empty) and ($strace_log | path exists) {
        let hits = (try { (^grep -iE 'ENOSYS|ENOTSUP' $strace_log | ^head -100 | into string) } catch { "" })
        if ($hits | is-not-empty) {
            for line in ($hits | str replace -r '\n$' '' | split row "\n") {
                $findings = ($findings | append $"strace|ciderd|($line)")
            }
        }
    }
    let findings_text = (if ($findings | is-empty) { "" } else { ($findings | str join "\n") + "\n" })
    $findings_text | save -f -r $findings_file

    # ── Extract syscall numbers ─────────────────────────────────────────────
    let syscalls_file = $"($triage_tmp)/syscalls.txt"
    mut syscalls = []
    for line in $findings {
        let m = ($line | parse --regex '[Uu]nimplemented\s+syscall\s*\(?(?P<num>[0-9]+)\)?')
        if ($m | is-not-empty) {
            let num = ($m | first | get num)
            let name = (syscall_name $num)
            let op = ($line | split row "|" | first)
            $syscalls = ($syscalls | append $"($num)|($name)|($op)|($line)")
        }
    }
    let syscalls_text = (if ($syscalls | is-empty) { "" } else { ($syscalls | str join "\n") + "\n" })
    $syscalls_text | save -f -r $syscalls_file

    # ── Other issues (non-syscall) ──────────────────────────────────────────
    let other_file = $"($triage_tmp)/other_issues.txt"
    let others = ($findings | where {|l| not ($l =~ '[Uu]nimplemented\s+syscall') })
    let other_text = (if ($others | is-empty) { "" } else { ($others | str join "\n") + "\n" })
    $other_text | save -f -r $other_file

    # ── Generate report ─────────────────────────────────────────────────────
    let timestamp = (date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
    mut rep = []

    $rep = ($rep | append [
        "# Syscall Triage Report"
        ""
        $"Generated: ($timestamp)"
        $"Darling prefix: ($cider_prefix)"
        $"Operations tested: ($operations)"
        $"XTrace: (if $xtrace { 'enabled' } else { 'disabled' })"
        $"Strace: (if $strace { 'enabled' } else { 'disabled' })"
        $"Nix available: (if $has_nix { 'yes' } else { 'no' })"
        ""
        "---"
        ""
        "## Unimplemented Syscalls"
        ""
    ])

    if ($syscalls | is-not-empty) {
        $rep = ($rep | append [
            "| Syscall # | Name | Operation | Count | Sample Message |"
            "|-----------|------|-----------|-------|----------------|"
        ])
        # sort | uniq -c | sort -rn, externally: the tiebreak is a reversed byte
        # comparison of the whole line, count padding included.
        let triples = ($syscalls | each {|l| $l | split row "|" | first 3 | str join "|" })
        let counted = (($triples | str join "\n") + "\n" | ^sort | ^uniq -c | ^sort -rn | into string)
        for row in ($counted | str replace -r '\n$' '' | split row "\n") {
            let m = ($row | parse --regex '^\s*(?P<count>\S+)\s+(?P<entry>.*?)\s*$' | first)
            let f = ($m.entry | split row "|")
            let num = ($f | get 0)
            let name = ($f | get 1)
            let op = ($f | get 2)
            let sample_line = (try { (^grep $"^($num)|" $syscalls_file | ^head -1 | into string) } catch { "" })
            let sample = (escape_pipes (truncate80 (
                $sample_line | str replace -r '\n$' '' | split row "|" | skip 3 | str join "|"
            )))
            $rep = ($rep | append $"| ($num) | `($name)` | ($op) | ($m.count) | ($sample) |")
        }
        $rep = ($rep | append "")
    } else {
        $rep = ($rep | append [
            "*No unimplemented syscalls detected.* :tada:"
            ""
            "This either means:"
            "1. All tested operations use fully-implemented syscalls, or"
            "2. The operations didn't exercise enough codepaths (try --xtrace or more operations)"
            ""
        ])
    }

    $rep = ($rep | append ["## Other Issues" ""])

    if ($others | is-not-empty) {
        $rep = ($rep | append [
            "| Category | Operation | Test | Message |"
            "|----------|-----------|------|---------|"
        ])
        for line in $others {
            let f = ($line | split row "|")
            let op = ($f | get 0)
            let test = ($f | get 1)
            let msg = ($f | skip 2 | str join "|")
            $rep = ($rep | append $"| (categorize $msg) | ($op) | ($test) | (escape_pipes (truncate80 $msg)) |")
        }
        $rep = ($rep | append "")
    } else {
        $rep = ($rep | append ["*No other issues detected.*" ""])
    }

    let log_count = (find_logs $logdir false | length)
    $rep = ($rep | append [
        "## Summary"
        ""
        $"- **Total log files analyzed**: ($log_count)"
        $"- **Files with findings**: ($findings | length) lines"
        $"- **Unique unimplemented syscalls**: ($syscalls | each {|l| $l | split row '|' | first } | uniq | length)"
        $"- **Other issues**: ($others | length)"
        ""
        "## Recommended Actions"
        ""
    ])

    if ($syscalls | is-not-empty) {
        $rep = ($rep | append ["### Must Fix (causes crashes / blocks Nix operations)" ""])
        let ordered = (($syscalls | str join "\n") + "\n" | ^sort -t'|' -k1,1n | ^sort -t'|' -k1,1n -u | into string)
        mut seen = []
        for line in ($ordered | str replace -r '\n$' '' | split row "\n") {
            let f = ($line | split row "|")
            let num = ($f | get 0)
            let name = ($f | get 1)
            if not ($num in $seen) {
                $seen = ($seen | append $num)
                $rep = ($rep | append $"- **Syscall ($num)** \(`($name)`\): Add to syscall triage table in `docs/changelog.md`")
            }
        }
        $rep = ($rep | append "")
    }

    $rep = ($rep | append [
        "### Next Steps"
        ""
        "1. Add any new syscalls to `docs/changelog.md`"
        '2. For each "Must fix" syscall, determine the best implementation strategy:'
        "   - Full translation to Linux equivalent"
        "   - Stub returning ENOTSUP (if caller handles gracefully)"
        "   - Stub returning 0 (if call is informational/optional)"
        "3. Re-run this triage after implementing fixes to verify they work"
        "4. Run with `--xtrace` for more detailed tracing if needed"
        ""
        "## Raw Logs"
        ""
        $"Log files are saved in: `($triage_tmp)/logs/`"
        ""
        "| Log File | Status | Size |"
        "|----------|--------|------|"
    ])

    for logfile in (find_logs $logdir true) {
        let relpath = ($logfile | str replace $"($logdir)/" "")
        let size = (open --raw $logfile | into binary | bytes length)
        let has_issue = (try { ((^grep -iE $pattern_regex $logfile | into string) | is-not-empty) } catch { false })
        let status = if $has_issue {
            $"($c.red)issues found($c.reset)"
        } else if $size == 0 {
            $"($c.yellow)empty($c.reset)"
        } else {
            $"($c.green)clean($c.reset)"
        }
        $rep = ($rep | append $"| `($relpath)` | ($status) | ($size)B |")
    }

    $rep = ($rep | append [
        ""
        "---"
        "*Generated by `scripts/triage-syscalls.nu` \u{2014} see [docs/changelog.md](../docs/changelog.md)*"
    ])

    # ── Output ──────────────────────────────────────────────────────────────
    let report_file = $"($triage_tmp)/report.md"
    (($rep | str join "\n") + "\n") | save -f -r $report_file

    if ($output | is-not-empty) {
        cp $report_file $output
        log_ $c $"Report saved to: ($c.bold)($output)($c.reset)"
    } else {
        print -e ""
        log_ $c $"($c.bold)\u{2550}\u{2550}\u{2550} Triage Report \u{2550}\u{2550}\u{2550}($c.reset)"
        print -e ""
        print -n (open --raw $report_file)
    }

    # Print a short summary to stderr regardless
    print -e ""
    let unique_syscalls = ($syscalls | each {|l| $l | split row "|" | first } | uniq | length)
    let other_count = ($others | length)

    if $unique_syscalls == 0 and $other_count == 0 {
        log_ $c $"($c.green)($c.bold)No issues found!($c.reset) All tested operations passed cleanly."
    } else {
        log_ $c $"Found ($c.red)($c.bold)($unique_syscalls)($c.reset) unimplemented syscall\(s\) and ($c.yellow)($c.bold)($other_count)($c.reset) other issue\(s\)."
    }
    log_ $c $"Full logs: ($triage_tmp)/logs/"
    if ($output | is-not-empty) { log_ $c $"Report: ($output)" }

    rm -rf $triage_tmp
}

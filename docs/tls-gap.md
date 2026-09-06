# The TLS gap: FIXED, and the spinner behind it was never ours

RESOLVED 2026-09-06. Two bugs, both in cider, both measured and fixed:

  1. `SecCertificateCopyPublicKey` answered errSecParam with a NULL key. It now falls back to
     `SecCertificateCopyKey` (commit 8b53add7). `pubkey=-50 key=NULL` became
     `pubkey=0 key=OK size=256`. The throw is inside `Certificate::publicKey()`, NOT in the ItemImpl
     creation before it and NOT in a missing CSSM plugin; see the correction below.
  2. `kCFStreamSocketSecurityLevelNegotiatedSSL` called `SSLSetProtocolVersion(kTLSProtocol1)`, which
     is a CEILING of TLS 1.0, so every HTTPS connection was pinned to a TLS 1.0 CBC path that could
     not authenticate the first record it read. It now asks for a range up to TLS 1.2
     (commit 6a5af7fb). `protocol=4 cipher=0xc013 result=-9846` became
     `protocol=8 cipher=0xc02f result=0`, a completed handshake on AES-GCM.

AND THE SPINNER THAT STARTED ALL THIS IS NOT A CIDER DEFECT. With TLS working, the trace shows the
response arrive (`17 03 03` application data) followed by an alert. The URL the application fetches,
`https://www.belightsoft.com/appsupport/swiftpublisher/welcome55/`, answers **HTTP 403** with a static
795 byte error page last modified in 2022, and it does so for the application User-Agent, for a Safari
User-Agent and for curl, while the site root answers 200. The vendor retired the endpoint. Real macOS
would get the same 403 today.

That verdict was only reachable AFTER the TLS fixes, because before them no response arrived at all.

The rest of this document is the investigation that got there, kept because the eliminations are worth
more than the conclusion.

# The original problem: a handshake that ran and rejected the certificate

An HTTPS fetch under cider connects, exchanges TLS records, and then fails. The visible symptom is a
spinner that never resolves: Swift Publisher shows one in its welcome window, which loads remote
content. Task #199.

## What actually happens

`CIDER_TRACE_TLS=1` turns on four probes in `vendor/src/cfnetwork/src/Stream/CFSocketStream.c`
(shipped as `vendor/patches/cfnetwork/0006`). One run gives the whole sequence:

    CIDER_TLS security-level applied ok=1
    CIDER_TLS handshake registered fn=0x76114f2c6290 security=1
    CIDER_TLS handshake running                  (4 times)
    CIDER_TLS SSLHandshake result=-9803          (3 times, errSSLWouldBlock, normal progress)
    CIDER_TLS SSLHandshake result=-9808          (errSSLBadCert, bad certificate format)

The codes are `SecBase.h:809` and `SecBase.h:814`. So TLS is present and reachable: CFNetwork applies
the security level, registers `_PerformSecurityHandshake_NoLock`, runs it, moves records, and then
rejects the peer certificate.

## Where the fault is NOT

Each of these was measured, not argued.

**Not trust evaluation, and not a missing root store.** Forcing `SSLSetEnableCertVerify(FALSE)` (a
temporary probe, deliberately not committed, since it weakens TLS) took effect (`rc=0`) and the
handshake still failed with the same -9808. Chain validation is not what rejects it.

**Not the daemons.** With launchd on (`LAUNCHD=0`, the variable is inverted) the trace is identical,
and neither trustd nor securityd appears in the log in either mode.

**Not our WebKit.** WebKit in the runtime is a dev stub, but `STUB_VERBOSE=1` produced zero stub calls
across a full run, while `TRACE_ENV` forwarding was proven working in the same session
(`CIDER_TRACE_IMAGESOURCE` delivered 265 lines through it). The app drives CFNetwork directly.

**Not an empty client certificate array.** `CFSocketStream` guards `SSLSetCertificate` with
`if (value && ...)` and only passes `kCFStreamSSLCertificates` when the settings dictionary has it.

**Not a missing symbol.** `scripts/macho-undefined.py` on Security.framework reports zero unresolved.

**Not our read callback, and not the partial read.** `CIDER_TRACE_TLS` also logs every read with the
requested length, the delivered length and the first bytes. The wire is framed correctly and every
byte asked for is delivered:

    read want=5    got=5    rc=0     head=16 03 01 00 61     record header, handshake, length 0x61
    read want=97   got=97   rc=0     head=02 00 00 5d 03     ServerHello
    read want=5    got=5    rc=0     head=16 03 01 19 75     record header, length 0x1975
    read want=6517 got=5397 rc=-9803 head=0b 00 19 71 00     Certificate, delivered short
    read want=1120 got=1120 rc=0                             the remaining 1120 bytes, 5397+1120=6517
    SSLHandshake result=-9808

Forcing the callback to hand back the whole request or nothing (a second temporary probe, also not
committed) made the certificate arrive in ONE piece, `want=6517 got=6517 rc=0`, and the handshake
still failed with the same -9808. So the chunking is not the problem either.

**Not an exotic certificate.** The peer is `www.belightsoft.com` (from the welcome URL baked into the
application), and its chain is four certificates ending at USERTrust, which matches the 6513 byte
Certificate message we receive. The leaf is entirely ordinary: X.509 v3, sha256WithRSAEncryption,
RSA 2048, standard extensions, and currently inside its validity window. Nothing there needs a modern
parser.

## A provenance claim that was WRONG, and how it went wrong

An earlier version of this document said the TLS engine is Apple prebuilt and that
`vendor/src/security` therefore could not explain the error. THAT WAS WRONG, and it cost a detour.

Security IS built from our own tree. The prefix takes it from `//vendor/src:Security_final`, there is
a `libSecurity_x86_64_firstpass.dylib` from the same build, and the shipped binary carries 113
`AppleX509CL` and 58 `MDSSession` strings, which only our sources put there. `libsecurity_keychain`
and coretls are both compiled.

The two observations behind the wrong claim were real and the inferences from them were not:

  * `parseIncomingCerts` does not appear as a string, but it is a FUNCTION NAME that only reaches the
    binary through `sslErrorLog`, which `sslDebug.h` compiles out under NDEBUG.
  * `tls_handshake_negotiate` is not in the exported symbols, but a statically linked component keeps
    its symbols local, so an export list cannot prove absence.

The lesson is narrower than the one first written here: a missing STRING and a missing EXPORT are both
weak evidence about what is in a binary. A build-graph question (what does the prefix install, and
from which target) answers it directly, and that is what settled it.

## The fault: the legacy public key call returns nothing

CFNetwork already links Security, so the probe asks Security directly, feeding it the certificate
bytes taken straight out of the Certificate message on the wire. Every step works except one:

    cert parse len=1687 -> OK
    policy=OK trust create=0 trust=OK pubkey=-50 key=NULL size=-1 modern=OK msize=256

Read that line carefully, because it is the whole answer:

  * `SecCertificateCreateWithData` PARSES the certificate. Not a decode failure.
  * `SecPolicyCreateSSL` and `SecTrustCreateWithCertificates` both SUCCEED, status 0.
  * `SecCertificateCopyPublicKey`, the LEGACY entry point, returns -50 (`errSecParam`, `SecBase.h:335`)
    and hands back a NULL key.
  * `SecCertificateCopyKey`, the MODERN entry point, returns a correct key whose block size is 256
    bytes, which is exactly the RSA 2048 key the certificate carries.

So the certificate is good, the modern API reads it correctly, and only the legacy shim fails. In the
built Security the two live far apart (`SecCertificateCopyKey` at 0x6dd00, `SecCertificateCopyPublicKey`
at 0x2362e0), so they are different implementations, and the legacy one goes through CSSM and CDSA.
Which part of that path throws is answered in the correction below, and it is not what this paragraph
originally guessed.

Without a peer public key there is no key exchange, and a certificate you cannot take a key out of is
reported as a bad certificate. That is the errSSLBadCert.

CAUTION, stated as a hypothesis rather than a measurement: that SecureTransport itself takes the
legacy path is an inference from the two facts above, not something traced inside Security itself.
It is consistent with everything measured, and the legacy failure is real either way.

## CORRECTION: the CSSM plugins are NOT missing, and that story was wrong

An earlier version of this document said the legacy call fails because the CSSM plugin bundles
(AppleX509CL and friends) do not exist on disk. THAT WAS WRONG. Measured afterwards:

  * The plugin CODE is linked into Security: 123 `AppleX509CL` symbols and 71 CSP symbols.
  * `modloader.cpp` registers all six as built-ins,
    `mPlugins["*AppleX509CL"] = new StaticPlugin(builtin__apple_x509_cl)`, and `NO_BUILTIN_PLUGINS`
    is not defined anywhere in the build.
  * The installed `cl_common.mdsinfo` says `BuiltIn: true` with `Path: *AppleX509CL`, which is
    Apple's convention for a built-in module. A bundle on disk is NOT supposed to exist.

So the absence of bundles under `/System/Library/Security` was never evidence of anything. I read a
missing FILE as a missing FEATURE, which is the same shape of mistake as reading a missing string or
a missing export as missing code.

WHERE THE FAILURE IS, walked in one line at a time with `CIDER_TRACE_SECCERT=1`:

    ItemImpl create -> OK alive=1 rc=1     the legacy certificate is built AND alive when handed back
    publicKey entered                      Certificate::required succeeds, publicKey IS called
    copyFirstFieldValue entered            and it reaches the field query
    clHandle threw osStatus=-50            THE CL MODULE ATTACH IS WHAT FAILS

So the errSecParam an application finally sees is thrown attaching the Certificate Library, before any
certificate field is ever asked for. Everything downstream of that (the field query, the CSP taking
the key) is never reached, and the certificate itself was never the problem.

TWO HYPOTHESES DIED ON THE WAY, both worth recording:

  * The SecPointer destroys the ItemImpl. NO: it is alive with rc=1 when handed back. Worth testing
    because `handle()` deliberately does not retain a NEW object.
  * The plugin is missing. NO: the CL is linked into Security and registered in modloader as a static
    plugin.

## The failing call, named: DbOpen on the MDS directory returns -50

Walked the rest of the way with the same switch, adding a probe at each step that can throw
(patches 0017 to 0020). The full chain, one run of Swift Publisher:

    publicKey entered                      Certificate::publicKey
    copyFirstFieldValue entered
    AttachmentImpl activate entered        CssmClient, so the attach IS attempted
    ModuleImpl activate entered
    CSSM_Init -> 0x00000000                the CSSM session starts fine
    mdsclient MDS_Initialize -> 0x00000000 MDS starts fine too
    mdsclient DbOpen cdsa -> 0xffffffce    THIS IS THE FAILING CALL, 0xffffffce is -50
    MdsComponent fetch: threw osStatus=-50
    loadModule MdsComponent: threw osStatus=-50
    CSSM_ModuleLoad -> 0xffffffce
    clHandle threw osStatus=-50

So the -50 is born in `MDSSession::DbOpen` on the "CDSA" directory and is passed up unchanged. It is
NOT a CSSM error code: `END_API(CSSM)` only rebases a CSSM_RETURN in the common range, and a
`CommonError` that is not a CssmError comes out as its raw `osStatus()`. A CSSM entry point returning
a Security OSStatus therefore means something inside threw a MacOSError, not a CSSM error.

CORRECTED FROM THE PREVIOUS SECTION: the failing step is `CSSM_ModuleLoad`, not `CSSM_ModuleAttach`.
The attach is never reached. The earlier note naming the attach was a guess from the call chain, not
a measurement.

THREE MORE THINGS THAT ARE NOT THE CAUSE, each measured rather than argued:

  * The MDS databases are missing or empty. NO. `mdsObject.db` (4.1K) and `mdsDirectory.db` (47.2K)
    exist in the prefix, and both list all six built-in modules by name, `AppleX509CL`,
    `*AppleX509CL` and "Apple built-in CL" among them. The record being looked up is there.
  * securityd is absent. NO, and this is the one that turned out to matter: securityd is found, it
    answers, and it is the step that fails. See the next section. The launchd ON and OFF traces are
    character for character identical because securityd is reachable either way.
  * MDS itself failed to start. NO: `MDS_Initialize` returns 0 in the same run.

## The whole chain, and why the error you see is not the error that happened

Two more probes (patches 0021 and 0022) finish the walk. `MDSSession::DbOpen` contacts securityd
before it touches a file, and that is the step that throws:

    CIDER_SSCLNT findSecurityd back port=0x4907    securityd IS registered and the port is live
    CIDER_SSCLNT verifyPrivileged2 back origin=..  a full round trip, and it matches serverPort
    CIDER_SSCLNT setup back kr=0x0 rcode=0x1       kr=0 so the IPC worked; rcode=1 is securityd
    MDS DbOpen securityd: threw osStatus=-50       and what the caller sees is -50

`rcode=1` is `CSSM_ERRCODE_INTERNAL_ERROR`, from securityd's own `ucsp_server_setup`. securityd logs
it too, `setup(?:obsolete) failed rcode=1` in `var/log/system.log`. I found that line first, saw its
timestamp was hours old, and treated it as stale; the live probe printed the same value, so the log
was right and the doubt was wrong.

THE -50 IS MANUFACTURED, and this is worth knowing on its own. `ClientSession::activate` reaches
securityd through `ModuleNexus<Global>`, and `ModuleNexusCommon::do_create` is:

    try { pointer = make(); } catch (...) { pointer = NULL; }

so the CssmError(1) carrying securityd's answer is DISCARDED, and `create()` then throws a generic
`ModuleNexusError`, whose `osStatus()` is a hard-coded `errSecParam`. Every -50 above is that one
constant, not an error anybody computed. Worse, the nexus is a `dispatch_once`: after the first
failure `pointer` stays NULL for the life of the process, so every later attempt fails instantly
with the same manufactured -50 and never retries.

So chasing -50 as if it were a parameter error was chasing a placeholder. The real error is rcode=1
from securityd, and it is only visible in securityd's syslog line or with a probe below the nexus.

## The bottom of it: an identity token that does not resolve to a task

`ucsp_server_setup` in `vendor/src/security/securityd/src/transition.cpp` does two things before it
answers, and the first one fails (patch 0023):

    setup entered
    get_task_port token=0x1e03 kr=0x4 taskPort=0x0

`kr=0x4` is `KERN_INVALID_ARGUMENT`, from
`task_identity_token_get_task_port(taskToken, TASK_FLAVOR_CONTROL, &taskPort)`. There is no
`setupConnection returned` line, so `MachPlusPlus::check(kr)` throws, `END_IPCN(CSSM)` maps a
MachPlusPlus::Error's default case to `CSSM_ERRCODE_INTERNAL_ERROR`, and that is the 1 the client
reads. So the whole -50 stands on this one kern_return.

The routine IS compiled into ciderd (`task_ident.c`, `vendor/pins/ciderd/xnu-sys/BUCK`), and it has
four ways to answer KERN_INVALID_ARGUMENT. A null token and an unknown flavor are both ruled out by
the trace: the token is 0x1e03 and the flavor is `TASK_FLAVOR_CONTROL`, which the switch handles. What
is left is `proc_find_ident(&token->ident)` returning NULL, or the task behind it being TASK_NULL.

HOW TO PROBE SECURITYD, because this cost a build: **its `Syslog::notice` does not reach
`var/log/system.log` in a container, and its stderr is not collected either.** The first version of
patch 0023 used Syslog and printed nothing, which is indistinguishable from the handler never
running. Write to a file under the prefix instead, and include an entry line as a positive control.
securityd itself is definitely alive: `mldr!/usr/sbin/securityd -i` was in 19 of 20 samples of the
host process table during a run.

The client is NOT at fault, which was the other candidate: `self_token_create` falls back to sending
`mach_task_self()` on an old kernel, and a task port would never resolve as a token. It did not fall
back. Measured, `task_create_identity_token kr=0x0 token=0x3803 self=0x103`, so the token is real and
distinct from the task port.

## ROOT CAUSE: task_lookup_eternal is a stub that always returns NULL

Probing every KERN_INVALID_ARGUMENT branch in ciderd's `task_identity_token_get_task_port`
(patch `vendor/patches/xnu-sys-xnu/0007`) names it in two lines:

    [xnu_sys] CIDER_TIDT ident eid=6 flavor=0
    [xnu_sys] CIDER_TIDT proc_find_ident found nothing

cider's `struct proc_ident` is a single `xnu_sys_eternal_id_t eid` (not xnu's pid/uniqueid/idversion),
and `proc_find_ident` is `task_lookup_eternal(eid, true)`. In `src/linux/server/src/sched.rs`, BOTH
halves of that identity are stubs:

    pub(super) unsafe extern "C" fn task_lookup_eternal(_eid, _retain) -> *mut xnu_sys_task_t {
        std::ptr::null_mut()
    }
    pub(super) unsafe extern "C" fn task_eternal_id(_c: *mut c_void) -> xnu_sys_eternal_id_t {
        NEXT_EID.fetch_add(1, Ordering::Relaxed)
    }

`task_eternal_id` ignores the task it is asked about and hands back a fresh counter value, so the
"eternal id" is not an identity: the same task gets a different number every call, nothing records
the mapping, and the lookup returns NULL unconditionally. An identity token therefore can never be
resolved back to a task by anyone.

THIS IS BIGGER THAN CERTIFICATES. `ClientSession::activate` is the front door of every securityd
call, so this one stub is why keychain, code signing and trust work all arrive at the same
manufactured -50 or hang. The certificate path is just the one that led here.

## FIXED, and the failure moved one layer on

`task_eternal_id` turned out to need no change: `xnu_sys_task_create` calls it exactly ONCE per task
and stores the result in `p_ident`, so the number is already stable. Only the reverse was missing.
`sched.rs` now keeps a `TASK_BY_EID` table beside the existing `TASK_BY_NSID` one, filled in
`register_task_lookup` by reading the id back off the task (never by assigning a second one) and
cleared in `unregister_task_lookup`.

Measured before and after, same app, same probes:

    before   CIDER_TIDT proc_find_ident found nothing
             get_task_port token=0x2103 kr=0x4 taskPort=0x0
             setup back kr=0x0 rcode=0x1

    after    CIDER_TIDT past the eval, asking for special port 1
             get_task_port token=0x2003 kr=0x0 taskPort=0x2303
             setup back kr=0x0 rcode=0xfffefa2c

So the token resolves, securityd gets the client's task port, and the Mach half is done. Swift
Publisher still renders and resizes correctly, LOOKED at, so nothing regressed.

## FIXED, and it was a log line: the legacy path now works end to end

`0xfffefa2c` is -67028, `errSecCSBadBundleFormat`. Probing each step of `Process::Process`
(patch 0024) puts it somewhere unexpected:

    Process codePath threw osStatus=-67028

Everything functional had already succeeded: the session, `Process::setup`, `ClientIdentification::setup`
and `processCode()`. The throw is in the LAST LINE of the constructor, the `secinfo` that names the new
client, whose argument is `codePath(this->processCode())`:

    std::string codePath(SecStaticCodeRef code)
    {
        CFRef<CFURLRef> path;
        MacOSError::check(SecCodeCopyPath(code, kSecCSDefaultFlags, &path.aref()));   // THROWS
        return cfString(path);
    }

A DIAGNOSTIC WAS LOAD BEARING. `codePath` is commented in Apple's own source as a "bonus function", its
only caller is that log line, and `dumpCode` twenty lines below it already tolerates the same failure
with `unknown(rc=%d)`. Patch 0025 makes `codePath` do the same instead of throwing.

Measured after, one run of Swift Publisher, and the trace no longer contains a single -50:

    setup back kr=0x0 rcode=0x0                     securityd accepts the client
    MDS DbOpen path: .../mdsDirectory.db            the MDS database opens
    mdsclient DbOpen cdsa -> 0x00000000
    loadModule path: *AppleX509CL                   the built-in CL loads
    CSSM_ModuleLoad -> 0x00000000
    CSSM_ModuleAttach -> 0x00000000                 the attach this document once guessed at
    copyFirstFieldValue clHandle=0x75df6ec6c239
    loadModule path: *AppleCSP                      and the CSP
    CertGetFirstCachedFieldValue result=0x0 fields=1
    publicKey CL field -> OK
    publicKey CSP key -> OK                         the LEGACY public key, working

So the legacy `SecCertificateCopyPublicKey` works now; the modern fallback from 8b53add7 stays as a
safety net rather than the load-bearing path. Swift Publisher renders and resizes correctly, LOOKED at.

THIS IS NOT ONLY ABOUT CERTIFICATES. `ClientSession::activate` is the front door of every securityd
call, so until now no application could complete a securityd connection at all. Keychain, code
signing and trust all went through this.

A PLACEMENT LESSON, learned twice in this file: a probe placed after the first call in a function
cannot tell a throw inside that call from the function never running. Both times the fix was an entry
probe, and both times it changed the answer. Put the first probe before the first thing that can throw.

The fix in commit 8b53add7 does not depend on which of those it is: the modern
`SecCertificateCopyKey` answers correctly, so the legacy answer is only a fallback away.
## Where to look next

`SecCodeCopyPath` still answers `errSecCSBadBundleFormat` for a running client. Nothing depends on it
now, but it means securityd's view of a client's code signature is wrong, and that WILL matter for
anything that actually checks a signature rather than logs one.

`thread_lookup_eternal` and `thread_eternal_id` in `sched.rs` are still stubbed exactly the way the
task pair was, and will fail the same way the moment anything resolves a thread identity token.

Two things worth fixing regardless:

  * `ModuleNexusCommon::do_create` swallowing the real error. Even keeping the generic throw, the
    caught error should be logged, because right now a first failure erases the only evidence and
    the `dispatch_once` makes it unrecoverable for the process.
  * Nothing in this path needs securityd. `MDSSession::DbOpen` contacts it only to wait for system
    MDS data to be installed, and the MDS databases in the prefix are already complete. If the
    handshake cannot be made to work, that wait is the thing to skip.

Then: make the legacy path work, or make it stop being the path.

1. Ship the CSSM plugins. The sources are in the tree already:
   `vendor/src/security/OSX/libsecurity_apple_x509_cl` is the Certificate Library, with
   `libsecurity_apple_csp`, `libsecurity_cssm` and the TP beside it. `AppleX509CL` alone may be
   enough for the certificate key path, which makes it the cheapest thing to try first.
2. If building the plugins is too much, the loader can redirect the symbol, which this tree has done
   before for a stdlib symbol (task #172). Note the limit: a call SecureTransport makes to its OWN
   function inside the same binary is direct and does not go through the symbol table, so a redirect
   helps outside callers and may not help Security talk to itself.

FIXED 2026-09-06 (commit 8b53add7, `vendor/patches/security/0013`): the legacy call now falls back
to `SecCertificateCopyKey`. Measured, `pubkey=-50 key=NULL` became `pubkey=0 key=OK size=256`, and the
handshake moved from `-9808` errSSLBadCert to `-9846` errSSLBadRecordMac.

## Where it stops now: the record we receive, not the one we send

HTTPS still does not work, one layer further along. The record trace names the stopping point, and it
rules out most of what a bad record MAC usually means:

    read want=331 got=331 head=0c 00 01 47 03    ServerKeyExchange, so the exchange is EPHEMERAL
    read want=4   got=4   head=0e 00 00 00       ServerHelloDone
                                                 (we send ClientKeyExchange, ChangeCipherSpec, Finished)
    read want=5   got=5   head=14 03 01 00 01    server ChangeCipherSpec
    read want=48  got=48  head=5a 38 6e 4e ff    server Finished, encrypted, 48 bytes
    SSLHandshake result=-9846                    errSSLBadRecordMac

THE SERVER ANSWERED WITH ChangeCipherSpec AND Finished, NOT AN ALERT. A server that could not verify
the client Finished sends a fatal alert and stops. This one verified ours, so both sides agree on the
premaster secret, the master secret and the client-write keys, and the key exchange is fine.

What fails is the FIRST record we have to decrypt and authenticate in the other direction. So the
fault is in the server-write half of the record protection: the read-side keys, the read sequence
number, or the explicit IV handling.

That also weakens the earlier guess that a missing AppleCSP explains this. If the crypto provider
could not compute, our own Finished would not have verified either.

The record layer here is coretls, which is COMPILED FROM OUR TREE, so this is ours to debug and fix
rather than something to work around.

Do not re-test the read callback, certificate parsing or trust creation. All three are measured good.

## Postscript: proc_pidpath answers the container root for every process

Task #200, found with `CIDER_TRACE_CODESIGN=1` (patches 0026 and 0027). The reason
`SecCodeCopyPath` calls a live client's bundle badly formatted is that it is not looking at the
client's bundle at all:

    bestGuess path=/Volumes/SystemRoot isdir=1
    BundleDiskRep(path) path=/Volumes/SystemRoot bundle=0x7a31ffc7fa20
    setup found nothing signable, resourcesRoot=/Volumes/SystemRoot

`/Volumes/SystemRoot` is the container root. It is a directory, so `bestGuess` takes it for a bundle,
CFBundle happily makes one, and `setup` then finds no main executable in it. Nothing is wrong with
the bundle machinery or with Swift Publisher's bundle.

WHERE THE PATH COMES FROM. `cskernel.cpp` uses `::proc_pidpath(guest->pid(), ...)`, which is
`__proc_info(PROC_PIDPATHINFO)`, which in the guest emulation is `_proc_pidinfo_pathinfo`:

    int rv = dserver_rpc_get_executable_path(pid, args.path, sizeof(args.path), &fullLength);
    ...
    rv = vchroot_unexpand(&args);

The server's `get_executable_path` returns `Process::executable_path`, which is initialised to
`String::new()` and set only by the `set_executable_path` RPC. **Nothing in the tree ever calls that
RPC.** It exists in `generate-rpc-wrappers.py` and is implemented in `handler.rs`, and no guest code
invokes it, so every process's path is the empty string, and `vchroot_unexpand("")` renders as the
container root.

So `proc_pidpath` answers `/Volumes/SystemRoot` for EVERY process in the container. Code signing is
just where it happened to show: crash reporting, LaunchServices, sandboxing and anything else that
asks a pid for its executable get the same wrong answer.

### FIXED: mldr now tells the daemon what it loaded

`src/darwin/loader/src/rpc.rs` gains the `set_executable_path` call (number 25, the one the wire
already defined and nobody sent), and `main.rs` sends it once per process, right after it has
resolved the binary.

IT MUST BE THE HOST PATH, and getting that wrong is worth recording because it looked like a fix.
Sending the guest path (`/Applications/Swift Publisher 5.app/Contents/MacOS/...`) made the
bundle-format error disappear, which read like success. It was not: the emulation runs
`vchroot_unexpand` over whatever is stored, and that maps HOST to GUEST, so a guest path came back
mangled and `SecCodeCopyPath` answered `errSecCSStaticCodeNotFound` (-67068) instead. Only a
positive control caught it, because the failing branch was in a part of the code the probes did not
cover, and its silence read as success.

Measured with the host path, and this is the positive control, not an absence:

    [mldr] set_executable_path(/tmp/cider-sp-1000/prefix/Applications/Swift Publisher 5.app/Contents/MacOS/Swift Publisher 5) -> 0
    bestGuess path=/Applications/Swift Publisher 5.app/Contents/MacOS/Swift Publisher 5 isdir=0
    bestGuess exec-url bundle=0x71ed7ac7fa20
    codePath -> /Applications/Swift Publisher 5.app

So `proc_pidpath` answers the real executable, `bestGuess` recognises it as a bundle's main
executable, and securityd identifies its client as the application bundle. All five roster
applications still render and resize, LOOKED at.

WHAT THIS DOES NOT COVER: guest `execve`. mldr sends the path when it loads an image, which is the
initial exec of every process here, but a process that execs through the emulation without a fresh
mldr would keep its parent's path. Nothing in the roster does that today.

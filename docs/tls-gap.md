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

WHERE THE FAILURE ACTUALLY IS, narrowed twice by measurement:

  * The legacy ItemImpl certificate IS created. `CIDER_TRACE_SECCERT=1` prints `ItemImpl create -> OK`
    with a positive control on that line, so its silence would have been readable.
  * `Certificate::publicKey()` is NEVER REACHED. The same switch prints `publicKey CL field -> ...` on
    entry to that function and that line never appears, in a run where the ItemImpl line does. So the
    throw is not in the CL field extraction and not in the CSP either.

That leaves the step BETWEEN them, `Certificate::required(__itemImplRef)`, the handle to object lookup
that BEGIN_SECCERTAPI performs on the reference it just created. A freshly created ItemImpl whose
handle does not resolve is a lifetime or registration question, and it is the next thing to look at:
`SecCertificateCreateItemImplInstance` returns `certificatePtr->handle()` from a SecPointer that goes
out of scope on the next line, so whether `handle()` hands out an owning reference is the question.

That is as far as this went. NOT localised further, and the fix does not depend on it.

The fix in commit 8b53add7 does not depend on which of those it is: the modern
`SecCertificateCopyKey` answers correctly, so the legacy answer is only a fallback away.
## Where to look next

Make the legacy path work, or make it stop being the path.

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

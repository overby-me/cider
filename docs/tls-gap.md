# The TLS gap: a handshake that runs and rejects the certificate

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

## The provenance trap, which cost real time

The TLS engine is APPLE PREBUILT, not built from `vendor/src/security`. The built Security.framework
contains no string from `OSX/libsecurity_ssl` (no `parseIncomingCerts`, no `empty incoming cert
array`) and defines no coretls symbol (`tls_handshake_negotiate` is absent). It is also not a dev stub
(zero STUB strings). Reading `vendor/src/security` to explain the error is reading code that is not in
the build, and that is exactly the detour this investigation took before checking. Check what is in
the binary first.

## Where to look next

Both of the obvious candidates are now dead: the bytes are right, and the certificate is ordinary. So
the rejection is something SecureTransport does with correct input, inside prebuilt Apple code, and
the next probe has to be in there rather than around it.

The most direct question is whether `SecCertificateCreateWithData` works at all under cider. If it
returns NULL for a perfectly good DER certificate, every chain is a bad certificate and the verdict
follows with no mystery. Two ways in:

1. From our own code, which already links Security: call it from CFNetwork on a certificate we
   construct, and print whether the result is NULL. A self test beats a hook, and it needs no
   symbolication.
2. In the prebuilt binary, the way `symbolicate a prebuilt dylib from your own trace` describes:
   anchor the slide with one dlsym of a known export, then break on the certificate entry points.

Do not go back to `vendor/src/security` for the answer, and do not re-test the read callback.

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

## The provenance trap, which cost real time

The TLS engine is APPLE PREBUILT, not built from `vendor/src/security`. The built Security.framework
contains no string from `OSX/libsecurity_ssl` (no `parseIncomingCerts`, no `empty incoming cert
array`) and defines no coretls symbol (`tls_handshake_negotiate` is absent). It is also not a dev stub
(zero STUB strings). Reading `vendor/src/security` to explain the error is reading code that is not in
the build, and that is exactly the detour this investigation took before checking. Check what is in
the binary first.

## Where to look next

The failure is on the decode side of the certificate, inside prebuilt Apple code. Two candidates, in
order:

1. The bytes SecureTransport is handed are not the bytes on the wire. The read callback is ours:
   `_SecurityReadFunc_NoLock` in `CFSocketStream.c`, which buffers and returns `errSSLWouldBlock` on a
   partial read. A length or offset error there would present as a malformed certificate.
2. The certificate itself is one this vintage of SecureTransport will not parse. The peer is a modern
   server, so a signature algorithm or extension it predates is plausible.

Trace inside the prebuilt binary the way `symbolicate a prebuilt dylib from your own trace` describes:
anchor the slide with one dlsym of a known export, then hook the certificate entry points and see
which call produces the verdict. Do not go back to `vendor/src/security` for the answer.

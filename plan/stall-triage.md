# Stall triage

Stalls (hangs, not crashes) are the signature failure mode of a subtly-wrong
kernel shim under Darling: the guest process blocks forever in a wait that never
wakes. Prime suspects: kqueue/kevent fidelity, poll/select edge semantics, Mach
IPC waits through darlingserver, and futex/ulock. Campaign 1's
`fixPythonPipStalling` branch is the known example of this class.

## Protocol

Wrap long guest invocations in `scripts/with-watchdog.sh` (timeout + gdb stack
capture of the guest tree and darlingserver). On a stall, capture:
- `thread apply all bt` for the guest process(es) and darlingserver
- `/proc/<pid>/wchan` and `/proc/<pid>/stack`
- what syscall/IPC the top frame is blocked in

File each distinct signature below with a minimal reproducer.

## Known suspects (from Campaign 1 / upstream)

- **libkqueue EVFILT_TIMER** — upstream `b0795a2e` reworks `evfilt_timer_knote_enable`
  to program the timerfd directly (fixes type-punning/behaviour). libdispatch
  timers ride libkqueue under Darling, so timer-driven waits are suspect. Adopt
  that fix (plan/upstream-adoption.md) if a timer stall appears.

## Signatures

_(none recorded yet — populate as they occur)_

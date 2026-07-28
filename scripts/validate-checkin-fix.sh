#!/usr/bin/env bash
# Validate the checkin lifetime-pipe-leak fix: rebuild darlingserverd against the freshly
# regenerated duct-tape lib, splice it, run the toolchain-path hello build, and confirm the
# daemon's pipe-fd count stays FLAT (no leak) and the build reaches "Hello, world!" (i.e. the
# config.status hang is gone). Restores the C++ daemon afterward.
set -u
REPO=/home/overby.me/Work/darling-nix
RT=/home/overby.me/darling-rt
LIB=/home/overby.me/m1roots/ds-consume/rust-consume/lib
BT=/nix/store/v6wk45fap70cgcw88x4ilzkiwzhwq6r0-bootstrap-tools
SDK=/nix/store/dfd1kijwi4r02dk8ridqwmx1vzfg7dik-apple-sdk-14.4/Platforms/MacOSX.platform/Developer/SDKs/MacOSX14.4.sdk
HSRC=/nix/store/wj7phsmi7ncidl8k00p489krqss7n9sd-hello-2.12.3.tar.gz

[ -f "$LIB/libdarlingserver_duct_tape.a" ] || { echo "duct-tape lib not present at $LIB"; exit 2; }

echo "=== cargo build with fix (DUCT_TAPE_LIB=$LIB) ==="
export PATH="/nix/store/1vna555h23v6s4v00gaz5kh1ynva6vj0-rust-default-1.96.0/bin:$PATH"
export LIBCLANG_PATH="/nix/store/7306wrcri9nmdp7w4pbqc5rqdn6y048d-clang-21.1.8-lib/lib"
export DUCT_TAPE_LIB="$LIB"
export CC=clang CARGO_HOME="$HOME/.cargo" CARGO_NET_OFFLINE=true
cd "$REPO/linux/server" || exit 3
cargo build --bin darlingserverd 2>&1 | tail -4
BIN="$REPO/linux/server/target/debug/darlingserverd"
[ -x "$BIN" ] || { echo "cargo build failed"; exit 4; }

echo "=== splice fixed Rust daemon ==="
for p in /proc/[0-9]*; do ex=$(readlink "$p/exe" 2>/dev/null); case "$ex" in *darling-rt/bin/darlingserver*) kill -9 "${p#/proc/}" 2>/dev/null;; esac; done
pkill -9 -x mldr 2>/dev/null; pkill -9 -x shellspawn 2>/dev/null; sleep 1
cp "$BIN" "$RT/bin/darlingserver" || { echo "splice cp failed"; exit 5; }
rm -f /home/overby.me/.wnix/.darlingserver.sock /home/overby.me/.wnix/.init.pid
echo "daemon sha: $(sha1sum "$RT/bin/darlingserver" | cut -c1-12)"

echo "=== run toolchain M1 (background) ==="
rm -f /tmp/validate-fix.log
DPREFIX=/home/overby.me/.wnix DARLING_NO_LAUNCHD=1 \
  DSERVER_LIBEXEC_PATH="$RT/libexec/darling" DSERVER_MLDR_PATH="$RT/libexec/darling/usr/libexec/darling/mldr" \
  timeout 600 "$REPO/result-launcher-spliced/src/startup/darling" shell sh -c "
    export PATH=$BT/bin:/usr/bin:/bin SDKROOT=$SDK CC=clang
    export CFLAGS='-isysroot $SDK -Wno-implicit-function-declaration' LDFLAGS='-isysroot $SDK'
    export CONFIG_SHELL=$BT/bin/bash SHELL=$BT/bin/bash HOME=/Users/root
    unset CONFIG_SITE
    cd \$HOME; rm -rf tbuild tmp; mkdir -p tbuild tmp; export TMPDIR=\$HOME/tmp
    cd tbuild; tar xzf $HSRC; cd hello-2.12.3
    \$CONFIG_SHELL ./configure >conf.log 2>&1; echo configure_rc=\$?
    make >make.log 2>&1; echo make_rc=\$?; ./hello; echo hello_rc=\$?
  " > /tmp/validate-fix.log 2>&1 &
RUNPID=$!
echo "build pid=$RUNPID; sampling daemon pipe-fd count every 30s ..."
for i in $(seq 1 18); do
  sleep 30
  dpid=$(for p in /proc/[0-9]*; do ex=$(readlink "$p/exe" 2>/dev/null); case "$ex" in *darling-rt/bin/darlingserver*) echo "${p#/proc/}"; break;; esac; done)
  pc=$([ -n "$dpid" ] && ls /proc/$dpid/fd 2>/dev/null | xargs -I{} readlink /proc/$dpid/fd/{} 2>/dev/null | grep -c pipe: || echo "?")
  mk=$(ls /home/overby.me/.wnix/Users/root/tbuild/hello-2.12.3/Makefile 2>/dev/null && echo yes || echo no)
  echo "t=$((i*30))s daemon_pipe_fds=$pc Makefile=$mk markers=[$(grep -aoE 'configure_rc=[0-9]+|make_rc=[0-9]+|hello_rc=[0-9]+' /tmp/validate-fix.log 2>/dev/null | tr '\n' ' ')] hello=[$(grep -ac 'Hello, world' /tmp/validate-fix.log)]"
  grep -aq 'hello_rc=' /tmp/validate-fix.log 2>/dev/null && break
done
echo "=== FINAL ==="; grep -aE 'configure_rc|make_rc|hello_rc|Hello, world' /tmp/validate-fix.log | head
echo "=== restore C++ ==="
for p in /proc/[0-9]*; do ex=$(readlink "$p/exe" 2>/dev/null); case "$ex" in *darling-rt/bin/darlingserver*) kill -9 "${p#/proc/}" 2>/dev/null;; esac; done
pkill -9 -x mldr 2>/dev/null; pkill -9 -x shellspawn 2>/dev/null; sleep 1
cp "$RT/bin/darlingserver.cpp-bak" "$RT/bin/darlingserver" && echo "C++ restored"

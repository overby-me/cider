# The FRAMEWORK-TIER endpoint target list: the same tier/test set as buck2-targets-min.nix, but it
# lowers the framework prefix (//buck/prefix-fw) instead of the minimal one. That prefix keeps the
# CoreFoundation/CoreServices/SystemConfiguration/Foundation stack (and its re-export closure) that
# guest nix loads, minus the two framework dylibs that do not build for arm64 (JavaScriptCore,
# DBusKit). Lowering the prefix target pulls its whole transitive closure, so only the prefix line
# differs from the minimal list.
[
  "//src/darwin/libsimple:libsimple_ciderd"
  "//src/darwin/libsimple:libsimple_cider"
  "//vendor/src:migcom"
  "//src/linux/startup:rtsig_header"
  "//vendor/pins/ciderd:dserver_rpc"
  "//vendor/pins/ciderd/xnu-sys:ciderd_xnu_sys"
  "//vendor/pins/ciderd/tools:dserverdbg"
  "//src/linux/server:xnu_sys_lib"
  "//src/darwin/libsimple:libsimple_cider_dylib"
  "//tests/buck2/firstpass:a"
  "//tests/buck2/firstpass:b"
  "//tests/buck2/firstpass:umbrella"
  "//vendor/src:system_blocks_firstpass"
  "//vendor/src:keymgr_firstpass"
  "//vendor/src:system_malloc_firstpass"
  "//vendor/src:system_pthread_firstpass"
  "//vendor/src/libc:system_c_firstpass"
  "//vendor/src/xnu:system_kernel_firstpass"
  "//vendor/src:system_blocks_final"
  "//vendor/src/xnu:system_kernel_final"
  "//vendor/src/libplatform:platform_firstpass"
  "//vendor/src:compiler_rt_firstpass"
  "//vendor/src:system_dyld_firstpass"
  "//vendor/src:system_asl_firstpass"
  "//vendor/src:system_coretls_firstpass"
  "//vendor/src:asl_ipc_mig"
  "//src/darwin/duct:system_duct_firstpass"
  "//vendor/pins/libtrace:system_trace_firstpass"
  "//src/darwin/libsystem_coreservices:system_coreservices_firstpass"
  # The FRAMEWORK prefix: min + the framework stack guest nix loads, minus JavaScriptCore/DBusKit.
  "//buck/prefix-fw:cider_prefix_fw"
]

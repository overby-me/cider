# The MINIMAL endpoint target list: the same as buck2-targets.nix except it lowers the
# minimal prefix. Kept in one place because both the graph attribute and the lowered one
# need the same list. It is the suite's list
# (scripts/buck-test.nu): the set already known to build, spanning host tier, guest
# tier, MIG codegen and the firstpass/final link pair.
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
  # The MINIMAL prefix, not the full one. Same layout minus the GUI frameworks, the
  # private frameworks and the scripting languages, which together are 42 percent of the
  # graph and none of which the goal needs: a prefix that boots, runs bash, and can run
  # nix to build things. Parity keeps the full prefix in buck2-targets.nix.
  "//buck/prefix-min:cider_prefix_min"
]

# The MINIMAL endpoint target list: the same as buck2-targets.nix except it lowers the
# minimal prefix. Kept in one place because both the graph attribute and the lowered one
# need the same list. It is the suite's list
# (scripts/buck-test.nu): the set already known to build, spanning host tier, guest
# tier, MIG codegen and the firstpass/final link pair.
[
  "//darwin/libsimple:libsimple_ciderd"
  "//darwin/libsimple:libsimple_cider"
  "//buck-src:migcom"
  "//linux/startup:rtsig_header"
  "//src/external/ciderd:dserver_rpc"
  "//src/external/ciderd/xnu-sys:ciderd_xnu_sys"
  "//src/external/ciderd/tools:dserverdbg"
  "//linux/server:xnu_sys_lib"
  "//darwin/libsimple:libsimple_cider_dylib"
  "//tests/buck2/firstpass:a"
  "//tests/buck2/firstpass:b"
  "//tests/buck2/firstpass:umbrella"
  "//buck-src:system_blocks_firstpass"
  "//buck-src:keymgr_firstpass"
  "//buck-src:system_malloc_firstpass"
  "//buck-src:system_pthread_firstpass"
  "//buck-src/libc:system_c_firstpass"
  "//buck-src/xnu:system_kernel_firstpass"
  "//buck-src:system_blocks_final"
  "//buck-src/xnu:system_kernel_final"
  "//buck-src/libplatform:platform_firstpass"
  "//buck-src:compiler_rt_firstpass"
  "//buck-src:system_dyld_firstpass"
  "//buck-src:system_asl_firstpass"
  "//buck-src:system_coretls_firstpass"
  "//buck-src:asl_ipc_mig"
  "//darwin/duct:system_duct_firstpass"
  "//src/external/libtrace:system_trace_firstpass"
  "//darwin/libsystem_coreservices:system_coreservices_firstpass"
  # The MINIMAL prefix, not the full one. Same layout minus the GUI frameworks, the
  # private frameworks and the scripting languages, which together are 42 percent of the
  # graph and none of which the goal needs: a prefix that boots, runs bash, and can run
  # nix to build things. Parity keeps the full prefix in buck2-targets.nix.
  "//buck/prefix-min:cider_prefix_min"
]

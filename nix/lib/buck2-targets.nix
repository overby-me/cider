# The targets the Nix endpoint dumps a graph for, kept in one place because both the
# graph attribute and the lowered one need the same list. It is the suite's list
# (scripts/buck-test.nu): the set already known to build, spanning host tier, guest
# tier, MIG codegen and the firstpass/final link pair.
[
  "//darwin/libsimple:libsimple_ciderd"
  "//darwin/libsimple:libsimple_cider"
  "//vendor/src:migcom"
  "//linux/startup:rtsig_header"
  "//vendor/pins/ciderd:dserver_rpc"
  "//vendor/pins/ciderd/xnu-sys:ciderd_xnu_sys"
  "//vendor/pins/ciderd/tools:dserverdbg"
  "//linux/server:xnu_sys_lib"
  "//darwin/libsimple:libsimple_cider_dylib"
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
  "//darwin/duct:system_duct_firstpass"
  "//vendor/pins/libtrace:system_trace_firstpass"
  "//darwin/libsystem_coreservices:system_coreservices_firstpass"
  # The PREFIX: what a Darling install actually is, and the target the bash milestone
  # runs from. It pulls in every dylib, executable and data file the layout installs, so
  # it is also by far the widest thing this endpoint is asked to lower.
  "//buck/prefix:cider_prefix"
]

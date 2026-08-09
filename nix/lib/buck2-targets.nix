# The targets the Nix endpoint dumps a graph for, kept in one place because both the
# graph attribute and the lowered one need the same list. It is the suite's list
# (scripts/buck-test.nu): the set already known to build, spanning host tier, guest
# tier, MIG codegen and the firstpass/final link pair.
[
  "//src/libsimple:libsimple_darlingserver"
  "//src/libsimple:libsimple_darling"
  "//buck-src:migcom"
  "//src/startup:rtsig_header"
  "//src/external/darlingserver:dserver_rpc"
  "//src/external/darlingserver/xnu-sys:darlingserver_duct_tape"
  "//src/external/darlingserver/tools:dserverdbg"
  "//linux/server:duct_tape_lib"
  "//src/libsimple:libsimple_darling_dylib"
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
  "//src/duct:system_duct_firstpass"
  "//src/external/libtrace:system_trace_firstpass"
  "//src/libsystem_coreservices:system_coreservices_firstpass"
  # The PREFIX: what a Darling install actually is, and the target the bash milestone
  # runs from. It pulls in every dylib, executable and data file the layout installs, so
  # it is also by far the widest thing this endpoint is asked to lower.
  "//buck/prefix:darling_prefix"
]

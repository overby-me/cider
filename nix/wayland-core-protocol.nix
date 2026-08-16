# The CORE Wayland protocol XML, which nixpkgs does not ship in any output of `wayland`.
#
# WHY THIS IS NEEDED AT ALL, and it is a consequence of how this fork reaches host libraries.
# A guest Mach-O binary cannot link an ELF .so, so wrapgen generates a forwarding stub per host
# library. A stub forwards FUNCTIONS, which is all a jump can do: measured on the generated
# libwayland-client.dylib, wl_display_connect, wl_display_roundtrip, wl_proxy_marshal_flags and
# wl_proxy_add_listener are all there, and the DATA symbols are not:
#
#     wl_registry_interface        0
#     wl_compositor_interface      0
#
# Those are `const struct wl_interface` objects, and every protocol call needs one. The ordinary
# way a Wayland client gets them is by linking libwayland-client, which is exactly what a Mach-O
# guest cannot do.
#
# So the interfaces are GENERATED LOCALLY instead, from the same XML upstream generates them from,
# with the same wayland-scanner. That is the standard mechanism for protocol EXTENSIONS
# (xdg-shell already works this way); this only extends it to the core protocol.
#
# The XML lives in the wayland source tarball under protocol/, and in no installed output, hence
# the unpack.
{ pkgs }:
pkgs.runCommand "wayland-core-protocol"
{
  meta.description = "protocol/wayland.xml, extracted from the wayland source";
} ''
  mkdir -p "$out"
  tar -xf ${pkgs.wayland.src} -C .
  cp wayland-*/protocol/wayland.xml "$out/wayland.xml"
''

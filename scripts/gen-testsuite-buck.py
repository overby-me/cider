#!/usr/bin/env python3
"""Emit BUCK targets for darling-testsuite cases (task #123).

The upstream suite registers each case twice in CMake, once as an executable and once as a test:

    add_executable("${DARLING_IDENTIFIER}.test_x" "test/test_x.m")
    add_test(NAME "${DARLING_PATH}/test_x" COMMAND "${DARLING_IDENTIFIER}.test_x")

so the case list is already written down and does not need inventing. This walks the materialised
tree instead of parsing CMake, because the sources ARE the list and a file that exists but is not
registered is still a case we can run.

Every case becomes two targets, an object and a guest binary, because that is the shape this port
already builds and runs. They share one dependency list: a Foundation-using guest target needs the
whole framework root set, not just fw_Foundation, or the headers cascade one missing framework per
build. On top of that base each case also gets the headers AND THE DYLIB of the framework its own
path names, which is the only way a case can resolve the symbols it was written to check.

Usage: scripts/gen-testsuite-buck.py [--appkit] > block.bzl
       --appkit also emits the AppKit cases, which link AppKit and want a display.

C cases are included: CoreFoundation provides CGFloat and the geometry structs now (task #128), so
a plain C file that includes only CoreFoundation compiles the way it does on a real system.
"""
import os
import sys

ROOT = "vendor/src/darling-testsuite"
TESTS = f"{ROOT}/testsuite"
LIBXPC = "usr/lib/system/libxpc.dylib"

FRAMEWORK_DEPS = [
    "//vendor/src:fw_Foundation",
    "//vendor/src:fw_CoreFoundation",
    "//vendor/src:fw_Security",
    "//vendor/src:fw_CFNetwork",
    "//vendor/src:fw_CoreGraphics",
    "//vendor/src:fw_CoreText",
    "//vendor/src:fw_CoreData",
    "//src/darwin/frameworks:fw_AE",
    "//src/darwin/frameworks:fw_ATS",
    "//src/darwin/frameworks:fw_ApplicationServices",
    "//src/darwin/frameworks:fw_CarbonCore",
    "//src/darwin/frameworks:fw_ColorSync",
    "//src/darwin/frameworks:fw_ColorSyncLegacy",
    "//src/darwin/frameworks:fw_CoreServices",
    "//src/darwin/frameworks:fw_FSEvents",
    "//src/darwin/frameworks:fw_HIServices",
    "//src/darwin/frameworks:fw_ImageIO",
    "//src/darwin/frameworks:fw_LangAnalysis",
    "//src/darwin/frameworks:fw_LaunchServices",
    "//src/darwin/frameworks:fw_OpenGL",
    "//src/darwin/frameworks:fw_PrintCore",
    "//src/darwin/frameworks:fw_QD",
    "//src/darwin/frameworks:fw_SearchKit",
    "//src/darwin/frameworks:fw_SpeechSynthesis",
]

DYLIBS = [
    "//vendor/src:system_final",
    "//vendor/src/corefoundation:CoreFoundation_dylib",
    "//vendor/src:Foundation_dylib",
]

# WITHOUT THE DYLIB HALF a case compiles and then cannot resolve the very constants it was written
# to check. That is why the kCG*, kLS* and Sec* symbols read as missing exports for so long when
# every one of them is defined and exported.
# Header and dylib are not always in the same package (SystemConfiguration splits them), and
# Security's dylib target is Security_final, so both halves are spelled out per framework.
FW = "//src/darwin/frameworks"
CASE_FRAMEWORKS = {
    "AVFoundation": (f"{FW}:fw_AVFoundation", f"{FW}:AVFoundation_dylib"),
    "AddressBook": (f"{FW}:fw_AddressBook", f"{FW}:AddressBook_dylib"),
    "AppKit": ("//vendor/src:fw_AppKit", "//vendor/src:AppKit_dylib"),
    "Carbon": (f"{FW}:fw_Carbon", f"{FW}:Carbon_dylib"),
    "CoreBluetooth": (f"{FW}:fw_CoreBluetooth", f"{FW}:CoreBluetooth_dylib"),
    "CoreGraphics": ("//vendor/src:fw_CoreGraphics", "//vendor/src:CoreGraphics_dylib"),
    "CoreImage": (f"{FW}:fw_CoreImage", f"{FW}:CoreImage_dylib"),
    "CoreMIDI": (f"{FW}:fw_CoreMIDI", f"{FW}:CoreMIDI_dylib"),
    "CoreMedia": (f"{FW}:fw_CoreMedia", f"{FW}:CoreMedia_dylib"),
    "CoreServices": (f"{FW}:fw_CoreServices", f"{FW}:CoreServices_dylib"),
    "CoreText": ("//vendor/src:fw_CoreText", "//vendor/src:CoreText_dylib"),
    "CoreVideo": (f"{FW}:fw_CoreVideo", f"{FW}:CoreVideo_dylib"),
    "Foundation": ("//vendor/src:fw_Foundation", "//vendor/src:Foundation_dylib"),
    "HIToolbox": (f"{FW}:fw_HIToolbox", f"{FW}:HIToolbox_dylib"),
    "ImageCaptureCore": (f"{FW}:fw_ImageCaptureCore", f"{FW}:ImageCaptureCore_dylib"),
    "ImageIO": (f"{FW}:fw_ImageIO", f"{FW}:ImageIO_dylib"),
    "InstantMessage": (f"{FW}:fw_InstantMessage", f"{FW}:InstantMessage_dylib"),
    "LaunchServices": (f"{FW}:fw_LaunchServices", f"{FW}:LaunchServices_dylib"),
    "PDFKit": (f"{FW}:fw_PDFKit", f"{FW}:PDFKit_dylib"),
    "QuartzCore": ("//vendor/src:fw_QuartzCore", "//vendor/src:QuartzCore_dylib"),
    "SearchKit": (f"{FW}:fw_SearchKit", f"{FW}:SearchKit_dylib"),
    "Security": ("//vendor/src:fw_Security", "//vendor/src:Security_final"),
    "SystemConfiguration": (
        "//vendor/src:fw_SystemConfiguration",
        f"{FW}:SystemConfiguration_dylib",
    ),
    "UIFoundation": (
        "//src/darwin/private-frameworks:fw_UIFoundation",
        "//src/darwin/private-frameworks:UIFoundation_dylib",
    ),
    "VideoToolbox": (f"{FW}:fw_VideoToolbox", f"{FW}:VideoToolbox_dylib"),
    "WebKit": (f"{FW}:fw_WebKit", f"{FW}:WebKit_dylib"),
    # PubSub deliberately absent: the framework does not exist here, and that case is the
    # negative control scripts/run-dts-case.sh relies on.
}

# A FRAMEWORK UMBRELLA INCLUDES OTHER UMBRELLAS, and the case only names its own framework, so the
# path rule alone stops one header short. Each entry is the framework the compiler actually asked
# for, taken from the "file not found" it reported, not from reading the umbrella and guessing.
EXTRA_HEADERS = {
    "AVFoundation": [f"{FW}:fw_AVFAudio"],
    "Carbon": [f"{FW}:fw_HIToolbox"],
    "PDFKit": [f"{FW}:fw_Quartz"],
    "QuartzCore": [f"{FW}:fw_CoreVideo", "//vendor/src:fw_Metal"],
    # WebKit reaches AppKit through Cocoa, and AppKit.h reaches QuartzCore, which is the same hop
    # APPKIT_HEADERS exists for. A WebKit case is not an AppKit case, so it needs them spelled out.
    "WebKit": ["//vendor/src:fw_Cocoa", "//vendor/src:fw_AppKit", "//vendor/src:fw_QuartzCore",
               "//vendor/src:fw_Onyx2D"],
}

# AN APPKIT CASE LINKS APPKIT, and only an AppKit case does: pulling the GUI framework into a libc
# test would drag the whole display path into something that has no business touching it.
APPKIT_DYLIBS = DYLIBS + ["//vendor/src:AppKit_dylib"]
APPKIT_HEADERS = [
    "//vendor/src:fw_AppKit",
    "//vendor/src:fw_Onyx2D",
    # AppKit.h reaches QuartzCore, so without this every AppKit case stops at
    # "QuartzCore/CIImage.h file not found" before it has said anything about AppKit at all.
    "//vendor/src:fw_QuartzCore",
]


def case_frameworks(rel):
    """(headers, dylibs) for every framework named in a case's own path.

    Frameworks nest: a LaunchServices case sits under CoreServices.framework/Frameworks/
    LaunchServices.framework, and taking just one component picks the wrong one either way.
    """
    headers, dylibs = [], []
    for part in rel.split("/"):
        if not part.endswith(".framework"):
            continue
        name = part[: -len(".framework")]
        pair = CASE_FRAMEWORKS.get(name)
        if pair:
            headers.append(pair[0])
            dylibs.append(pair[1])
        headers.extend(EXTRA_HEADERS.get(name, []))
    return headers, dylibs


def target_name(rel):
    """A buck target name from a case path: unique, and readable in a failure list."""
    stem = rel[len(TESTS) + 1 :]
    stem = stem.replace("/", "_").replace(".m", "").replace(".c", "")
    for ch in "().-+ ":
        stem = stem.replace(ch, "_")
    while "__" in stem:
        stem = stem.replace("__", "_")
    return "dts_" + stem.strip("_")


def will_fail_cases():
    """Case names upstream marks as EXPECTED TO FAIL.

    CTest carries this as a property beside the test, not in the source:

        set_property(TEST "${DARLING_PATH}/test_exit_return_1" PROPERTY WILL_FAIL true)

    and test_exit_return_1 is exactly what it sounds like, a main that calls exit(1). A runner that
    treats every non-zero exit as a failure reports that one as broken, which is how it was counted
    here first. Read the property rather than the exit code.
    """
    names = set()
    for base, _dirs, files in os.walk(TESTS):
        if "CMakeLists.txt" not in files:
            continue
        body = open(os.path.join(base, "CMakeLists.txt"), errors="replace").read()
        for line in body.split("\n"):
            if "WILL_FAIL" not in line:
                continue
            start = line.find('"')
            end = line.find('"', start + 1)
            if start < 0 or end < 0:
                continue
            names.add(line[start + 1 : end].rsplit("/", 1)[-1])
    return names


# CASES WHOSE BODY IS A PLACEHOLDER UPSTREAM. test_NSColor_colorUsingColorSpaceNamedevice is fifty
# lines of commented-out intentions and then exit(1), and CMake does NOT mark it WILL_FAIL, so it
# fails in upstream's own CI exactly as it fails here. It was counted as an AppKit divergence of
# this port for a while, which it never was: nothing in it touches our AppKit at all.
# Bodies upstream has not written: every line is commented out and main just exits 1. Upstream
# registers them as ordinary tests with no WILL_FAIL, so they fail on real macOS too. They cannot
# pass here and are not evidence of anything about this port.
UPSTREAM_PLACEHOLDERS = {
    "test_NSColor_colorUsingColorSpaceNamedevice",
}


def main():
    want_appkit = "--appkit" in sys.argv
    if "--willfail" in sys.argv:
        for n in sorted(will_fail_cases()):
            print(n)
        return
    if "--placeholders" in sys.argv:
        for n in sorted(UPSTREAM_PLACEHOLDERS):
            print(n)
        return
    cases = []
    for base, _dirs, files in os.walk(TESTS):
        for f in sorted(files):
            if not f.endswith((".m", ".c")):
                continue
            rel = os.path.join(base, f)
            if "AppKit.framework" in rel and not want_appkit:
                continue
            # NOT EVERY SOURCE FILE IS A CASE. libxpc.dylib/src/helper/*.c is a library CMake builds
            # into libxpc_helper_tools and links into the cases; wired as binaries they have no main
            # and fail at link, which reads as a broken test and is a broken rule.
            if LIBXPC in rel and f"{LIBXPC}/src/" in rel:
                continue
            # SKIP THE CASES THAT NEED A GENERATED HEADER. The libxpc group ships
            # include/test_shared_data.h.in and its CMakeLists runs configure_file over it, so the
            # header only exists inside a CMake build. Five automated cases include it, four of them
            # client halves that need a launchd-registered server, so wiring configure_file is its
            # own step and worth one case on its own.
            try:
                body = open(rel, "rb").read()
            except OSError:
                continue
            if b"test_shared_data.h" in body:
                continue
            cases.append(rel)
    cases.sort()

    out = []
    out.append("# BEGIN GENERATED by scripts/gen-testsuite-buck.py -- do not edit by hand.")
    expect_fail = will_fail_cases()
    out.append(f"# {len(cases)} cases.")
    out.append("# Cases whose body upstream has not written yet (exit(1) and nothing else):")
    for n in sorted(UPSTREAM_PLACEHOLDERS):
        out.append(f"#   {n}")
    out.append("# Cases upstream marks WILL_FAIL, where a non-zero exit IS the pass:")
    for n in sorted(expect_fail):
        out.append(f"#   {n}")
    for rel in cases:
        name = target_name(rel)
        is_appkit = "AppKit.framework" in rel
        is_libxpc = LIBXPC in rel
        own_headers, own_dylibs = case_frameworks(rel)
        out.append("")
        out.append("cc_objects(")
        out.append(f'    name = "{name}_obj",')
        out.append("    srcs = [")
        out.append(f'        "{rel[len("vendor/src/"):]}",')
        out.append("    ],")
        out.append('    compiler_flags = ["-O2", "-Wall"],')
        out.append('    toolchain = "toolchains//:darwin_cc",')
        out.append("    deps = [")
        out.append('        "//src/darwin:sdk_env",')
        for d in FRAMEWORK_DEPS:
            out.append(f'        "{d}",')
        if is_appkit:
            for d in APPKIT_HEADERS:
                out.append(f'        "{d}",')
        emitted = set(FRAMEWORK_DEPS) | (set(APPKIT_HEADERS) if is_appkit else set())
        for h in own_headers:
            if h not in emitted:
                emitted.add(h)
                out.append(f'        "{h}",')
        out.append('        ":darling_testsuite_inc",')
        if is_libxpc:
            out.append('        ":libxpc_testsuite_inc",')
        out.append("    ],")
        out.append('    visibility = ["PUBLIC"],')
        out.append(")")
        out.append("")
        out.append("darwin_binary(")
        out.append(f'    name = "{name}",')
        out.append("    objs = [")
        out.append(f'        ":{name}_obj",')
        out.append('        ":darling_testsuite_lib_obj",')
        if is_libxpc:
            out.append('        ":libxpc_helper_tools_obj",')
        out.append('        "//vendor/src/csu:crt1.10.6_obj2",')
        out.append("    ],")
        out.append("    dylibs = [")
        linked = list(APPKIT_DYLIBS if is_appkit else DYLIBS)
        for d in own_dylibs:
            if d not in linked:
                linked.append(d)
        for d in linked:
            out.append(f'        "{d}",')
        out.append("    ],")
        out.append('    toolchain = "toolchains//:darwin_cc",')
        out.append('    deps = ["//src/darwin:sdk_env"],')
        out.append('    visibility = ["PUBLIC"],')
        out.append(")")
    out.append("")
    out.append("# END GENERATED")
    print("\n".join(out))


if __name__ == "__main__":
    main()

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
build.

Usage: scripts/gen-testsuite-buck.py [--appkit] > block.bzl
       --appkit also emits the AppKit cases, which link AppKit and want a display.

C cases are included: CoreFoundation provides CGFloat and the geometry structs now (task #128), so
a plain C file that includes only CoreFoundation compiles the way it does on a real system.
"""
import os
import sys

ROOT = "vendor/src/darling-testsuite"
TESTS = f"{ROOT}/testsuite"

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


def main():
    want_appkit = "--appkit" in sys.argv
    if "--willfail" in sys.argv:
        for n in sorted(will_fail_cases()):
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
            # SKIP THE CASES THAT NEED A GENERATED HEADER. The libxpc group ships
            # include/test_shared_data.h.in and its CMakeLists runs configure_file over it, so the
            # header only exists inside a CMake build. Eighteen cases include it and every one of
            # them fails with "test_shared_data.h file not found", which reads like a missing API
            # and is nothing of the kind. Wiring the configure_file rule for them is its own step.
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
    out.append("# Cases upstream marks WILL_FAIL, where a non-zero exit IS the pass:")
    for n in sorted(expect_fail):
        out.append(f"#   {n}")
    for rel in cases:
        name = target_name(rel)
        is_appkit = "AppKit.framework" in rel
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
        out.append('        ":darling_testsuite_inc",')
        out.append("    ],")
        out.append('    visibility = ["PUBLIC"],')
        out.append(")")
        out.append("")
        out.append("darwin_binary(")
        out.append(f'    name = "{name}",')
        out.append("    objs = [")
        out.append(f'        ":{name}_obj",')
        out.append('        ":darling_testsuite_lib_obj",')
        out.append('        "//vendor/src/csu:crt1.10.6_obj2",')
        out.append("    ],")
        out.append("    dylibs = [")
        for d in (APPKIT_DYLIBS if is_appkit else DYLIBS):
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

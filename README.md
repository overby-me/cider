# Cider

**Cider Isn't Darwin Emulation, Really.**

Cider is a runtime environment for macOS applications. It is a fork of
[Darling](https://github.com/darlinghq/darling), whose copyright and history it keeps.

Please note that most GUI applications will not run at the moment.

## Download

Cider is developed at [tangled.org/overby.me/cider](https://tangled.org/overby.me/cider).

Prebuilt packages are not published yet. Build it from source, see below.

## Build Instructions

Cider builds with Nix and buck2:

````
nix build .#cider-buck2-prefix-min
````

The upstream Darling build instructions at
[docs.darlinghq.org](https://docs.darlinghq.org/build-instructions.html) describe the
cmake build, which Cider no longer has.

### Prefixes

Cider has support for DPREFIXes, which are very similar to WINEPREFIXes. They are virtual “chroot” environments with an macOS-like filesystem structure, where you can install software safely. The default DPREFIX location is `~/.cider`, but this can be changed by exporting an identically named environment variable. A prefix is automatically created and initialized on first use.

Please note that we use `overlayfs` for creating prefixes, and so we cannot support putting prefix on a filesystem like NFS or eCryptfs. In particular, the default prefix location won't work if you have an encrypted home directory.

### Hello world

Let's start with a Hello world:

````
$ cider shell echo Hello world
Hello world
````

Congratulations, you have printed Hello world through Cider's OS X system call emulation and runtime libraries.

### Installing software

You can install `.pkg` packages with the installer tool available inside shell. It is a somewhat limited cousin of OS X's installer:

````
$ cider shell
Cider [~]$ installer -pkg mc-4.8.7-0.pkg -target /
````

The Midnight Commander package from the above example is [available for download](https://darling-misc.s3.eu-central-1.amazonaws.com/mc-4.8.7-0.pkg).

You can uninstall and list packages with the `uninstaller` command.

### Working with DMG images

DMG images can be attached and detached from inside `cider shell` with `hdiutil`. This is how you can install Xcode along with its toolchain and SDKs (note that Xcode itself doesn't run yet):

````
Cider [~]$ hdiutil attach Xcode_7.2.dmg
/Volumes/Xcode_7.2
Cider [~]$ cp -r /Volumes/Xcode_7.2/Xcode.app /Applications
Cider [~]$ export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.11.sdk
Cider [~]$ echo 'void main() { puts("Hello world"); }' > helloworld.c
Cider [~]$ /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang helloworld.c -o helloworld
Cider [~]$ ./helloworld
Hello world
````

Congratulations, you have just compiled and run your own Hello world application with Apple's toolchain.

### Working with XIP archives

Xcode is now distributed in `.xip` files. These can be installed using `unxip`:

```
cd /Applications
unxip Xcode_11.3.xip
```

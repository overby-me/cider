# CMake, driven through a real configure

CMake is the Qt application on the roster, and until this it had only ever been driven as far as
typing a path into the source field. This drives it through Configure.

## The whole interface works

At 1256x684, with launchd on:

- the source and build fields take text, and the path completer popup opens under the source field
  as it is typed;
- **Add Entry** opens the Add Cache Entry dialog: a focused Name field, a Type popup reading BOOL,
  a Value checkbox, a Description field, Cancel and OK;
- **Configure** opens the generator sheet: `Specify the generator for this project` over a popup
  reading Unix Makefiles, four radio buttons with `Use default native compilers` selected, and Go
  Back and Done;
- Done runs it. `Current Generator` changes from None to Unix Makefiles, the Configure button
  becomes Stop, the progress bar fills, the output pane fills with the running log, and when it
  fails an error dialog appears reading
  `Error in configuration process, project files may be invalid` with a red icon and OK.

So the Qt dialogs, the popup, the buttons, the progress bar, the streaming output pane and the
modal error all work, and CMake really does spawn a subprocess and read it back.

## Why the configure fails, which is not a port defect

The output pane says:

    Detecting C compiler ABI info   failed
    Check for working C compiler:/usr/bin/clang

Running that compiler directly in the same prefix names it:

    xcrun: invoked with /Library/Developer/DarlingCLT/usr/bin/xcrun clang --version
    xcrun: error: unable to find utility "clang", not a developer tool or in PATH

`/usr/bin/clang` in the prefix is an `xcrun` shim, and there are no command line tools behind it.
CMake is doing exactly the right thing and the toolchain is simply not staged. Making this configure
succeed is a staging job, not a drawing or event one.

## Two things I got wrong on the way, and how

**"The Configure button does not fire."** In the first attempt the click landed, the button took a
focus ring, and nothing happened. The reason is that typing the source path opens the completer
popup, and the popup was still up: the click dismissed it instead of pressing the button. Sending
Escape after typing, and only then clicking, opens the generator sheet every time. The button was
never at fault.

**"/usr/bin/clang does not exist."** It does. `ls` on the host under the prefix shows only
`usr/local`, because `/usr` inside the container is overlaid from the built prefix tree and exists
only while the container runs. A host-side path check of a cider prefix answers about the wrong
filesystem.

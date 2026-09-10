#!/usr/bin/env python3
"""Which methods an application defines on a class cocotron also defines them on.

WHY THIS EXISTS. An ObjC selector is a process wide namespace, and a subclass method WINS. Qt
subclasses NSWindow as QNSWindow and defines -platformWindow, returning a C++ QCocoaWindow pointer;
cocotron uses that same name for its own backend object, so every internal [window platformWindow]
inside AppKit got a C++ vtable and objc_msgSend read it as an isa. See task #227.

THIS NEEDS HUMAN JUDGEMENT AND DOES NOT PRETEND OTHERWISE. Most hits are LEGITIMATE: drawRect:,
isFlipped and hitTest: are override points, and an application overriding them is the design. The
dangerous ones are names cocotron INVENTED, where cocotron calls the method expecting its own
answer. There is no way to tell the two apart without Apple's API list, so this prints the
intersection and a person decides.

Measured 2026-09-10 over the six roster applications plus libqcocoa: 79 distinct names collide, and
exactly ONE was a cocotron invention, platformWindow, now renamed cider_platformWindow.
enableBlur: and disableBlur also collide and are SAFE: cocotron defines them as no-ops precisely
because iTerm2 calls them, and never sends them itself.

THE RULE THIS LEAVES: an internal accessor cocotron adds to a public AppKit class must be prefixed.

Usage:
    scripts/objc-selector-collisions.py <cocotron-sels.json> <app-binary>...

where the json maps a cocotron class name to the selectors it defines. Fat binaries are handled;
the x86_64 slice is extracted to a temporary file.
"""

COCOTRON = json.load(open(sys.argv[1]))

def slices(path):
    """Every x86_64 Mach-O slice of a file, written out; a thin file is itself."""
    with open(path,'rb') as f:
        head=f.read(8)
        if len(head)<8: return []
        if struct.unpack('>I',head[:4])[0]==0xcafebabe:
            f.seek(0); d=f.read(4096)
            n=struct.unpack('>I',d[4:8])[0]; out=[]
            for i in range(n):
                cpu,sub,off,size,al=struct.unpack('>iiIII',d[8+i*20:28+i*20])
                if cpu==0x01000007:
                    f.seek(off); tmp=f"/tmp/claude-1000/slice_{os.getpid()}_{i}.bin"
                    open(tmp,'wb').write(f.read(size)); out.append(tmp)
            return out
        return [path]

def classes_with_methods(path):
    """class name -> (superclass, {selectors it DEFINES})."""
    try:
        o=subprocess.run(['llvm-objdump','--macho','--objc-meta-data',path],
                         capture_output=True,text=True,timeout=300).stdout
    except Exception:
        return {}
    res={}; cur=None; sup=None; pending=None
    for line in o.splitlines():
        m=re.match(r'\s+superclass 0x[0-9a-f]+ _OBJC_CLASS_\$_(\S+)', line)
        if m: pending=m.group(1); continue
        m=re.match(r'\s+name 0x[0-9a-f]+ (\S+)$', line)
        if m and pending is not None and cur is None:
            cur=m.group(1); sup=pending; pending=None; res.setdefault(cur,(sup,set())); continue
        m=re.match(r'\s+name 0x[0-9a-f]+ (\S+)$', line)
        if m and cur is not None:
            res[cur][1].add(m.group(1)); continue
        if re.match(r'\s+superclass ', line): cur=None
    return res

for target in sys.argv[2:]:
    for sl in slices(target):
        cm=classes_with_methods(sl)
        for cls,(sup,sels) in sorted(cm.items()):
            if sup in COCOTRON:
                hits=sorted(sels & set(COCOTRON[sup]))
                if hits:
                    print(f"{os.path.basename(target)}: {cls} : {sup} defines {len(hits)} name(s) cocotron also defines")
                    for h in hits: print(f"    {h}")

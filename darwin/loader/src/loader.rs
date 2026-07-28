// mldr M2: map a Mach-O image's segments into the address space at vmaddr+slide.
// Mirrors src/startup/mldr/loader.c:50-343 -- the PIE slide computation and the
// LC_SEGMENT_64 mapping state machine (protection quirk, two-phase BSS map, __PAGEZERO
// tolerance). All raw mmap; deliberately unsafe and address-exact.
use goblin::mach::MachO;
use std::os::raw::{c_int, c_void};

const VM_PROT_READ: u32 = 1;
const VM_PROT_WRITE: u32 = 2;
const VM_PROT_EXECUTE: u32 = 4;
const MH_PIE: u32 = 0x0020_0000;
const MH_DYLINKER: u32 = 7;
const PAGE_SIZE: u64 = 4096;

pub struct MapResult {
    pub slide: u64,
    pub mh: u64,          // in-memory mach_header of the image (the fileoff==0 segment)
    pub vm_addr_max: u64, // top of the mapped image
    pub entry: u64,       // goblin's entry (LC_MAIN/LC_UNIXTHREAD) + slide
}

/// native_prot (mldr.c:462-474): VM_PROT_* -> PROT_*.
fn native_prot(vmprot: u32) -> c_int {
    let mut p = 0;
    if vmprot & VM_PROT_READ != 0 {
        p |= libc::PROT_READ;
    }
    if vmprot & VM_PROT_WRITE != 0 {
        p |= libc::PROT_WRITE;
    }
    if vmprot & VM_PROT_EXECUTE != 0 {
        p |= libc::PROT_EXEC;
    }
    p
}

fn page_align_down(x: u64) -> u64 {
    x & !(PAGE_SIZE - 1)
}

/// Map every LC_SEGMENT_64 of `macho` (already parsed from `fd`) at vmaddr+slide.
/// `fat_offset` is the slice offset within a fat file (0 for a thin Mach-O).
pub unsafe fn map_image(fd: c_int, macho: &MachO, fat_offset: u64) -> MapResult {
    let is_pie = macho.header.flags & MH_PIE != 0 || macho.header.filetype == MH_DYLINKER;
    let slide = if is_pie { compute_slide(macho) } else { 0 };
    let mut r = MapResult {
        slide,
        mh: 0,
        vm_addr_max: 0,
        entry: macho.entry.wrapping_add(slide),
    };

    for seg in &macho.segments {
        let name = seg.name().unwrap_or("");
        let maxprot = native_prot(seg.maxprot);
        let initprot = native_prot(seg.initprot);
        // The "wrong but load-bearing" protection quirk (loader.c:152-157).
        let useprot = if initprot & libc::PROT_EXEC != 0 {
            maxprot
        } else {
            initprot
        };
        let addr = seg.vmaddr.wrapping_add(slide);
        // __PAGEZERO: an inaccessible region -- tolerate map failures (loader.c:173-181).
        let pagezero = seg.vmaddr == 0 && useprot == 0;

        // Phase 1: anonymous map for the zero-fill (BSS) tail when filesize < vmsize.
        if seg.filesize < seg.vmsize {
            let (a_addr, a_len) = if slide != 0 {
                (addr, seg.vmsize as usize) // map the whole span, file overlays below
            } else {
                let ts = page_align_down(seg.vmaddr + seg.filesize);
                (ts, (seg.vmaddr + seg.vmsize - ts) as usize)
            };
            if a_len > 0 {
                let p = libc::mmap(
                    a_addr as *mut c_void,
                    a_len,
                    useprot,
                    libc::MAP_ANONYMOUS | libc::MAP_PRIVATE | libc::MAP_FIXED_NOREPLACE,
                    -1,
                    0,
                );
                if p == libc::MAP_FAILED && !pagezero {
                    fail(&format!("anon map of {name} at {addr:#x} ({a_len} bytes)"));
                }
            }
        }

        // Phase 2: map the file bytes (MAP_FIXED to overlay the anon when two-phase).
        if seg.filesize > 0 {
            let flags = if seg.filesize < seg.vmsize {
                libc::MAP_PRIVATE | libc::MAP_FIXED
            } else {
                libc::MAP_PRIVATE | libc::MAP_FIXED_NOREPLACE
            };
            let p = libc::mmap(
                addr as *mut c_void,
                seg.filesize as usize,
                useprot,
                flags,
                fd,
                (seg.fileoff + fat_offset) as libc::off_t,
            );
            if p == libc::MAP_FAILED && !pagezero {
                fail(&format!(
                    "file map of {name} at {addr:#x} (fileoff {})",
                    seg.fileoff
                ));
            }
        }

        // The fileoff==0 non-PAGEZERO segment holds the in-memory mach_header.
        if seg.fileoff == 0 && !pagezero && r.mh == 0 {
            r.mh = addr;
        }
        r.vm_addr_max = r.vm_addr_max.max(addr + seg.vmsize);
    }
    r
}

/// PIE slide (loader.c:96-136): reserve the total VM span as a free hole, release it, and
/// take the returned address as the slide base. Non-PIE images get slide 0.
unsafe fn compute_slide(macho: &MachO) -> u64 {
    let mut base = u64::MAX;
    let mut end = 0u64;
    for seg in &macho.segments {
        if seg.name().unwrap_or("") == "__PAGEZERO" {
            continue;
        }
        base = base.min(seg.vmaddr);
        end = end.max(seg.vmaddr + seg.vmsize);
    }
    if base == u64::MAX || end <= base {
        return 0;
    }
    let span = (end - base) as usize;
    let p = libc::mmap(
        base as *mut c_void,
        span,
        libc::PROT_NONE,
        libc::MAP_ANONYMOUS | libc::MAP_PRIVATE,
        -1,
        0,
    );
    if p == libc::MAP_FAILED {
        return 0;
    }
    libc::munmap(p, span);
    (p as u64).wrapping_sub(base)
}

/// Extract the LC_LOAD_DYLINKER path (mldr.c:260-314) by walking the raw load commands
/// (x86_64 Mach-O is little-endian). Returns the Mach-O dylinker path (needs vchroot).
pub fn find_dylinker(data: &[u8]) -> Option<String> {
    const LC_LOAD_DYLINKER: u32 = 0xe;
    if data.len() < 32 {
        return None;
    }
    let ncmds = u32::from_le_bytes(data[16..20].try_into().ok()?) as usize;
    let mut off = 32usize; // sizeof(mach_header_64)
    for _ in 0..ncmds {
        if off + 8 > data.len() {
            break;
        }
        let cmd = u32::from_le_bytes(data[off..off + 4].try_into().ok()?);
        let cmdsize = u32::from_le_bytes(data[off + 4..off + 8].try_into().ok()?) as usize;
        if cmdsize == 0 || off + cmdsize > data.len() {
            break;
        }
        if cmd == LC_LOAD_DYLINKER {
            let name_off = u32::from_le_bytes(data[off + 8..off + 12].try_into().ok()?) as usize;
            let s = off + name_off;
            if s < off + cmdsize {
                let region = &data[s..off + cmdsize];
                let end = region.iter().position(|&b| b == 0).unwrap_or(region.len());
                return Some(String::from_utf8_lossy(&region[..end]).into_owned());
            }
        }
        off += cmdsize;
    }
    None
}

fn fail(msg: &str) -> ! {
    eprintln!("[mldr] map error: {msg}");
    std::process::exit(1);
}

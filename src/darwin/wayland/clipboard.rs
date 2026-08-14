// THE CLIPBOARD BETWEEN APPLICATIONS, which is the half WaylandPasteboard.m says it does not do.
//
// Copy and paste WITHIN the application never needed this: the pasteboard keeps the bytes and hands
// them back. Copying OUT of it, into a browser or an editor, is a different mechanism entirely.
// There is no clipboard daemon on Wayland and no data at rest anywhere. A client that copies takes
// OWNERSHIP of the selection and advertises the MIME types it can produce; when something else
// pastes, the compositor hands that client a pipe and it writes the bytes then. Ownership ends the
// moment another client takes it, and the compositor says so with wl_data_source.cancelled.
//
// THE SERIAL IS THE PERMISSION. wl_data_device.set_selection is refused unless its serial belongs to
// a recent input event on this seat, which is how a compositor stops a background process from
// taking the clipboard from under the user. So the last serial seen by the keyboard or the pointer
// is recorded in input.rs and used here.
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::sync::Mutex;

use crate::wl;

/// The text this process has published, kept because the request to produce it arrives LATER: a
/// compositor sends wl_data_source.send when something else pastes, which may be minutes after the
/// copy or never.
struct State {
    manager: *mut wl::WlDataDeviceManager,
    device: *mut wl::WlDataDevice,
    source: *mut wl::WlDataSource,
    /// What we published, as UTF-8.
    text: Vec<u8>,
    /// The offer another client owns, if any, and whether it advertises text we can read.
    offer: *mut wl::WlDataOffer,
    offer_mime: Option<CString>,
}

unsafe impl Send for State {}

static STATE: Mutex<State> = Mutex::new(State {
    manager: std::ptr::null_mut(),
    device: std::ptr::null_mut(),
    source: std::ptr::null_mut(),
    text: Vec::new(),
    offer: std::ptr::null_mut(),
    offer_mime: None,
});

/// THE TYPES, in the order a text-shaped consumer wants them. utf8_string is what modern clients
/// look for first, text/plain;charset=utf-8 is what everything understands, and the other two are
/// there because older clients ask by those names and get nothing otherwise.
const MIMES: [&str; 4] = [
    "text/plain;charset=utf-8",
    "UTF8_STRING",
    "text/plain",
    "TEXT",
];

fn mime_is_text(mime: &str) -> bool {
    mime == "text/plain;charset=utf-8"
        || mime == "UTF8_STRING"
        || mime == "text/plain"
        || mime == "TEXT"
        || mime == "STRING"
}

pub fn note_manager(manager: *mut wl::WlDataDeviceManager) {
    if let Ok(mut st) = STATE.lock() {
        st.manager = manager;
    }
}

/// Called once the seat exists, because a data device is obtained FOR a seat.
pub fn attach_seat(seat: *mut wl::WlSeat) {
    let manager = match STATE.lock() {
        Ok(st) => st.manager,
        Err(_) => return,
    };
    if manager.is_null() || seat.is_null() {
        println!("cider-wayland-clipboard device=skipped reason=no-manager-or-seat");
        return;
    }
    let device = unsafe { wl::cider_wl_data_device_manager_get_data_device(manager, seat) };
    if device.is_null() {
        println!("cider-wayland-clipboard device=failed");
        return;
    }
    unsafe {
        wl::cider_wl_data_device_add_listener(device, &DEVICE_LISTENER, std::ptr::null_mut());
    }
    if let Ok(mut st) = STATE.lock() {
        st.device = device;
    }
    println!("cider-wayland-clipboard device=ok");
}

// ---------------------------------------------------------------------------------------------
// OWNING THE SELECTION, which is what happens when the application copies.

extern "C" fn on_send(
    _data: *mut c_void,
    _source: *mut wl::WlDataSource,
    _mime: *const c_char,
    fd: i32,
) {
    /*
     * RENDER NOW, because the application promised rather than produced.
     *
     * LibreOffice declares the types it could write and waits to be asked, which is the same
     * bargain wl_data_source makes, so this is where the two meet: the compositor asks, the
     * pasteboard asks its owner, and the bytes exist for the first time. A copy nobody pastes never
     * renders anything.
     *
     * This runs on the thread pumping the connection, which is the main thread, which is where
     * AppKit expects to be called.
     */
    let mut len: usize = 0;
    let rendered = unsafe { cider_wayland_pasteboard_general_utf8(&mut len) };
    let text: Vec<u8> = if rendered.is_null() || len == 0 {
        match STATE.lock() {
            Ok(st) => st.text.clone(),
            Err(_) => Vec::new(),
        }
    } else {
        let slice = unsafe { std::slice::from_raw_parts(rendered, len) }.to_vec();
        unsafe { libc_free(rendered as *mut c_void) };
        slice
    };
    // WRITE AND CLOSE, AND CLOSE EVEN ON FAILURE. The reader is blocked on this pipe: a client that
    // takes the fd and never closes it leaves the other application hanging on a paste, which is a
    // far worse failure than an empty clipboard.
    unsafe {
        let mut written = 0usize;
        while written < text.len() {
            let n = libc_write(fd, text.as_ptr().add(written) as *const c_void, text.len() - written);
            if n <= 0 {
                break;
            }
            written += n as usize;
        }
        libc_close(fd);
    }
}

extern "C" fn on_cancelled(_data: *mut c_void, source: *mut wl::WlDataSource) {
    // ANOTHER CLIENT TOOK THE CLIPBOARD. The source is dead from here; destroying it is required,
    // and keeping the pointer would be a use after free the next time something copies.
    let was_ours = match STATE.lock() {
        Ok(mut st) => {
            let ours = st.source == source;
            if ours {
                st.source = std::ptr::null_mut();
                st.text.clear();
            }
            ours
        }
        Err(_) => false,
    };
    unsafe { wl::cider_wl_data_source_destroy(source) };
    if was_ours {
        /*
         * AND THE PASTEBOARD HAS TO BE TOLD, or the next paste inserts what THIS application copied
         * ten minutes ago instead of what the user just copied somewhere else. Measured exactly
         * that: wl-copy took the selection, the document pasted its own old text, and nothing
         * anywhere was wrong except that the pasteboard still believed it owned the clipboard.
         */
        unsafe { cider_wayland_pasteboard_dropped() };
        println!("cider-wayland-clipboard ownership=lost");
    }
}

extern "C" fn on_target(_d: *mut c_void, _s: *mut wl::WlDataSource, _mime: *const c_char) {}
extern "C" fn on_dnd_drop_performed(_d: *mut c_void, _s: *mut wl::WlDataSource) {}
extern "C" fn on_dnd_finished(_d: *mut c_void, _s: *mut wl::WlDataSource) {}
extern "C" fn on_source_action(_d: *mut c_void, _s: *mut wl::WlDataSource, _action: u32) {}

static SOURCE_LISTENER: wl::WlDataSourceListener = wl::WlDataSourceListener {
    target: on_target,
    send: on_send,
    cancelled: on_cancelled,
    dnd_drop_performed: on_dnd_drop_performed,
    dnd_finished: on_dnd_finished,
    action: on_source_action,
};

/// Publish text as the selection. Returns false if there is no device or no serial to use yet.
pub fn set_text(text: &[u8]) -> bool {
    let (manager, device) = match STATE.lock() {
        Ok(st) => (st.manager, st.device),
        Err(_) => return false,
    };
    if manager.is_null() || device.is_null() {
        return false;
    }
    let serial = crate::input::last_serial();
    if serial == 0 {
        // No input has been seen, so the compositor would refuse this. Not an error: the
        // application can copy before anyone has typed, and the next copy will carry a serial.
        println!("cider-wayland-clipboard copy=deferred reason=no-serial");
        return false;
    }
    let source = unsafe { wl::cider_wl_data_device_manager_create_data_source(manager) };
    if source.is_null() {
        return false;
    }
    unsafe {
        wl::cider_wl_data_source_add_listener(source, &SOURCE_LISTENER, std::ptr::null_mut());
        for mime in MIMES {
            if let Ok(c) = CString::new(mime) {
                wl::cider_wl_data_source_offer(source, c.as_ptr());
            }
        }
        wl::cider_wl_data_device_set_selection(device, source, serial);
    }
    if let Ok(mut st) = STATE.lock() {
        // The OLD source is not destroyed here. The compositor will send cancelled for it, and
        // destroying it first would race that event; on_cancelled is the one place it is freed.
        st.source = source;
        st.text = text.to_vec();
    }
    crate::session::flush();
    println!("cider-wayland-clipboard copy=ok bytes={} serial={serial}", text.len());
    true
}

// ---------------------------------------------------------------------------------------------
// READING SOMEONE ELSE'S SELECTION, which is what happens when the application pastes.

extern "C" fn on_offer_mime(_data: *mut c_void, offer: *mut wl::WlDataOffer, mime: *const c_char) {
    if mime.is_null() {
        return;
    }
    let Ok(text) = (unsafe { CStr::from_ptr(mime) }).to_str() else {
        return;
    };
    if !mime_is_text(text) {
        return;
    }
    if let Ok(mut st) = STATE.lock() {
        if st.offer == offer {
            // FIRST MATCH WINS, and MIMES is in preference order, so a later text/plain does not
            // replace an earlier utf-8 one.
            let better = match &st.offer_mime {
                None => true,
                Some(current) => {
                    let current = current.to_str().unwrap_or("");
                    rank(text) < rank(current)
                }
            };
            if better {
                st.offer_mime = CString::new(text).ok();
            }
        }
    }
}

fn rank(mime: &str) -> usize {
    MIMES.iter().position(|m| *m == mime).unwrap_or(usize::MAX)
}

extern "C" fn on_offer_source_actions(_d: *mut c_void, _o: *mut wl::WlDataOffer, _a: u32) {}
extern "C" fn on_offer_action(_d: *mut c_void, _o: *mut wl::WlDataOffer, _a: u32) {}

static OFFER_LISTENER: wl::WlDataOfferListener = wl::WlDataOfferListener {
    offer: on_offer_mime,
    source_actions: on_offer_source_actions,
    action: on_offer_action,
};

/// A NEW OFFER, which is announced BEFORE anyone says what it is for. The types arrive next, as
/// wl_data_offer.offer events, and only then does selection or enter say which mechanism it
/// belongs to.
extern "C" fn on_data_offer(
    _data: *mut c_void,
    _device: *mut wl::WlDataDevice,
    offer: *mut wl::WlDataOffer,
) {
    if offer.is_null() {
        return;
    }
    unsafe { wl::cider_wl_data_offer_add_listener(offer, &OFFER_LISTENER, std::ptr::null_mut()) };
    if let Ok(mut st) = STATE.lock() {
        // The previous offer is destroyed as it is replaced. Keeping them would leak one proxy per
        // copy anywhere in the session.
        if !st.offer.is_null() && st.offer != offer {
            unsafe { wl::cider_wl_data_offer_destroy(st.offer) };
        }
        st.offer = offer;
        st.offer_mime = None;
    }
}

extern "C" fn on_selection(
    _data: *mut c_void,
    _device: *mut wl::WlDataDevice,
    offer: *mut wl::WlDataOffer,
) {
    if offer.is_null() {
        // The clipboard was cleared, or it is ours and the compositor is telling us so.
        if let Ok(mut st) = STATE.lock() {
            if !st.offer.is_null() {
                unsafe { wl::cider_wl_data_offer_destroy(st.offer) };
            }
            st.offer = std::ptr::null_mut();
            st.offer_mime = None;
        }
    }
}

extern "C" fn on_enter(
    _d: *mut c_void, _dev: *mut wl::WlDataDevice, _serial: u32, _s: *mut wl::WlSurface,
    _x: i32, _y: i32, _o: *mut wl::WlDataOffer,
) {
}
extern "C" fn on_leave(_d: *mut c_void, _dev: *mut wl::WlDataDevice) {}
extern "C" fn on_motion(_d: *mut c_void, _dev: *mut wl::WlDataDevice, _t: u32, _x: i32, _y: i32) {}
extern "C" fn on_drop(_d: *mut c_void, _dev: *mut wl::WlDataDevice) {}

static DEVICE_LISTENER: wl::WlDataDeviceListener = wl::WlDataDeviceListener {
    data_offer: on_data_offer,
    enter: on_enter,
    leave: on_leave,
    motion: on_motion,
    drop: on_drop,
    selection: on_selection,
};

/// Read the current selection, or None when this process owns it or nobody offers text.
///
/// THE READ IS THE AWKWARD PART. receive() hands the other client a pipe and it writes whenever it
/// likes, so this has to flush the request, then read with the connection still being serviced.
/// The read end is made non-blocking and polled with a deadline: a client that never writes must
/// not freeze the application, and one that is merely slow must not be cut off.
pub fn text() -> Option<Vec<u8>> {
    let (offer, mime) = match STATE.lock() {
        Ok(st) => (st.offer, st.offer_mime.clone()),
        Err(_) => return None,
    };
    let offer = if offer.is_null() { return None } else { offer };
    let mime = mime?;

    let mut fds = [0i32; 2];
    if unsafe { libc_pipe(fds.as_mut_ptr()) } != 0 {
        return None;
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);
    unsafe {
        wl::cider_wl_data_offer_receive(offer, mime.as_ptr(), write_fd);
        libc_close(write_fd);
    }
    crate::session::flush();

    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
    loop {
        let n = unsafe { libc_read(read_fd, buf.as_mut_ptr() as *mut c_void, buf.len()) };
        if n > 0 {
            out.extend_from_slice(&buf[..n as usize]);
            continue;
        }
        if n == 0 {
            break;
        }
        // EAGAIN on a pipe nobody has written to yet. Service the connection and try again.
        if std::time::Instant::now() >= deadline {
            break;
        }
        crate::session::pump();
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    unsafe { libc_close(read_fd) };
    println!("cider-wayland-clipboard paste=ok bytes={}", out.len());
    if out.is_empty() { None } else { Some(out) }
}

unsafe extern "C" {
    /// Implemented in WaylandPasteboard.m: the general pasteboard as UTF-8, asking its owner to
    /// render a promised type, in a malloc block this side frees.
    fn cider_wayland_pasteboard_general_utf8(len: *mut usize) -> *mut u8;
    /// Implemented in WaylandPasteboard.m: empty the general pasteboard because the clipboard now
    /// belongs to another application.
    fn cider_wayland_pasteboard_dropped();
    #[link_name = "free"]
    fn libc_free(p: *mut c_void);
    #[link_name = "write"]
    fn libc_write(fd: i32, buf: *const c_void, count: usize) -> isize;
    #[link_name = "read"]
    fn libc_read(fd: i32, buf: *mut c_void, count: usize) -> isize;
    #[link_name = "close"]
    fn libc_close(fd: i32) -> i32;
    #[link_name = "pipe"]
    fn libc_pipe(fds: *mut i32) -> i32;
}

// ---------------------------------------------------------------------------------------------
// The C entry points WaylandPasteboard.m calls.

/// TAKE THE SELECTION WITH NOTHING RENDERED, which is what an application that promises its types
/// needs. The bytes are fetched from the pasteboard when the compositor asks.
#[unsafe(no_mangle)]
pub extern "C" fn cider_wayland_clipboard_declare() -> i32 {
    if set_text(&[]) { 1 } else { 0 }
}

/// Publish UTF-8 bytes as the system selection.
#[unsafe(no_mangle)]
pub extern "C" fn cider_wayland_clipboard_set_text(bytes: *const u8, len: usize) -> i32 {
    if bytes.is_null() || len == 0 {
        return 0;
    }
    let slice = unsafe { std::slice::from_raw_parts(bytes, len) };
    if set_text(slice) { 1 } else { 0 }
}

/// Copy the current selection into a caller-owned buffer. Returns the number of bytes written, or
/// the negative size needed when the buffer is too small, or 0 when there is nothing to paste.
#[unsafe(no_mangle)]
pub extern "C" fn cider_wayland_clipboard_get_text(out: *mut u8, cap: usize) -> isize {
    let Some(bytes) = text() else { return 0 };
    if out.is_null() || cap < bytes.len() {
        return -(bytes.len() as isize);
    }
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
    bytes.len() as isize
}

// Load-time entry point for the AppKit backend bundle. Separate from the CoreGraphics one because
// they are different dylibs and each must call only its own registration.
extern void cider_wayland_appkit_register(void);

__attribute__((constructor)) static void cider_wayland_appkit_init(void) {
	cider_wayland_appkit_register();
}

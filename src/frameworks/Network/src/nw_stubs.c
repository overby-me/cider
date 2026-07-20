// nw_stubs.c - loudly-logging stubs for the modern low-level Network.framework
// C API (nw_*). Darling's Network.framework implements the older Objective-C
// NW* classes but not these nw_ functions, which macOS 14 binaries link (e.g.
// aws-c-io, pulled in by the nixpkgs `nix` for S3 binary-cache support). Nix
// never touches S3 for a local store/build, so these are never actually called;
// they exist only so such binaries load under Darling. If one *is* called it
// logs once and returns NULL/0 (which the caller treats as failure).
//
// Generated from the undefined nw_ symbols of libaws-c-io; see
// plan/syscall-triage.md. NOT a real Network implementation.
#include <stdio.h>
#include <stddef.h>

#define NW_STUB(name) \
	__attribute__((visibility("default"))) \
	void* name(void) { \
		static int warned = 0; \
		if (!warned) { warned = 1; \
			fprintf(stderr, "[Darling] Network.framework stub called: %s (nw_ API not implemented)\n", #name); \
		} \
		return NULL; \
	}

NW_STUB(_nw_content_context_default_message)
NW_STUB(_nw_parameters_configure_protocol_disable)
NW_STUB(nw_connection_cancel)
NW_STUB(nw_connection_copy_current_path)
NW_STUB(nw_connection_copy_endpoint)
NW_STUB(nw_connection_copy_protocol_metadata)
NW_STUB(nw_connection_create)
NW_STUB(nw_connection_receive)
NW_STUB(nw_connection_send)
NW_STUB(nw_connection_set_queue)
NW_STUB(nw_connection_set_state_changed_handler)
NW_STUB(nw_connection_start)
NW_STUB(nw_content_context_get_is_final)
NW_STUB(nw_endpoint_create_address)
NW_STUB(nw_endpoint_get_hostname)
NW_STUB(nw_endpoint_get_port)
NW_STUB(nw_error_get_error_code)
NW_STUB(nw_listener_cancel)
NW_STUB(nw_listener_create)
NW_STUB(nw_listener_get_port)
NW_STUB(nw_listener_set_new_connection_handler)
NW_STUB(nw_listener_set_queue)
NW_STUB(nw_listener_set_state_changed_handler)
NW_STUB(nw_listener_start)
NW_STUB(nw_parameters_create_secure_tcp)
NW_STUB(nw_parameters_create_secure_udp)
NW_STUB(nw_parameters_set_local_endpoint)
NW_STUB(nw_parameters_set_reuse_local_address)
NW_STUB(nw_path_copy_effective_local_endpoint)
NW_STUB(nw_protocol_copy_tls_definition)
NW_STUB(nw_release)
NW_STUB(nw_retain)
NW_STUB(nw_tcp_options_set_connection_timeout)
NW_STUB(nw_tcp_options_set_enable_keepalive)
NW_STUB(nw_tcp_options_set_keepalive_count)
NW_STUB(nw_tcp_options_set_keepalive_idle_time)
NW_STUB(nw_tcp_options_set_keepalive_interval)
NW_STUB(nw_tcp_options_set_maximum_segment_size)
NW_STUB(nw_tls_copy_sec_protocol_options)

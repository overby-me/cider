/*
 * Upstream compatibility: Darling's own sources include <darlingserver/rpc.h>.
 *
 * The daemon is ciderd here and its headers stage as <ciderd/...>, but 42 files
 * across the xnu and libkqueue pins name the upstream path, and those are pins:
 * they keep their own names, so we provide the path they ask for rather than
 * patching 45 upstream files across two repositories.
 */
#include <ciderd/rpc.h>

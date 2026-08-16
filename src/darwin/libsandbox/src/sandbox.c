/*
 This file is part of Darling.

 Copyright (C) 2019 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/


#include <sandbox/sandbox.h>
#include <stdlib.h>
#include <stdio.h>

static int verbose = 0;

__attribute__((constructor))
static void initme(void) {
    verbose = getenv("STUB_VERBOSE") != NULL;
}

/*
 * THE PROFILE BUILDERS ANSWER A HANDLE, AND THIS IS A DELIBERATE LIE WORTH READING.
 *
 * There is no Apple sandbox here and nothing below applies one. What these two used to do was
 * answer NULL, and NULL is not a neutral answer: an application that cannot BUILD a sandbox
 * concludes it is running unprotected and shuts its own features off. iTerm2 does exactly that.
 * Its inline image decoder is a bundled XPC service whose main is
 *
 *     params = sandbox_create_params();
 *     if (!params) goto fail;                       <- this is where every run ended
 *     profile = sandbox_compile_string(text, params, &error);
 *     if (sandbox_apply_container(profile, 0) != 0) goto fail;
 *     sandboxSuccessful = YES;
 *
 * and the FIRST instruction of its listener:shouldAcceptNewConnection: is a test of that flag,
 * returning NO when it is clear. So the service started, accepted nothing, and answered nothing,
 * which is precisely how imgcat behaved: the request went out and the reply never came, with no
 * error anywhere because refusing a connection is not an error.
 *
 * A static token rather than an allocation, so that the free functions can stay the no-ops they
 * are and nothing leaks. sandbox_apply_container already answers zero, which its callers read as
 * success.
 *
 * WHAT THIS COSTS, said plainly: a process that asks to be confined is told it was confined and is
 * not. On this system that changes nothing it could have relied on, because the guest already runs
 * with the privileges of the user running Cider and no sandbox was ever going to be applied. The
 * alternative is not a safer iTerm2, it is an iTerm2 that cannot display an image.
 */
static char cider_sandbox_params_token;
static char cider_sandbox_profile_token;

void* sandbox_apply(void)
{
    if (verbose) puts("STUB: sandbox_apply called");
    return NULL;
}

void* sandbox_apply_container(void)
{
    /* Zero is SUCCESS to every caller of this one, and returning NULL is how this file spells zero.
     * That is why the sandbox chain only ever failed at sandbox_create_params. */
    if (verbose) puts("STUB: sandbox_apply_container called, answering success");
    return NULL;
}

void* sandbox_compile_entitlements(void)
{
    if (verbose) puts("STUB: sandbox_compile_entitlements called");
    return NULL;
}

void* sandbox_compile_file(void)
{
    if (verbose) puts("STUB: sandbox_compile_file called");
    return NULL;
}

void* sandbox_compile_named(void)
{
    if (verbose) puts("STUB: sandbox_compile_named called");
    return NULL;
}

void* sandbox_compile_string(void)
{
    /* Nothing is compiled. The token exists so a caller that checks the profile before applying it
     * takes the same path as one that does not; iTerm2 happens not to check. */
    if (verbose) puts("STUB: sandbox_compile_string called, answering a token");
    return &cider_sandbox_profile_token;
}

void* sandbox_container_paths_iterate_items(void)
{
    if (verbose) puts("STUB: sandbox_container_paths_iterate_items called");
    return NULL;
}

void* sandbox_create_params(void)
{
    /* See the note at the top: NULL here is read as "this machine has no sandbox to build", and
     * callers disable themselves rather than run unconfined. */
    if (verbose) puts("STUB: sandbox_create_params called, answering a token");
    return &cider_sandbox_params_token;
}

void* sandbox_free_params(void)
{
    if (verbose) puts("STUB: sandbox_free_params called");
    return NULL;
}

void* sandbox_free_profile(void)
{
    if (verbose) puts("STUB: sandbox_free_profile called");
    return NULL;
}

void* sandbox_inspect_pid(void)
{
    if (verbose) puts("STUB: sandbox_inspect_pid called");
    return NULL;
}

void* sandbox_inspect_smemory(void)
{
    if (verbose) puts("STUB: sandbox_inspect_smemory called");
    return NULL;
}

void* sandbox_set_param(void)
{
    if (verbose) puts("STUB: sandbox_set_param called");
    return NULL;
}

void* sandbox_set_user_state_item(void)
{
    if (verbose) puts("STUB: sandbox_set_user_state_item called");
    return NULL;
}

void* sandbox_user_state_item_buffer_create(void)
{
    if (verbose) puts("STUB: sandbox_user_state_item_buffer_create called");
    return NULL;
}

void* sandbox_user_state_item_buffer_destroy(void)
{
    if (verbose) puts("STUB: sandbox_user_state_item_buffer_destroy called");
    return NULL;
}

void* sandbox_user_state_item_buffer_send(void)
{
    if (verbose) puts("STUB: sandbox_user_state_item_buffer_send called");
    return NULL;
}

void* sandbox_user_state_iterate_items(void)
{
    if (verbose) puts("STUB: sandbox_user_state_iterate_items called");
    return NULL;
}

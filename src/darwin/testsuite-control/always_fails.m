#include <darling-testsuite/assertion.h>

/*
 * THE NEGATIVE CONTROL FOR scripts/run-dts-case.sh, AND IT FAILS ON PURPOSE.
 *
 * The script used to point at the PubSub case, on the grounds that PubSub.framework did not exist
 * in this port. It does now, so that case passes, and the script spent an unknown period with no
 * control at all while its comment still claimed one. A control that depends on something being
 * ABSENT can be retired by anyone who adds it, without noticing. Task #232.
 *
 * This one cannot be made to pass by any change to the tree, which is the whole point.
 *
 * IT MUST NEVER BE NAMED dts_ ANYTHING. run-dts-batch.sh builds its case list with
 *   grep '^    name = "dts_' vendor/src/BUCK
 * so a dts_ prefixed target here would join the 69 of 69 gate as a permanent failure and retire it
 * for everyone. It lives outside vendor/src for the same reason.
 */
int main(void) {
    assert_is_true(1 == 2);
    return 0;
}

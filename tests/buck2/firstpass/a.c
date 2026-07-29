// Half of the firstpass fixture: `a` calls into `b` and `b` calls back into `a`,
// which is the shape of Darling's libSystem sublibraries (libsystem_c needs
// libsystem_kernel, which needs libsystem_c). Neither dylib can be linked after
// the other, so both are built twice: a firstpass that resolves nothing, then a
// final pass against the other's firstpass. See buck/rules/darwin.bzl.
int b_value(void);

int a_value(void) {
	return 1;
}

int a_calls_b(void) {
	return b_value() + 1;
}

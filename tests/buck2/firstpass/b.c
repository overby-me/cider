// The other half; see a.c.
int a_value(void);

int b_value(void) {
	return 2;
}

int b_calls_a(void) {
	return a_value() + 2;
}

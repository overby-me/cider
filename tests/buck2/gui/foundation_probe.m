// The control for appkit_probe.m: same package, same crt1, same link shape, but nothing
// above Foundation. If this runs and the AppKit one does not, the difference is AppKit's
// load and initialization -- which is the whole point of having it.
#import <Foundation/Foundation.h>
#import <stdio.h>

int main(int argc, const char **argv) {
	printf("FOUNDATION_PROBE start\n");
	fflush(stdout);
	@autoreleasepool {
		NSString *s = [NSString stringWithUTF8String:"hello"];
		printf("FOUNDATION_PROBE string=%s len=%lu\n", [s UTF8String],
			(unsigned long)[s length]);
		fflush(stdout);
		NSLog(@"FOUNDATION_PROBE nslog-visible");
		printf("FOUNDATION_PROBE after-nslog\n");
		fflush(stdout);
	}
	printf("FOUNDATION_PROBE_OK\n");
	fflush(stdout);
	return 0;
}

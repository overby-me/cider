// Does the CoreAudio cone decode anything?
//
// CoreAudio is the last cone of any size that had never run. It is unusual in the tree
// because most of it is a BRIDGE: AudioToolbox parses and converts through the
// AFAVFormat component, which calls libavformat, libavcodec, libswresample and libavutil,
// and those four are wrapgen ELF stubs that forward into the host's ffmpeg through
// elfcalls. So this exercises the wrapper machinery as much as the framework.
//
// Reading and decoding only: no output device, so it needs neither audio hardware nor a
// PulseAudio sink and can run unattended. afinfo already does roughly this, but it
// swallows the OSStatus and prints only "AudioFileOpen failed", which says nothing about
// which layer gave up. This prints the status, as a number and as the four-character code
// CoreAudio actually uses.

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static void show(const char *what, OSStatus err) {
	// An OSStatus in CoreAudio is usually a fourcc read big-endian, and sometimes a plain
	// negative number. Print both rather than guess which one this is.
	char cc[5] = {0};
	UInt32 be = CFSwapInt32HostToBig((UInt32) err);
	memcpy(cc, &be, 4);
	for (int i = 0; i < 4; i++)
		if (cc[i] < 32 || cc[i] > 126)
			cc[i] = '.';
	printf("AUDIO_PROBE %s err=%d fourcc=%s\n", what, (int) err, cc);
	fflush(stdout);
}

static int probe(const char *path) {
	printf("AUDIO_PROBE file=%s\n", path);
	fflush(stdout);

	CFURLRef url = CFURLCreateFromFileSystemRepresentation(
		NULL, (const UInt8 *) path, (CFIndex) strlen(path), false);
	if (!url) {
		printf("AUDIO_PROBE url=nil\n");
		return 1;
	}

	AudioFileID afid = NULL;
	OSStatus err = AudioFileOpenURL(url, kAudioFileReadPermission, 0, &afid);
	show("open", err);
	if (err || !afid) {
		CFRelease(url);
		return 1;
	}

	AudioStreamBasicDescription asbd;
	UInt32 size = sizeof asbd;
	err = AudioFileGetProperty(afid, kAudioFilePropertyDataFormat, &size, &asbd);
	show("dataformat", err);
	if (!err) {
		char fmt[5] = {0};
		UInt32 be = CFSwapInt32HostToBig(asbd.mFormatID);
		memcpy(fmt, &be, 4);
		printf("AUDIO_PROBE format=%s rate=%g channels=%u bits=%u\n",
			fmt, asbd.mSampleRate, (unsigned) asbd.mChannelsPerFrame,
			(unsigned) asbd.mBitsPerChannel);
		fflush(stdout);
	}

	UInt64 frames = 0;
	size = sizeof frames;
	err = AudioFileGetProperty(afid, kAudioFilePropertyAudioDataPacketCount, &size, &frames);
	show("packets", err);
	if (!err) {
		printf("AUDIO_PROBE packets=%llu\n", (unsigned long long) frames);
		fflush(stdout);
	}

	// Actually pull bytes through, which is the part that reaches the decoder rather than
	// just the container parser.
	char buf[4096];
	UInt32 nbytes = sizeof buf;
	UInt32 npackets = 16;
	err = AudioFileReadPacketData(afid, false, &nbytes, NULL, 0, &npackets, buf);
	show("read", err);
	if (!err) {
		printf("AUDIO_PROBE read bytes=%u packets=%u\n",
			(unsigned) nbytes, (unsigned) npackets);
		fflush(stdout);
	}

	AudioFileClose(afid);
	CFRelease(url);
	return err ? 1 : 0;
}

// The five ELF wrappers under /usr/lib/native are the PORT-SPECIFIC half of this cone:
// wrapgen generates a Mach-O stub whose every export forwards into the host's ffmpeg or
// pulseaudio through elfcalls. Darling's AudioFile layer above them is a stub (see main),
// so nothing else here would ever reach them -- but they are what buck2 built, and calling
// one proves the bridge carries a real answer back rather than merely resolving.
static int wrappers(void) {
	struct { const char *lib; const char *sym; } probes[] = {
		{"/usr/lib/native/libavutil.dylib", "avutil_version"},
		{"/usr/lib/native/libavcodec.dylib", "avcodec_version"},
		{"/usr/lib/native/libavformat.dylib", "avformat_version"},
		{"/usr/lib/native/libswresample.dylib", "swresample_version"},
	};
	int bad = 0;
	for (size_t i = 0; i < sizeof probes / sizeof probes[0]; i++) {
		void *h = dlopen(probes[i].lib, RTLD_LAZY);
		if (!h) {
			printf("AUDIO_PROBE wrapper %s dlopen=FAILED %s\n", probes[i].lib, dlerror());
			fflush(stdout);
			bad = 1;
			continue;
		}
		unsigned (*ver)(void) = (unsigned (*)(void)) dlsym(h, probes[i].sym);
		if (!ver) {
			printf("AUDIO_PROBE wrapper %s sym=%s MISSING\n", probes[i].lib, probes[i].sym);
			fflush(stdout);
			bad = 1;
			continue;
		}
		unsigned v = ver();
		printf("AUDIO_PROBE wrapper %s %s=%u.%u.%u\n", probes[i].lib, probes[i].sym,
			(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
		fflush(stdout);
		if (v == 0)
			bad = 1;
	}
	// pulseaudio's version is a string rather than a packed integer.
	void *h = dlopen("/usr/lib/native/libpulse.dylib", RTLD_LAZY);
	if (h) {
		const char *(*pv)(void) = (const char *(*)(void)) dlsym(h, "pa_get_library_version");
		printf("AUDIO_PROBE wrapper libpulse pa_get_library_version=%s\n",
			pv ? pv() : "(symbol missing)");
	} else {
		printf("AUDIO_PROBE wrapper libpulse dlopen=FAILED %s\n", dlerror());
		bad = 1;
	}
	fflush(stdout);
	return bad;
}

int main(int argc, const char **argv) {
	printf("AUDIO_PROBE start\n");
	fflush(stdout);

	// AudioFile first, and it is EXPECTED to report unimpErr: every entry point in
	// darwin/CoreAudio/AudioToolbox/AudioFile.cpp is literally `return unimpErr`, so Darling
	// has no decode path at this layer at all. Reported rather than skipped, because the
	// day someone implements it this is the line that changes.
	int stubbed = 0;
	for (int i = 1; i < argc; i++)
		stubbed |= probe(argv[i]);
	printf("AUDIO_PROBE audiofile_stubbed=%d\n", stubbed);
	fflush(stdout);

	int bad = wrappers();
	printf("AUDIO_PROBE_DONE wrappers_bad=%d\n", bad);
	fflush(stdout);
	return bad;
}

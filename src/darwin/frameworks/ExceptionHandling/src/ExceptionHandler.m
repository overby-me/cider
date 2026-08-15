#include <ExceptionHandling/ExceptionHandler.h>
#include <pthread.h>
#include <sys/types.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>

NSString *NSStackTraceKey = @"NSStackTraceKey";

static void LocalExceptionHandler(NSException* e);

@implementation NSExceptionHandler

@synthesize exceptionHandlingMask = _handlingMask;
@synthesize exceptionHangingMask = _hangingMask;
@synthesize delegate = _delegate;

static NSExceptionHandler* instance;

static void init_routine(void)
{
	instance = [NSExceptionHandler new];
	instance->_delegate = NULL;
	instance->_handlingMask = 0xffffffff;
	instance->_hangingMask = 0;

	NSSetUncaughtExceptionHandler(LocalExceptionHandler);
}

+ (NSExceptionHandler *)defaultExceptionHandler
{
	static pthread_once_t once = PTHREAD_ONCE_INIT;
	
	pthread_once(&once, &init_routine);

	return instance;
}

@end

void LocalExceptionHandler(NSException* e)
{
	NSExceptionHandler* handler = [NSExceptionHandler defaultExceptionHandler];
	unsigned int mask = handler.exceptionHandlingMask;
	unsigned int hangmask = handler.exceptionHangingMask;
	id delegate = handler.delegate;

	/*
	 * BOTH DELEGATE METHODS ARE OPTIONAL, and sending one that is not there from inside the
	 * uncaught exception handler is the worst place to raise: the handler runs under the
	 * terminate handler, so a second exception there aborts the process with
	 *
	 *     libc++abi: terminate_handler unexpectedly threw an exception
	 *
	 * and NOTHING about the first exception is ever printed. Swift Publisher 5 sets a delegate
	 * that implements neither, and the exception it actually hit was invisible until this was
	 * guarded.
	 *
	 * A delegate that does not answer leaves the decision with the mask, which is what the
	 * no-delegate path below already did.
	 */
	bool log = (mask & NSLogUncaughtExceptionMask) != 0;
	bool handle = (mask & NSHandleUncaughtExceptionMask) != 0;

	if ([delegate respondsToSelector: @selector(exceptionHandler:shouldLogException:mask:)])
	{
		log = [delegate exceptionHandler: handler
		             shouldLogException: e
		                           mask: mask];
	}

	if ([delegate respondsToSelector: @selector(exceptionHandler:shouldHandleException:mask:)])
	{
		handle = [delegate exceptionHandler: handler
		             shouldHandleException: e
		                              mask: mask];
	}

	if (log)
		NSLog(@"Uncaught exception: %@", e);
	if (hangmask & NSHangOnUncaughtExceptionMask)
		kill(getpid(), SIGTRAP);
	if (handle)
		abort();
}

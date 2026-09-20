#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * WHAT CALLERS USE THIS FOR. CMake asks `xcrun --find clang` and takes stdout as the compiler path.
 * The previous stub execed argv[1], so it tried to run a program called "--find", and it printed
 * its own chatter on stdout, so anything parsing the answer read that too. Task #237.
 *
 * STDOUT IS THE ANSWER. Every diagnostic here goes to stderr.
 */

#if DEBUG
# define XCRUN_DEBUG(...) fprintf(stderr, __VA_ARGS__)
#else
# define XCRUN_DEBUG(...) do { } while (0)
#endif

static char* join(const char* dir, size_t dirlen, const char* tool)
{
	char* path = malloc(dirlen + 1 + strlen(tool) + 1);

	if (path == NULL)
		return NULL;
	memcpy(path, dir, dirlen);
	if (dirlen > 0 && dir[dirlen - 1] != '/')
		path[dirlen++] = '/';
	strcpy(path + dirlen, tool);
	return path;
}

/* THE DEVELOPER DIRECTORY ONLY, NOT PATH: /usr/bin/clang here is a shim that asks xcrun where the
 * real clang is, so an xcrun that falls back to PATH answers with the shim and the two exec each
 * other forever. Measured as a CMake compiler check that ping-ponged until it was killed. */
static char* locate(const char* self, const char* tool)
{
	const char* slash = strrchr(self, '/');
	char* path;

	if (tool[0] == '/')
		return access(tool, X_OK) == 0 ? strdup(tool) : NULL;

	if (slash == NULL)
		return NULL;

	path = join(self, (size_t) (slash - self), tool);
	if (path != NULL && access(path, X_OK) == 0)
		return path;
	free(path);
	return NULL;
}

int main(int argc, char** argv)
{
	int find_only = 0;
	int i = 1;
	char* path;

	XCRUN_DEBUG("xcrun: invoked with");
	for (int a = 0; a < argc; a++)
		XCRUN_DEBUG(" %s", argv[a]);
	XCRUN_DEBUG("\n");

	for (; i < argc && argv[i][0] == '-' && argv[i][1] != '\0'; i++)
	{
		const char* opt = argv[i];

		if (strcmp(opt, "-f") == 0 || strcmp(opt, "--find") == 0)
			find_only = 1;
		else if (strcmp(opt, "-r") == 0 || strcmp(opt, "--run") == 0)
			find_only = 0;
		/* These take a value. This port has one SDK and one toolchain, so the value changes
		 * nothing, but skipping it matters: otherwise it is read as the tool name. */
		else if (strcmp(opt, "--sdk") == 0 || strcmp(opt, "--toolchain") == 0)
			i++;
	}

	if (i >= argc)
	{
		fprintf(stderr, "xcrun: error: no tool name given\n");
		return 1;
	}

	path = locate(argv[0], argv[i]);
	if (path == NULL)
	{
		fprintf(stderr, "xcrun: error: unable to find utility \"%s\", "
				"not a developer tool or in PATH\n", argv[i]);
		return 1;
	}

	if (find_only)
	{
		printf("%s\n", path);
		return 0;
	}

	XCRUN_DEBUG("xcrun: executing %s\n", path);
	argv[i] = path;
	execv(path, argv + i);

	fprintf(stderr, "xcrun: error: failed to execute %s\n", path);
	return 1;
}

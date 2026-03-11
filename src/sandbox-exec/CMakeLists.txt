project(sandbox-exec)

add_darling_executable(sandbox-exec sandbox-exec.c)

# sandbox-exec is a simple tool that runs inside the Darling prefix.
# It only needs libSystem for execvp, fprintf, strcmp, etc.
target_link_libraries(sandbox-exec system)

install(TARGETS sandbox-exec DESTINATION libexec/darling/usr/bin)

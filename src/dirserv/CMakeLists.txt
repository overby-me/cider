project(dirserv)

# Directory Services command-line stubs for Darling.
#
# These shell scripts translate macOS Directory Services commands
# (dseditgroup, sysadminctl, dscl) to direct /etc/passwd and /etc/group
# file operations within the Darling prefix.  They implement only the
# subset needed by the Nix installer and multi-user Nix daemon setup.
#
# See: plan/07-phase5-daemon.md (Task 5.1)

install(FILES dseditgroup sysadminctl dscl
	DESTINATION libexec/darling/usr/sbin
	PERMISSIONS
		OWNER_READ OWNER_WRITE OWNER_EXECUTE
		GROUP_READ GROUP_EXECUTE
		WORLD_READ WORLD_EXECUTE
)

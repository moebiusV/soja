sojactl(1)

# NAME

sojactl - Manage a running instance of the soja IRC bouncer

# SYNOPSIS

*sojactl* [options...] <command...>

# DESCRIPTION

sojactl sends a _BouncerServ_ command to a running soja instance. See the
_IRC SERVICE_ section in *soja*(1) for more information.

sojactl requires a _listen unix+admin://_ directive in the soja configuration
file. sojactl needs to be run with write permissions on the soja admin socket.

# OPTIONS

*-h, -help*
	Show help message and quit.

*-config* <path>
	Path to the config file. If unset, the default config file path is used,
	if any.

# AUTHORS

soja is a translation of soju, which is maintained by Simon Ser
<contact@emersion.fr> and other open-source contributors. For more information
about soju development, see <https://sr.ht/~emersion/soju>.

# SEE ALSO

*soja*(1), *sojadb*(1)

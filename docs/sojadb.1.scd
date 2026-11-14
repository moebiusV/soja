sojadb(1)

# NAME

sojadb - Manage the database of the soja IRC bouncer

# SYNOPSIS

*sojadb* [options...] <action> [action options...]

# DESCRIPTION

sojadb creates users and changes their passwords directly in the database that
*soja*(1) uses: the one named by the _db_ directive of the configuration file.
It is how the first (administrator) user is made, before soja has anyone to
log in.

The password is asked for on the terminal, without echo. If standard input is
not a terminal, one line is read from it as the password (and a warning is
printed); an empty password is refused.

# OPTIONS

*-h, -help*
	Show help message and quit.

*-config* <path>
	Path to the config file (default: /etc/soju/config).

# ACTIONS

*create-user* <username> [-admin]
	Create a new user, asking for the password. With *-admin* the user is an
	administrator, who can create and change other users through BouncerServ
	(see *soja*(1)).

*change-password* <username>
	Change the password of an existing user, asking for the new one.

# AUTHORS

soja is a translation of soju, which is maintained by Simon Ser
<contact@emersion.fr> and other open-source contributors. soju's database tool
is called sojudb.

# SEE ALSO

*soja*(1), *sojactl*(1)

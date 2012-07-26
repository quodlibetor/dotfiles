# .bashrc
# Source global definitions
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi

if [ -d "$HOME/.local/bin" ] ; then
	export PATH="$PATH:$HOME/.local/bin"
fi

if [ -z "$PYTHONPATH" ] ; then
	PYTHONPATH="$HOME/.local/lib/python2.6/site-packages/"
else
	PYTHONPATH="$HOME/.local/lib/python2.6/site-packages/:$PYTHONPATH"
fi

PYTHONSTARTUP="$HOME/.pythonrc"

# User specific aliases and functions
. ~/.bash-colors
PS1="\[$txtgrn\]\u\[$txtrst\]@\[$txtcyn\]\h\[$txtrst\] :: \[$bldylw\]\w\[$txtrst\]\n\$ "

if [ -f "$HOME/.bash_local" ] ; then
	source "$HOME/.bash_local"
fi

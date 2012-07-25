# .bashrc
# Source global definitions
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi

# User specific aliases and functions
. ~/.bash-colors
PS1="\[$txtgrn\]\u\[$txtrst\]@\[$txtcyn\]\h\[$txtrst\] :: \[$bldylw\]\w\[$txtrst\]\n\$ "

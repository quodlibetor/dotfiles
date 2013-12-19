#! /bin/bash
# .bashrc
# Source global definitions
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

if [ -d "$HOME/.local/bin" ] ; then
    export PATH="$PATH:$HOME/.local/bin"
fi

shopt -s extglob
shopt -s globstar 2>/dev/null  # globstar doesn't exist on old versions of bash

if [ -z "$PYTHONPATH" ] ; then
    PYTHONPATH="$HOME/.local/lib/python2.6/site-packages/"
else
    PYTHONPATH="$HOME/.local/lib/python2.6/site-packages/:$PYTHONPATH"
fi

export PYTHONSTARTUP="$HOME/.pythonrc"

# User specific aliases and functions
. ~/.bash-colors
PS1="\[$txtgrn\]\u\[$txtrst\]@\[$txtcyn\]\h\[$txtrst\] :: \[$bldylw\]\w\[$txtrst\]\n\$ "

if [ -f "$HOME/.bash_local" ] ; then
    source "$HOME/.bash_local"
fi

if [ -f "$HOME/.bashfuncs" ] ; then
    source "$HOME/.bashfuncs"
fi

sv() {
    echo 'starting virtualenvwrapper'
    source /usr/local/bin/virtualenvwrapper.sh
}

workon() {
    sv
    workon $@
}

ff() {
    echo 'ps -ef | grep --color=always -E '$2' "(PID|'$1')" | grep -v grep'
    ps -ef | grep --color=always -E $2 "(PID|$1)" | grep -v grep
}

alias py27=python27

alias ls="ls --color=auto"
alias ll="ls -l"

pysite=/usr/lib/python2.7/site-packages
log=/var/log

project=CHANGE_ME
plog=/var/log/ragu/${project}
pbase=/var/www/${project}
psite=${ibase}/lib/python2.7/site-packages

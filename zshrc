if [ -n "$PATH" ] ; then
    export PATH="/home/bwm/.local/bin:/usr/lib/lightdm/lightdm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:$PATH"
else
    export PATH=/home/bwm/.local/bin:/usr/lib/lightdm/lightdm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games
fi
# Path to your oh-my-zsh configuration.
ZSH=$HOME/.oh-my-zsh

# Set name of the theme to load.
# Look in ~/.oh-my-zsh/themes/
# Optionally, if you set this to "random", it'll load a random theme each
# time that oh-my-zsh is loaded.
ZSH_THEME="bwm"

# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"

# Set to this to use case-sensitive completion
# CASE_SENSITIVE="true"

# Comment this out to disable weekly auto-update checks
# DISABLE_AUTO_UPDATE="true"

# Uncomment following line if you want to disable colors in ls
# DISABLE_LS_COLORS="true"

# Uncomment following line if you want to disable autosetting terminal title.
DISABLE_AUTO_TITLE="true"

# Uncomment following line if you want red dots to be displayed while waiting for completion
# COMPLETION_WAITING_DOTS="true"

# Which plugins would you like to load? (plugins can be found in ~/.oh-my-zsh/plugins/*)
# Custom plugins may be added to ~/.oh-my-zsh/custom/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
plugins=(git autojump pip django)

source $ZSH/oh-my-zsh.sh

[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# Customize to your needs...
export PYTHONSTARTUP="$HOME/.pythonrc"
export EDITOR=vim
export VISUAL=$EDITOR
export VIRTUALENV_USE_DISTRIBUTE=true
export PIP_DOWNLOAD_CACHE=$HOME/.pip/cache

export JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:bin/java::")
source $HOME/.aws-setup

svnbase="https://svn.advance.net"
svngae="$svnbase/advance-gae"
svnsrv="$svnbase/advance-services"
svnsvc=$svnsrv
rpmsrc="$HOME/rpmbuild/SOURCES"
rpmrpm="$HOME/rpmbuild/RPMS/noarch"
rpm="$HOME/rpmbuild"
pysite=/usr/lib/python2.7/dist-packages

if whence gnome-open >/dev/null ; then
    alias -r o=gnome-open
fi

alias -r la="ls -a"
alias -r ll="ls -lh"
alias -r ipy=ipython
alias -r xsel="xsel --clipboard"
alias -r pyup="python setup.py register -r advance sdist upload -r advance"
alias -r ect="emacsclient -t"

sv() {
        echo 'starting virtualenvwrapper'
        source /usr/local/bin/virtualenvwrapper.sh
}

workon() {
        sv
        workon $@
}

ff() {
   ps -ef | grep --color=always -E $2 "(PID|$1)" | grep -v grep
}

exps1() {
    if [ x$inexps1 = x ] ; then
        exps1_oldps1="$PS1"
        PS1="================================================================================
$ "
        inexps1=y
    else
        PS1="$exps1_oldps1"
        inexps1=
    fi
}

pipi() {
    set -x
    if ! =pip install --find-links file://$HOME/.pip/cache --no-index $@
    then
        =pip install --download $HOME/.pip/cache $@
        =pip install --find-links file://$HOME/.pip/cache --no-index $@
    fi
    set +x
}

# make sure that ssh-agent doesn't always ask me for a password
# seems to be idempotent?
eval $( gnome-keyring-daemon --start 2>/dev/null )

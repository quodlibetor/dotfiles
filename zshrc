if [ -n "$PATH" ] ; then
    export PATH="/home/bwm/.local/bin:/usr/lib/lightdm/lightdm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:$PATH"
else
    export PATH=/home/bwm/.local/bin:/usr/lib/lightdm/lightdm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games
fi
# Path to your oh-my-zsh configuration.
ZSH=$HOME/.oh-my-zsh

setopt share_history

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
plugins=(git autojump pip bundle django vagrant knife homebrew aws ansible docker zsh-syntax-highlighting)

source $ZSH/oh-my-zsh.sh

[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# enable M-x edit-command-line to open current command in vim
autoload edit-command-line
zle -N edit-command-line

# Customize to your needs...
export PYTHONSTARTUP="$HOME/.pythonrc"
export EDITOR=vim
export VISUAL=$EDITOR
export VIRTUALENV_USE_DISTRIBUTE=true
export PIP_DOWNLOAD_CACHE=$HOME/.pip/url_cache

export JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:bin/java::")
if [[ $(uname) == Darwin ]] ; then
    export CLICOLOR=1
    export LSCOLORS=GxFxCxDxBxegedabagaced
fi


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
alias -r emacsf="open -a /usr/local/Cellar/emacs/HEAD/Emacs.app/Contents/MacOS/Emacs"
alias -r em="emacsclient"
alias -r emn="emacsclient --no-wait"
alias -r emt="emacsclient -t"
alias -r emc="emacsclient --create-frame --no-wait"
alias -r new_ssh='ssh -i ~/.ssh/temporary_knewton_launch_key.pem -o GSSAPIKeyExchange=no'
alias -r mfind="mdfind -onlyin . -name"
alias -r bup="be berks upload --no-freeze"
alias -r bdev="be berks install && be berks upload --no-freeze"
alias -r knife=/opt/chefdk/bin/knife
alias -g listening="lsof -i -n -P | egrep 'COMMAND|LISTEN'"

sv() {
        echo 'starting virtualenvwrapper'
        source /usr/local/bin/virtualenvwrapper.sh
}

workon() {
        sv
        workon $@
}

ff() {
   ps -eo "user pid ppid %cpu %mem time args" | grep -Ev 'ps -eo|grep' | grep -i -E $2 "( PID |$1)"
}

fssh() {
    if [[ -n "$VIRTUAL_ENV" ]] ; then
        old_venv=$( basename $VIRTUAL_ENV )
        deactivate
    fi

    ssh $1 "echo -n"  # firstssh doesn't handle initial logins great
    firstssh $1

    [[ -n "$old_venv" ]] && workon $old_venv
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

export MANPATH="$MANPATH:$HOME/.local/man:$HOME/.local/share/man"
man() {
    env LESS_TERMCAP_mb=$'\E[01;31m' \
    LESS_TERMCAP_md=$'\E[01;38;5;74m' \
    LESS_TERMCAP_me=$'\E[0m' \
    LESS_TERMCAP_se=$'\E[0m' \
    LESS_TERMCAP_so=$'\E[38;5;246m' \
    LESS_TERMCAP_ue=$'\E[0m' \
    LESS_TERMCAP_us=$'\E[04;38;5;146m' \
    man "$@"
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

fullhost() {
    grep -A1 "Host ${1}$" ~/.ssh/config | awk '/HostName/ {print $2}'
}
# make sure that ssh-agent doesn't always ask me for a password
# seems to be idempotent?
eval $( gnome-keyring-daemon --start 2>/dev/null )

# aws-things
[ -f "$HOME"/.aws-setup ] && source $HOME/.aws-setup
if [ -d "$HOME"/.awssh ] ; then
    fpath=($HOME/.awssh $fpath)
    autoload -U compinit ; compinit
    source $HOME/.awssh/awssh.sh
fi

export NOSE_WITH_PROGRESSIVE=y

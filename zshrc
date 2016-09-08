# -*- mode: shell-script -*-
if [ -n "$PATH" ] ; then
    export PATH="$HOME/.local/bin:$HOME/Library/Python/2.7/bin:/usr/lib/lightdm/lightdm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:$PATH:$HOME/Library/Haskell/bin:/usr/local/opt/go/libexec/bin:/Users/bwm/.multirust/toolchains/nightly/cargo/bin:/Users/bwm/.multirust/toolchains/stable/cargo/bin:$HOME/.cargo/bin:$HOME/.pyenv/versions/3.4.5/bin:/Users/bwm/anaconda3/bin"
else
    export PATH="$HOME/.local/bin:/usr/lib/lightdm/lightdm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/opt/go/libexec/bin:/Users/bwm/.multirust/toolchains/nightly/cargo/bin:/Users/bwm/.cargo/bin:/Users/bwm/.multirust/toolchains/nightly/cargo/bin:$HOME/.cargo/bin:$HOME/.pyenv/versions/3.4.5/bin:/Users/bwm/anaconda3/bin"
fi

[ -n "$JUST_WANT_PATH" ] && return

[[ -d "$HOME/.local/share/packer" ]] && export PATH="$PATH:$HOME/.local/share/packer"
# Path to your oh-my-zsh configuration.
ZSH=$HOME/.oh-my-zsh

setopt share_history

# Set name of the theme to load.
# Look in ~/.oh-my-zsh/themes/
# Optionally, if you set this to "random", it'll load a random theme each
# time that oh-my-zsh is loaded.
ZSH_THEME="bwm"

# Uncomment following line if you want to disable autosetting terminal title.
DISABLE_AUTO_TITLE="true"

# Which plugins would you like to load? (plugins can be found in ~/.oh-my-zsh/plugins/*)
# Custom plugins may be added to ~/.oh-my-zsh/custom/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
plugins=(git pytest autojump pip bundle django vagrant knife homebrew aws ansible docker zsh-syntax-highlighting)

source $ZSH/oh-my-zsh.sh
FPATH="$HOME/.fpath:$FPATH"

autoload -U deer
zle -N deer
bindkey '\ek' deer

[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# enable M-x edit-command-line to open current command in vim
autoload edit-command-line
zle -N edit-command-line

# Customize to your needs...
export PYTHONSTARTUP="$HOME/.pythonrc"
export VIRTUALENV_PYTHON=/usr/local/bin/python
export EDITOR=vim
export VISUAL=$EDITOR
export VIRTUALENV_USE_DISTRIBUTE=true
export PIP_DOWNLOAD_CACHE=$HOME/.pip/url_cache

if [[ $(uname) == Darwin ]] ; then
    export CLICOLOR=1
    export LSCOLORS=GxFxCxDxBxegedabagaced
fi

#if [[ -z $JAVA_HOME ]] ; then
#    export JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:bin/java::")
#fi

pysite=/usr/lib/python2.7/dist-packages

if whence gnome-open >/dev/null ; then
    alias -r o=gnome-open
fi

each () {
        find=$1
        shift
        for found in $(find $PWD -name $find)
        do
                dir=$(dirname $found)
                pushd "$dir" > /dev/null
                echo $dir && $@
                popd > /dev/null
        done
}

alias -r la="ls -a"
alias -r ll="ls -lh"
alias -r ipy=ipython
alias -r pytest="py.test"  # omg
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

ec2refresh(){
    vpc=${1:-sandbox}
    ANSIBLE_ENV=${vpc} ./ec2.py --refresh-cache >/dev/null
}

klone() {
    hub clone Knewton/$1
}

sv() {
        echo 'starting virtualenvwrapper'
        source /usr/local/bin/virtualenvwrapper.sh
}

psgrep() {
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
ussh() {
    host=$1
    shift
    ssh $host -i ~/.ssh/temporary_knewton_launch_key.pem
    if [[ $? -ge 1 ]] ; then
        echo "trying again as ubuntu with temp key"
        ssh ubuntu@$host $@ -i ~/.ssh/temporary_knewton_launch_key.pem
    fi
    if [[ $? -ge 1 ]] ; then
        echo "trying again as ubuntu with Ananlytics 001 key"
        ssh ubuntu@$host $@ -i ~/.ssh/analytics-001.pem
    fi
    if [[ $? -ge 1 ]] ; then
        echo "trying again as ubuntu with Staging 001 key"
        ssh ubuntu@$host $@ -i ~/.ssh/staging-001.pem
    fi
    if [[ $? -ge 1 ]] ; then
        echo "trying again as ubuntu with Production  001 key"
        ssh ubuntu@$host $@ -i ~/.ssh/production-001.pem
    fi
    if [[ $? -ge 1 ]] ; then
        echo "trying as default user without gssapi key exchange"
        ssh $host $@ -i ~/.ssh/temporary_knewton_launch_key.pem -o GSSAPIKeyExchange=no
    fi
    if [[ $? -ge 1 ]] ; then
        echo "trying as ubuntu without gssapi key exchange"
        ssh ubuntu@$host $@ -i ~/.ssh/temporary_knewton_launch_key.pem -o GSSAPIKeyExchange=no
    fi
}
assh() {
    ssh -i ~/.ssh/ansible_deployed.pem ubuntu@$1
}

# ssh into a running instance by id
sshid() {
    ip=$(aws ec2 describe-instances --instance-ids $1 | jq '.Reservations[0].Instances[0].PublicIpAddress' | tr -d \" )
    if [[ -n $ip ]] ; then
        ussh $ip
    else
        echo "No IP found for $1, do you have the right keys set up?"
    fi
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
ks() {
    /opt/chefdk/bin/knife search node "name:*${1}*"
}
kbox() {
    /opt/chefdk/bin/knife search node "name:*${1}*" | grep IP | cut -d ' ' -f 2
}

################
# brew-workarounds
brew() {
   /usr/local/bin/brew $@ && rehash 
}
if [[ -d /usr/local/opt/coreutils/libexec/gnubin ]] ; then
    export PATH="/usr/local/opt/coreutils/libexec/gnubin:$PATH"
    eval `dircolors ~/.dir_colors.solarized-dark`
    alias ls='ls --color=auto'
fi

alias ls=exa
alias be='bundle exec'

[[ -d /usr/local/opt/coreutils/libexec/gnuman ]] && export MANPATH="/usr/local/opt/coreutils/libexec/gnuman:$MANPATH"

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

availablesubnets() {
    aws ec2 describe-subnets | jq '.Subnets[] | select(.AvailabilityZone == "'$1'") | .CidrBlock' | tr -d '"' | sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4
}

aplay() {
  env=$1
  shift
  ANSIBLE_ENV=$env \
      /Users/bwm/findable/virtualenvs/ansible/bin/ansible-playbook \
      -i ec2.py --vault-password-file $vpf \
      $@
}

gfind() {
    git ls-files | grep $@
}

toggle_knewton_pypi() {
  local real=$HOME/.pip/pip.conf
  local deactive=$HOME/.pip/pip.unconf
  if [[ -f $real ]] ; then
      mv $real $deactive
      echo "deactivated pypi.knewton.net"
  else
      mv $deactive $real
      echo "activated pypi.knewton.net"
  fi
}
makequod() {
  if ! grep quodlibetor@gmail.com .git/config ; then
    echo "[user]
        name = Brandon W Maister
        email = quodlibetor@gmail.com" >> .git/config
  fi
}

export NOSE_WITH_PROGRESSIVE=y

. /Users/bwm/Library/Python/2.7/bin/virtualenvwrapper.sh

[[ -f $HOME/.zsh_local ]] && . $HOME/.zsh_local

export PATH="$PATH:$HOME/.rvm/bin" # Add RVM to PATH for scripting
export GOPATH=$HOME/go
export PATH="$PATH:$HOME/go/bin"

# export EC2_CERT=~/.aws/credentials/packer/cert.pem
# export EC2_PRIVATE_KEY=~/.aws/credentials/packer/pk.pem

eval `opam config env`
export JAVA_HOME=$(/usr/libexec/java_home)

LESSPIPE=`which src-hilite-lesspipe.sh`

export LESSOPEN="| ${LESSPIPE} %s"
export LESS='-R'

alias -g dnop='peter dmitriy dsiegel'
alias -r rnop='kerrit r s peterk dmitriy dsiegel'
alias -r rlearn='kerrit r s ludovic davidh martin'
alias -g jl='| jq -C . | less -R'
export FZF_DEFAULT_OPTS='--extended-exact'
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Load keys for kcs but then unset the generic ones for ansible
[ -f ~/.creds/aws ] && . ~/.creds/aws
unset AWS_ACCESS_KEY_ID ; unset AWS_SECRET_ACCESS_KEY

# ansible/consul things
vpf=~/.creds/data-bag-secret
peu=service.production-euwest1.consul
pus=service.production-useast1.consul
sus=service.staging-useast1.consul
syus=service.systems-useast1.consul
sbx=service.sandbox-useast1.consul
uus=service.uat-useast1.consul
cuus=service.classicuat-useast1.consul
biggie=service.biggie-useast1.consul

alias -r nopssl='brew switch openssl 1.0.1j_1'
alias -r kerssl='brew switch openssl 1.0.2d_1'

# Enable autosuggestions automatically.
#zle-line-init() {
#    zle autosuggest-start
#}
#zle -N zle-line-init
cint=classicqa-useast1-consumerint
cqa=classicqa-useast1-consumerqa
dev=classicdev-useast1
con=consumer-useast1
# eval $( docker-machine env dev )
export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="tcp://192.168.99.100:2376"
export DOCKER_CERT_PATH="/Users/bwm/.docker/machine/machines/dev"
export DOCKER_MACHINE_NAME="dev"

alias -r kssha="kssh -a -t tmux"
alias -r nopbpu="nop p b && nop p p && nop p u"

# added by travis gem
[ -f /Users/bwm/.travis/travis.sh ] && source /Users/bwm/.travis/travis.sh
. /Users/bwm/findable/virtualenvs/awscli-binstub/bin/aws_zsh_completer.sh
. ~/.consumer-completions.sh

rename-tab() {
    TAB_NAME="$1"
    tmux rename-window -t${TMUX_PANE} "$1"
}

unalias run-help
autoload run-help
HELPDIR=/usr/local/share/zsh/help
alias -r con=consumer
krs() {
    git pull -r origin master && kerrit r s $@
}

export NVM_DIR="/Users/bwm/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm
export RUST_NEW_ERROR_FORMAT=true

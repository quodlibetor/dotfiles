# https://github.com/blinks zsh theme

current_service() {
  if [[ -n $TAB_NAME ]] ; then
    echo $TAB_NAME
    return
  fi
  service=${PWD[(ws:/services/:)2]}
  if [[ $service = $PWD ]] ; then
    service=${PWD[(ws:/tools/:)2]}
  fi
  if [[ $service = $PWD ]] ; then
    service=${PWD[(ws:/src/:)2]}
  fi
  if [[ $service = $PWD ]] ; then
    service=${PWD[(ws:/projects/:)2]}
  fi
  if [[ $service = $PWD ]] ; then
    service=${PWD[(ws:/gerrit/:)2]}
  fi
  if [[ $service = $PWD ]] ; then
    service=${SHELL:t}
  fi
  echo ${service%%/*}
}

# print the virtualenv with a newline
virtualenv_info(){
    if [[ -n "$VIRTUAL_ENV" ]]; then
        # Strip out the path and just leave the env name
        venv="${VIRTUAL_ENV##*/}"
        echo "($venv)"
    fi
}

# disable the default virtualenv prompt change
export VIRTUAL_ENV_DISABLE_PROMPT=1

# This theme works with both the "dark" and "light" variants of the
# Solarized color schema.  Set the SOLARIZED_THEME variable to one of
# these two values to choose.  If you don't specify, we'll assume you're
# using the "dark" variant.

case ${SOLARIZED_THEME:-dark} in
    light) bkg=white;;
    *)     bkg=black;;
esac

#ZSH_THEME_GIT_PROMPT_PREFIX=" [%{%B%F{blue}%}"
#ZSH_THEME_GIT_PROMPT_SUFFIX="%{%f%k%b%K{${bkg}}%B%F{green}%}]"
#ZSH_THEME_GIT_PROMPT_DIRTY=" %{%F{red}%}*%{%f%k%b%}"
#ZSH_THEME_GIT_PROMPT_CLEAN=""

if [[ $(uname) = Darwin ]] ; then
    name=$( scutil --get LocalHostName )
else
    name='%m'
fi


PROMPT='%{%K{${bkg}}$(virtualenv_info)$(date +%H:%M)%B%F{green}%}%n%{%B%F{blue}%}@%{%B%F{cyan}%}'$name'%{%B%F{green}%} %{%b%F{yellow}%K{${bkg}}%}%~%{%k%}$(git-radar --zsh)%E%{%f%k%b%}
$ $(tmux rename-window -t${TMUX_PANE} $(current_service))'

#RPROMPT='!%{%B%F{cyan}%}%!%{%f%k%b%}'

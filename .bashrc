# ~/.bashrc: executed by bash(1) for non-login shells

# Exit early if not an interactive shell
case $- in
*i*) ;;
*) return ;;
esac

# Prompt color support
case "$TERM" in
xterm-color | *-256color) color_prompt=yes ;;
esac

# Enable colored prompt if possible
force_color_prompt=yes
if [ -n "$force_color_prompt" ]; then
  if command -v tput &>/dev/null && tput setaf 1 &>/dev/null; then
    color_prompt=yes
  else
    color_prompt=
  fi
fi

# Load dircolors if available
[ -f "$HOME/.config/dircolors/current" ] && eval "$(dircolors "$HOME/.config/dircolors/current")"

# History settings
export HISTCONTROL=ignoreboth:erasedups
HISTSIZE=1000
HISTFILESIZE=2000
HISTTIMEFORMAT='%F %T '
shopt -s histappend
shopt -s checkwinsize

# Enable lesspipe for better file preview
command -v lesspipe &>/dev/null && eval "$(SHELL=/bin/sh lesspipe)"

# Alias support
[ -f "$HOME/.bash_aliases" ] && . "$HOME/.bash_aliases"

# Bash completion
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Reuse persistent ssh-agent
SSH_ENV="$HOME/.ssh/agent.env"
start_agent() {
  (
    umask 077
    ssh-agent >"$SSH_ENV"
  )
  . "$SSH_ENV" >/dev/null
}
if [ -f "$SSH_ENV" ]; then
  . "$SSH_ENV" >/dev/null
  ps -p "$SSH_AGENT_PID" &>/dev/null || start_agent
else
  start_agent
fi

# PATH entries (prepend for priority)
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
[ -d "/opt/nvim-linux-x86_64/bin" ] && export PATH="/opt/nvim-linux-x86_64/bin:$PATH"

# pyenv setup (only if installed)
if command -v pyenv &>/dev/null; then
  export PATH="$HOME/.pyenv/bin:$PATH"
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
  eval "$(pyenv virtualenv-init -)"
fi

# nvm setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Starship prompt
command -v starship &>/dev/null && eval "$(starship init bash)"

# Auto-start tmux if available and not already inside tmux
if command -v tmux &>/dev/null && [ -z "$TMUX" ]; then
  tmux attach -t default || tmux new -s default
fi

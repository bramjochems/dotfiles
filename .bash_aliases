alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

alias ll='ls -alhF'

alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

alias npm-update='npm install -g $(npm outdated -g --parseable --depth=0 | cut -d: -f4)'

# AWS (Medi-Invest org): log in via IAM Identity Center; covers profiles lcct, medi-invest, management
alias aws-login='aws sso login --sso-session medi-invest --use-device-code'

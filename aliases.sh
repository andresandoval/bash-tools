alias ll='ls -al --color=auto'

alias ssh-config-tool='sh /home/asandoval/Git/bash-tools/ssh-config-tool.sh'
alias ssh-config-tool-swap-pfpt='ssh-config-tool --swap PFPT'
alias ssh-config-tool-swap-reg='ssh-config-tool --swap REGULAR'
alias ssh-config-tool-check='ssh-config-tool --check'
alias sshct-s-pfpt='ssh-config-tool-swap-pfpt'
alias sshct-s-reg='ssh-config-tool-swap-reg'
alias sshct-check='ssh-config-tool-check'


alias to-clipboard='xclip -selection clipboard'
alias goto-git-root='cd $(git rev-parse --show-toplevel)'
alias gedit='gnome-text-editor'
alias git-prune='sh /home/asandoval/Git/bash-tools/git-prune.sh'
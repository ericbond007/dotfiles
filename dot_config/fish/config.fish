source /usr/share/cachyos-fish-config/cachyos-config.fish
alias vi='nvim'
alias reload='source ~/.config/fish/config.fish'
fnm env --use-on-cd | source

# overwrite greeting
# potentially disabling fastfetch
#function fish_greeting
#    # smth smth
#end

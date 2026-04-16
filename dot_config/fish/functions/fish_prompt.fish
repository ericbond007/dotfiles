function fish_prompt
    set -l ttyname (tty | string replace '/dev/' '')
    set -l magenta (set_color magenta)
    set -l normal (set_color normal)

    echo -n (whoami)
    echo -n $magenta'<|'$ttyname'|>'$normal
    echo -n (prompt_hostname)
    echo -n $magenta'['(date +%T)'] '(prompt_pwd --full-length-dirs 100)'>'
    echo
    echo -n $normal'$ '
end

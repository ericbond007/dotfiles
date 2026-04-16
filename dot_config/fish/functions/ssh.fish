function ssh --wraps=ssh --description 'ssh with tmux window rename'
    if set -q TMUX
        # Extract hostname: skip flags and their arguments, take the first bare argument
        set -l host
        set -l skip_next false
        for arg in $argv
            if $skip_next
                set skip_next false
                continue
            end
            switch $arg
                case '-o' '-p' '-l' '-i' '-F' '-J' '-L' '-R' '-D' '-W' '-b' '-c' '-e' '-m' '-O' '-Q' '-S' '-w' '-E'
                    set skip_next true
                case '-*'
                    # flags without arguments
                case '*'
                    set host $arg
                    break
            end
        end

        if test -n "$host"
            # Strip user@ prefix if present
            set -l display_host (string replace -r '.*@' '' $host)
            tmux rename-window "$display_host:ssh"
        end
    end

    command ssh $argv

    if set -q TMUX
        tmux set-window-option automatic-rename on
    end
end

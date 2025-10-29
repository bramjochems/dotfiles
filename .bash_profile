# ~/.bash_profile
if [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi

# >>> juliaup initialize >>>

# !! Contents within this block are managed by juliaup !!

case ":$PATH:" in
    *:/home/bram/.juliaup/bin:*)
        ;;

    *)
        export PATH=/home/bram/.juliaup/bin${PATH:+:${PATH}}
        ;;
esac

# <<< juliaup initialize <<<

#!/usr/bin/env fish
# Manage a container named after the current directory.
#   c init [extra create args]   create it (e.g. c init -v $PWD:/work)
#   c start                      start it and attach

set -l name (path basename $PWD)

switch $argv[1]
    case init
        container create --name $name --ssh -it $argv[2..-1] nix-container:latest
    case start
        container start -ai $name
    case '*'
        echo "usage: c init|start" >&2
        exit 1
end

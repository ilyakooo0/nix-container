#!/usr/bin/env fish
# Manage a container named after the current directory.
#   c init [extra create args]   build + load the image, then create the container
#   c start                      start it and attach

set -l name (path basename $PWD)
# The flake lives next to this script (resolve symlinks so it works from $PATH too).
set -l flake (path dirname (path resolve (status filename)))

switch $argv[1]
    case init
        # Build the OCI archive into a temp dir, load it, then clean up.
        set -l tmp (mktemp -d)
        nix run $flake -- $tmp/image.tar.gz; and container image load --input $tmp/image.tar.gz
        set -l rc $status
        rm -rf $tmp
        test $rc -eq 0; or exit $rc
        container create --name $name --ssh -it $argv[2..-1] nix-container:latest
    case start
        container start -ai $name
    case '*'
        echo "usage: c init|start" >&2
        exit 1
end

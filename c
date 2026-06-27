#!/usr/bin/env fish
# Manage a container named after the current directory.
#   c init [-c FILE] [extra create args]   build + load the image, then create it
#                                          (packages from FILE, default ./container.nix)
#   c start                                start it and attach

set -l name (path basename $PWD)
# The flake lives next to this script (resolve symlinks so it works from $PATH too).
set -l flake (path dirname (path resolve (status filename)))

switch $argv[1]
    case init
        # -c/--config overrides the default ./container.nix; leftover args (e.g.
        # mounts) are forwarded to `container create`.
        argparse --ignore-unknown 'c/config=' -- $argv[2..-1]
        or exit 1
        set -l config container.nix
        set -l explicit 0
        if set -q _flag_config
            set config $_flag_config
            set explicit 1
        end

        # Build the OCI archive into a temp dir, load it, then clean up.
        set -l tmp (mktemp -d)
        set -l archive $tmp/image.tar.gz
        set -l rc 0

        if test -e $config
            # Per-project package set: build an image with exactly these packages.
            set -lx NIX_CONTAINER_PKGS (path resolve $config)
            set -l expr "(builtins.getFlake \"$flake\").lib.\${builtins.currentSystem}.copyWith (import (/. + builtins.getEnv \"NIX_CONTAINER_PKGS\"))"
            set -l copyer (nix build --impure --no-link --print-out-paths --expr "$expr")
            set rc $status
            if test $rc -eq 0
                $copyer/bin/copy-to "oci-archive:$archive:nix-container:latest"
                set rc $status
            end
        else if test $explicit -eq 1
            echo "c: config file not found: $config" >&2
            rm -rf $tmp
            exit 1
        else
            nix run "$flake#image" -- "oci-archive:$archive:nix-container:latest"
            set rc $status
        end

        if test $rc -eq 0
            container image load --input $archive
            set rc $status
        end

        rm -rf $tmp
        test $rc -eq 0; or exit $rc

        container create --name $name --ssh -it $argv nix-container:latest
    case start
        container start -ai $name
    case '*'
        echo "usage: c init [-c FILE] [create args] | start" >&2
        exit 1
end

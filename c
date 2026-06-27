#!/usr/bin/env fish
# Manage a container named after the current directory.
#   c init [-c FILE] [extra create args]   build + load the image, then (re)create it
#                                          (packages from FILE, default ./container.nix)
#   c start                                start it and attach

set -l name (path basename $PWD)
# The flake lives next to this script (resolve symlinks so it works from $PATH too).
set -l flake (path dirname (path resolve (status filename)))
# Image ref this script loads and runs (the archive tag + `create` reference).
set -l image nix-container:latest

switch $argv[1]
    case init
        # -c/--config overrides the default ./container.nix; leftover args (e.g.
        # mounts) are forwarded to `container create`.
        argparse --ignore-unknown 'c/config=' -- $argv[2..-1]
        or exit 1
        set -l config container.nix
        if set -q _flag_config
            set config $_flag_config
        end

        if not test -e $config
            echo "c: package file not found: $config" >&2
            echo "    create one ('{ pkgs, nur }: [ ... ]') or pass -c FILE" >&2
            exit 1
        end

        # Build an image with exactly the packages from $config, into a temp
        # dir, load it, then clean up.
        set -l tmp (mktemp -d)
        set -l archive $tmp/image.tar.gz
        set -lx NIX_CONTAINER_PKGS (path resolve $config)
        set -l expr "(builtins.getFlake \"$flake\").lib.\${builtins.currentSystem}.copyWith (import (/. + builtins.getEnv \"NIX_CONTAINER_PKGS\"))"
        set -l copyer (nix build --impure --no-link --print-out-paths --expr "$expr")
        set -l rc $status
        if test $rc -eq 0
            $copyer/bin/copy-to "oci-archive:$archive:$image"
            set rc $status
        end
        if test $rc -eq 0
            container image load --input $archive
            set rc $status
        end

        rm -rf $tmp
        test $rc -eq 0; or exit $rc

        # Mount the project at /workspace (the default cwd) and host ~/.config.
        # (Mounting ~/.config shadows the image's bundled fish prompt config.)
        set -l mounts -v "$PWD:/workspace"
        test -d $HOME/.config; and set -a mounts -v "$HOME/.config:/root/.config"

        # Replace any existing container of the same name.
        container rm --force $name 2>/dev/null
        container create --name $name --ssh -it --cwd /workspace $mounts $argv $image
    case start
        container start -ai $name
    case '*'
        echo "usage: c init [-c FILE] [create args] | start" >&2
        exit 1
end

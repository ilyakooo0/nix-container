#!/usr/bin/env fish
# Manage a container named after the current directory.
#   c init [-c FILE] [extra create args]   build + load the image, then (re)create it
#                                          (config from FILE, default ./container.nix)
#   c start                                start it and attach

set -l name (path basename $PWD)
# The flake lives next to this script (resolve symlinks so it works from $PATH too).
set -l flake (path dirname (path resolve (status filename)))
# Per-directory image ref this script loads and runs (archive tag + `create`).
set -l image "nix-container-$name:latest"

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
            echo "c: config file not found: $config" >&2
            echo "    create one ('{ packages = { pkgs, nur }: [ ... ]; mounts = [ ]; }') or pass -c FILE" >&2
            exit 1
        end

        # Host login shell (by name): added to the image automatically and baked
        # in as the cmd + default $SHELL (what zellij panes etc. spawn), so it
        # needn't be listed in container.nix. Falls back to bash.
        set -l shell bash
        test -n "$SHELL"; and set shell (path basename $SHELL)

        # Build an image with the config's `packages` (plus the shell) into a
        # temp dir, load it, then clean up.
        set -l tmp (mktemp -d)
        set -l archive $tmp/image.tar.gz
        set -lx NIX_CONTAINER_CONFIG (path resolve $config)
        set -l expr "(builtins.getFlake \"$flake\").lib.\${builtins.currentSystem}.copyWithShell \"nix-container-$name\" \"$shell\" (import (/. + builtins.getEnv \"NIX_CONTAINER_CONFIG\")).packages"
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

        # Mount the project at /workspace (the default cwd), plus any extra
        # mounts from the config (`mounts = [ "host:container" … ]`). A leading
        # ~/ in the host path expands to $HOME (nix leaves it literal).
        set -l mounts -v "$PWD:/workspace"
        for m in (nix eval --impure --raw --expr "builtins.concatStringsSep \"\n\" ((import (/. + builtins.getEnv \"NIX_CONTAINER_CONFIG\")).mounts or [])")
            set -a mounts -v (string replace -r '^~/' "$HOME/" -- $m)
        end

        # TERM to bake into the container env (`-e TERM`): the runtime hands the
        # `start -ai` session a bare "xterm", so set the host's real terminal,
        # mapped to an entry the bundled ncurses ships — Ghostty reports
        # "xterm-ghostty", which ncurses ships as "ghostty" — falling back to
        # xterm-256color for an empty or bare-"xterm" value.
        set -l term xterm-256color
        if test "$TERM" = xterm-ghostty
            set term ghostty
        else if test -n "$TERM"; and test "$TERM" != xterm
            set term $TERM
        end

        # Replace any existing container of the same name. The image's cmd is
        # zellij (`c start` attaches to it), so no command is passed here.
        container rm --force $name 2>/dev/null
        # The image only lays down /bin and /etc, so /tmp and /run don't exist;
        # without them anything that writes temp files (zellij, build tools, …)
        # fails with ENOENT. Mount writable tmpfs at both.
        container create --name $name --ssh -it -e "TERM=$term" \
            --tmpfs /tmp --tmpfs /run --memory 8g --cwd /workspace $mounts $argv $image
    case start
        # Start the container and attach to its cmd (zellij). TERM was baked into
        # the container env at create time (`-e TERM`), which survives this path.
        # Exiting zellij (PID1) stops the container; `c start` boots it again.
        container start -ai $name
    case '*'
        echo "usage: c init [-c FILE] [create args] | start" >&2
        exit 1
end

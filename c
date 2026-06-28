#!/usr/bin/env fish
# Manage a container named after the current directory.
#   c init [-c FILE] [extra create args]   build + load the image, then (re)create it
#                                          (packages from FILE, default ./container.nix)
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
            echo "c: package file not found: $config" >&2
            echo "    create one ('{ pkgs, nur }: [ ... ]') or pass -c FILE" >&2
            exit 1
        end

        # Host login shell (by name): added to the image automatically and used
        # as the default shell (what zellij panes etc. spawn), so it needn't be
        # listed in container.nix. Falls back to bash.
        set -l shell bash
        test -n "$SHELL"; and set shell (path basename $SHELL)

        # Build an image with the packages from $config (plus the shell) into a
        # temp dir, load it, then clean up.
        set -l tmp (mktemp -d)
        set -l archive $tmp/image.tar.gz
        set -lx NIX_CONTAINER_PKGS (path resolve $config)
        set -l expr "(builtins.getFlake \"$flake\").lib.\${builtins.currentSystem}.copyWithShell \"$shell\" (import (/. + builtins.getEnv \"NIX_CONTAINER_PKGS\"))"
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
        # (fish runs with --no-config, so the mount can't shadow the prompt.)
        set -l mounts -v "$PWD:/workspace"
        test -d $HOME/.config; and set -a mounts -v "$HOME/.config:/root/.config"

        # Replace any existing container of the same name. The image's cmd is
        # /bin/fish, so no command is passed.
        container rm --force $name 2>/dev/null
        # Forward the host terminal type: the runtime strips $TERM down to a
        # bare "xterm", so pass the real value as HOST_TERM for the fish init to
        # recover (see prompt.fish) — TUIs need the matching terminfo entry.
        #
        # The image only lays down /bin and /etc, so /tmp and /run don't exist;
        # without them anything that writes temp files (zellij, build tools, …)
        # fails with ENOENT. Mount writable tmpfs at both.
        # SHELL=/bin/<detected> makes the host shell the default (zellij panes,
        # etc.); it overrides the image's baked-in SHELL=/bin/fish fallback.
        container create --name $name --ssh -it -e "HOST_TERM=$TERM" -e "SHELL=/bin/$shell" \
            --tmpfs /tmp --tmpfs /run --memory 8g --cwd /workspace $mounts $argv $image
    case start
        # Boot the container detached (its PID1 fish keeps it alive), then attach
        # an interactive shell with `exec -it`. `container start -ai` has no `-t`
        # flag, so it never hands the guest a properly sized TTY: the real window
        # size isn't delivered via the TIOCGWINSZ ioctl, so ioctl-based TUIs
        # (crossterm/ncurses — helix, zellij, btop…) see 0×0 and render garbled,
        # misaligned output. `exec -it` opens a real, correctly sized TTY.
        #
        # Launch zellij as the session. We go through fish's init first so the
        # TERM fixup in prompt.fish runs (otherwise zellij gets the runtime's bare
        # "xterm"), then `exec zellij` replaces fish — and if zellij fails to
        # start, fish stays interactive as a fallback.
        container start $name >/dev/null 2>&1; or exit 1
        container exec -it --cwd /workspace $name \
            /bin/fish --no-config --init-command "source /etc/fish/prompt.fish; exec zellij"
    case '*'
        echo "usage: c init [-c FILE] [create args] | start" >&2
        exit 1
end

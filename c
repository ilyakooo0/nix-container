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

# Terminal type to pass into the container via `-e TERM` (both create and exec):
# the runtime hands processes a bare "xterm", so we set the host's real terminal
# instead. Map it to an entry the bundled ncurses ships — Ghostty reports
# "xterm-ghostty", which ncurses ships as "ghostty" — falling back to
# xterm-256color for an empty or bare-"xterm" value.
set -l term xterm-256color
if test "$TERM" = xterm-ghostty
    set term ghostty
else if test -n "$TERM"; and test "$TERM" != xterm
    set term $TERM
end

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

        # Host login shell (by name): added to the image automatically and baked
        # in as the cmd + default $SHELL (what zellij panes etc. spawn), so it
        # needn't be listed in container.nix. Falls back to bash.
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

        # Mount the project at /workspace (the default cwd).
        set -l mounts -v "$PWD:/workspace"

        # Replace any existing container of the same name. The image's cmd is the
        # detected shell (holds the container open), so no command is passed.
        container rm --force $name 2>/dev/null
        # -e TERM: the runtime would otherwise force a bare "xterm" (see above).
        #
        # The image only lays down /bin and /etc, so /tmp and /run don't exist;
        # without them anything that writes temp files (zellij, build tools, …)
        # fails with ENOENT. Mount writable tmpfs at both.
        container create --name $name --ssh -it -e "TERM=$term" \
            --tmpfs /tmp --tmpfs /run --memory 8g --cwd /workspace $mounts $argv $image
    case start
        # Boot the container detached (its PID1 shell keeps it alive), then attach
        # the session with `exec -it`. `container start -ai` has no `-t` flag, so
        # it never hands the guest a properly sized TTY: the real window size
        # isn't delivered via the TIOCGWINSZ ioctl, so ioctl-based TUIs
        # (crossterm/ncurses — helix, zellij, btop…) see 0×0 and render garbled,
        # misaligned output. `exec -it` opens a real, correctly sized TTY, and
        # `-e TERM` gives it the right terminal type.
        #
        # When the session exits, stop the container so it doesn't linger (the
        # PID1 shell would otherwise keep it running); `c start` boots it again.
        container start $name >/dev/null 2>&1; or exit 1
        container exec -it -e "TERM=$term" --cwd /workspace $name zellij
        container stop $name >/dev/null 2>&1
    case '*'
        echo "usage: c init [-c FILE] [create args] | start" >&2
        exit 1
end

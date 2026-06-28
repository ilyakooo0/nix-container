{
  description = "A Nix-built OCI image for Apple's `container` CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    nur.url = "github:nix-community/NUR";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nur,
      nix2container,
    }:
    # Iterate over the systems you might run `nix run` from. The image
    # *contents* are always Linux; the system here only decides where the
    # `copyTo`/skopeo step executes (e.g. your Mac).
    flake-utils.lib.eachSystem
      [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ]
      (
        system:
        let
          # Map the host system to the Linux system the container targets, so
          # `nix run` on a Mac still produces a Linux image.
          linuxSystem =
            {
              aarch64-darwin = "aarch64-linux";
              x86_64-darwin = "x86_64-linux";
              aarch64-linux = "aarch64-linux";
              x86_64-linux = "x86_64-linux";
            }
            .${system};

          arch =
            {
              aarch64-linux = "arm64";
              x86_64-linux = "amd64";
            }
            .${linuxSystem};

          pkgsLinux = import nixpkgs {
            system = linuxSystem;
            config.allowUnfree = true;
          };

          # NUR for the container's Linux arch. Pass BOTH `pkgs` and `nurpkgs`
          # explicitly: otherwise the unset one defaults to `import <nixpkgs>`,
          # which fails in pure flake eval. `pkgs` builds the repo packages, so
          # give it `allowUnfree` (charmbracelet.crush is unfree); `nurpkgs` is
          # only NUR's own machinery and can stay the plain set.
          nurPkgs = import nur {
            nurpkgs = pkgsLinux;
            pkgs = pkgsLinux;
          };

          # nix2container instantiated for the host system, so `copyTo` and its
          # skopeo run natively here while contents come from `pkgsLinux`.
          n2c = nix2container.packages.${system}.nix2container;

          # Host package set, for the wrapper app below.
          pkgsHost = nixpkgs.legacyPackages.${system};

          # Name/tag baked into the image's OCI config.
          imageName = "nix-container";
          imageTag = "latest";

          # Fish prompt config. Installed at /etc/fish/prompt.fish and loaded via
          # `fish --no-config --init-command` (see `cmd` below), NOT from
          # $HOME/.config/fish — so the `~/.config` mount can't shadow it. Built
          # on the host arch (just a text file), so no Linux builder is needed.
          fishConfig = pkgsHost.writeText "prompt.fish" ''
            # No welcome banner.
            set -g fish_greeting

            # The container runtime hands fish a bare TERM=xterm (8 colors) and
            # no COLORTERM, washing out colors. The bundled terminfo DB (via
            # ncurses) has the 256-color entry, so promote xterm→xterm-256color
            # and advertise truecolor for 24-bit-aware tools.
            if test "$TERM" = xterm; or test -z "$TERM"
                set -gx TERM xterm-256color
            end
            set -q COLORTERM; or set -gx COLORTERM truecolor

            # Define the prompt as a function so fish renders it before every
            # command; at top level it would run once at startup and be ignored.
            function fish_prompt
                set -l nix_shell_info
                if set -q IN_NIX_SHELL; or set -q IN_NIX_RUN
                    set nix_shell_info ' ❄️'
                end

                set -l cwd (prompt_pwd)

                set -l bookmark_info
                if jj root 2>/dev/null >/dev/null
                    set -l jj_bookmark (jj log -r 'heads(::@ & bookmarks())' -T 'local_bookmarks ++ "\n"' --no-graph 2>/dev/null | tail -1)
                    if test -n "$jj_bookmark"
                        set bookmark_info ' ' (set_color brmagenta) $jj_bookmark (set_color normal)
                    end
                end

                echo -n -s (set_color $fish_color_cwd) $cwd (set_color normal) $bookmark_info ' 🏗️' $nix_shell_info '> '
            end
          '';

          # Lay the prompt out at the path the cmd sources.
          fishRoot = pkgsHost.runCommand "fish-prompt" { } ''
            mkdir -p "$out/etc/fish"
            cp ${fishConfig} "$out/etc/fish/prompt.fish"
          '';

          # Build the OCI image from a `{ pkgs, nur }: [ ... ]` package function.
          # The image always runs /bin/fish; fish, its prompt config, and Nix are
          # bundled automatically, so `container.nix` lists only your extras.
          mkImage =
            packages:
            n2c.buildImage {
              name = imageName;
              tag = imageTag;
              inherit arch;

              # A plain, single-process root filesystem. No NixOS, no systemd.
              # buildEnv only *symlinks* paths (never runs them), so build it on
              # the host arch — the tree is arch-neutral and links the
              # (substituted) Linux store paths, sparing the Linux builder.
              #
              # Always shipped: fish (the cmd) + its prompt, and Nix (+ CA certs)
              # so every container can use Nix; `initializeNixDatabase` registers
              # the baked store.
              copyToRoot = pkgsHost.buildEnv {
                name = "root";
                paths =
                  packages {
                    pkgs = pkgsLinux;
                    nur = nurPkgs;
                  }
                  ++ [
                    pkgsLinux.fish
                    fishRoot
                    pkgsLinux.nix
                    pkgsLinux.cacert
                    # Networking glue glibc needs: /etc/nsswitch.conf (+passwd,
                    # group) so DNS/host lookups resolve, and /etc/protocols,
                    # /etc/services. Without these, hostname resolution fails.
                    pkgsLinux.fakeNss
                    pkgsLinux.iana-etc
                  ];
                # Link all of /etc so the above files (nsswitch.conf, protocols,
                # services, passwd, group, ssl certs, fish prompt) are present.
                pathsToLink = [
                  "/bin"
                  "/etc"
                ];
              };

              initializeNixDatabase = true;

              config = {
                # `cmd` (not `entrypoint`): the default command, *replaced* by any
                # command passed to `container run/create`. `--no-config` skips
                # $HOME/.config/fish (so a mounted ~/.config can't override the
                # prompt); `--init-command` loads the bundled prompt instead.
                cmd = [
                  "/bin/fish"
                  "--no-config"
                  "--init-command"
                  "source /etc/fish/prompt.fish"
                ];
                env = [
                  "PATH=/bin"
                  "HOME=/root"
                  # Marker so shells/scripts can detect they're in here.
                  "NIX_CONTAINER=1"
                  # Advertise truecolor so `container exec` sessions (which don't
                  # source the fish init) still get 24-bit color. TERM is fixed up
                  # in the fish prompt init, since the runtime overrides it here.
                  "COLORTERM=truecolor"
                  # CA trust for every TLS client (curl/git/…) and Nix.
                  "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                  "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                  # Make the bundled Nix usable: flake commands on, and
                  # single-user (no daemon/nixbld).
                  "NIX_CONFIG=experimental-features = nix-command flakes\nbuild-users-group =\nsandbox = false"
                ];
              };
            };

          # `nix run . -- init|start` runs the bundled `c` manager script. Its
          # `init` builds the image from the project's `container.nix` (via
          # `lib.copyWith`); the script finds the flake from its own (store)
          # location, so this works from a checkout or straight from
          # `nix run github:…/nix-container`.
          cApp = pkgsHost.writeShellScriptBin "c" ''
            exec ${pkgsHost.fish}/bin/fish ${self}/c "$@"
          '';
        in
        {
          apps = {
            # nix run . -- init|start   → build+load+create / start a container
            default = flake-utils.lib.mkApp { drv = cApp; };
          };

          # Build helpers. `c init` uses `copyWith` to honour a per-project
          # `container.nix`:
          #   (builtins.getFlake "github:…/nix-container")
          #     .lib.<system>.copyWith (import ./container.nix)
          lib = {
            inherit mkImage;
            # skopeo copy app (`skopeo copy nix:<image> "$@"`) for an image built
            # from a `{ pkgs, nur }: [ ... ]` function.
            copyWith = packages: (mkImage packages).copyTo;
          };
        }
      );
}

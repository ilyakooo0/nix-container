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

          # Default image name (for `copyWith`); `c init` passes a per-directory
          # name (`nix-container-<dir>`) to `copyWithShell` instead.
          imageName = "nix-container";
          imageTag = "latest";

          # Build the OCI image (named `name`) from a `{ pkgs, nur }: [ ... ]`
          # package function, for the named shell. The image's `cmd` is zellij
          # (the session `c start` attaches to); the shell is the default `$SHELL`
          # (what zellij panes spawn) and is added automatically, so `container.nix`
          # lists only your extras. Nix (+ CA certs) and the ncurses terminfo
          # database are always shipped too. Nothing here is fish-specific: the
          # TERM fixup happens host-side in `c` (passed via `-e TERM` at create).
          mkImage =
            name: shell: packages:
            n2c.buildImage {
              inherit name;
              tag = imageTag;
              inherit arch;

              # A plain, single-process root filesystem. No NixOS, no systemd.
              # buildEnv only *symlinks* paths (never runs them), so build it on
              # the host arch — the tree is arch-neutral and links the
              # (substituted) Linux store paths, sparing the Linux builder.
              copyToRoot = pkgsHost.buildEnv {
                name = "root";
                paths =
                  packages {
                    pkgs = pkgsLinux;
                    nur = nurPkgs;
                  }
                  # The shell (cmd + $SHELL), when it exists in nixpkgs.
                  ++ pkgsLinux.lib.optional (pkgsLinux ? ${shell}) pkgsLinux.${shell}
                  ++ [
                    pkgsLinux.nix
                    pkgsLinux.cacert
                    # Basic userland (ls, cat, cp, sleep, …) so the container is
                    # usable out of the box and tools that shell out don't fail.
                    pkgsLinux.coreutils-full
                    # Networking glue glibc needs: /etc/nsswitch.conf (+passwd,
                    # group) so DNS/host lookups resolve, and /etc/protocols,
                    # /etc/services. Without these, hostname resolution fails.
                    pkgsLinux.fakeNss
                    pkgsLinux.iana-etc
                    # The terminfo database (+ tput/clear/reset) so TUIs find the
                    # entry for whatever TERM `c` passes in and render correctly.
                    pkgsLinux.ncurses
                    # The session `c start` always launches.
                    pkgsLinux.zellij
                  ];
                # Link all of /etc so the above files (nsswitch.conf, protocols,
                # services, passwd, group, ssl certs) are present.
                pathsToLink = [
                  "/bin"
                  "/etc"
                ];
              };

              initializeNixDatabase = true;

              config = {
                # `cmd` (not `entrypoint`): the default command, *replaced* by any
                # command passed to `container run/create`. Plain zellij here;
                # `c init` overrides it with `zellij --session <dir>-container` so
                # the session is named per project. `c start` attaches via
                # `container start -ai`; exiting zellij (PID1) stops the container.
                cmd = [ "/bin/zellij" ];
                env = [
                  "PATH=/bin"
                  "HOME=/root"
                  # Default shell for tools that spawn one (zellij panes, etc.).
                  "SHELL=/bin/${shell}"
                  # Marker so shells/scripts can detect they're in here.
                  "NIX_CONTAINER=1"
                  # Advertise truecolor for 24-bit-aware tools; `c` passes the
                  # resolved TERM via -e (the runtime would otherwise force xterm).
                  "COLORTERM=truecolor"
                  # A UTF-8 locale so tools handle multibyte/wide characters
                  # correctly. glibc ships C.UTF-8 built in, so this needs no
                  # locale-archive.
                  "LANG=C.UTF-8"
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
          # `lib.copyWithShell`); the script finds the flake from its own (store)
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

          # Build helpers take a `{ pkgs, nur }: [ ... ]` packages function (the
          # `packages` attr of a project's `container.nix`). `c init` uses
          # `copyWithShell` (host shell baked in); `copyWith` is the generic form:
          #   (builtins.getFlake "github:…/nix-container")
          #     .lib.<system>.copyWith (import ./container.nix).packages
          lib = {
            inherit mkImage;
            # Build the image's `copyTo` script (a skopeo-copy wrapper) from a
            # `{ pkgs, nur }: [ ... ]` function, named `imageName`. Defaults the
            # shell (cmd + $SHELL) to bash; use `copyWithShell` to pick another.
            copyWith = packages: (mkImage imageName "bash" packages).copyTo;
            # Like `copyWith`, but for the given image `name` and shell — `c init`
            # passes `nix-container-<dir>` and the host login shell, which is added
            # to the image and used as cmd + $SHELL without being listed in
            # `container.nix`.
            copyWithShell = name: shell: packages: (mkImage name shell packages).copyTo;
          };
        }
      );
}

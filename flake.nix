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

          # Fish prompt config, installed at /root/.config/fish/config.fish
          # (fish reads $HOME/.config/fish).
          fishConfig = pkgsLinux.writeText "config.fish" ''
            # No welcome banner.
            set -g fish_greeting

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

          # Lay the config out at the path fish reads.
          fishRoot = pkgsLinux.runCommand "fish-config-root" { } ''
            mkdir -p "$out/root/.config/fish"
            cp ${fishConfig} "$out/root/.config/fish/config.fish"
          '';

          # Build the OCI image from a `{ pkgs, nur }: [ ... ]` package function.
          # The fish prompt config is always added; the default `cmd` is
          # /bin/fish, so the package set should include `fish` (warned about
          # below if missing) or override `config.cmd`.
          mkImage =
            packages:
            let
              pkgList = packages {
                pkgs = pkgsLinux;
                nur = nurPkgs;
              };
            in
            pkgsLinux.lib.warnIf (!builtins.any (p: (p.pname or "") == "fish") pkgList)
              "nix-container: config.cmd is /bin/fish but the package set has no `fish` — the container will fail to start unless something provides /bin/fish (or change config.cmd)."
              (
                n2c.buildImage {
                  name = imageName;
                  tag = imageTag;
                  inherit arch;

                  # A plain, single-process root filesystem. No NixOS, no systemd.
                  copyToRoot = pkgsLinux.buildEnv {
                    name = "root";
                    paths = pkgList ++ [ fishRoot ];
                    pathsToLink = [
                      "/bin"
                      "/root"
                    ];
                  };

                  initializeNixDatabase = true;

                  config = {
                    # `cmd` (not `entrypoint`): it's the default command and is
                    # *replaced* by `container run … -- <cmd>`. An entrypoint would
                    # be prepended instead, so `run … -- /bin/sh` would become
                    # `/bin/bash /bin/sh` and fail with "cannot execute binary file".
                    cmd = [ "/bin/fish" ];
                    env = [
                      "PATH=/bin"
                      # fish reads its prompt from $HOME/.config/fish/config.fish.
                      "HOME=/root"
                    ];
                  };
                }
              );

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

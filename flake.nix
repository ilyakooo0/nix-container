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

          # skopeo writes the OCI archive's ref.name from the *destination*
          # string, not from the image config — so the wrapper app must spell
          # these out, else the archive loads as `untagged`.
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

          image = n2c.buildImage {
            name = imageName;
            tag = imageTag;
            inherit arch;

            # A plain, single-process root filesystem. No NixOS, no systemd.
            copyToRoot = pkgsLinux.buildEnv {
              name = "root";
              paths = with pkgsLinux; [
                bashInteractive
                fish
                fishRoot
                openssh
                coreutils-full
                btop
                jujutsu
                zellij
                micro
                helix
                nurPkgs.repos.charmbracelet.crush

                # LLM tools
                git
                ripgrep
                fd
                jq
                curl
                wget
                gnused
                gnugrep
                gawk
                findutils
                gnutar
                gzip
                unzip
                less
                which
                tree
                nodejs
                python3

                # rust
                rustc
                cargo
                rustfmt
                clippy

                # C toolchain — rustc links final binaries through `cc`/`ld`.
                gcc # provides cc/gcc; pulls in binutils (ld) via its closure
              ];
              pathsToLink = [
                "/bin"
                "/root"
              ];
            };

            initializeNixDatabase = true;

            config = {
              # `cmd` (not `entrypoint`): it's the default command and is
              # *replaced* by `container run … -- <cmd>`. An entrypoint would be
              # prepended instead, so `run … -- /bin/sh` would become
              # `/bin/bash /bin/sh` and fail with "cannot execute binary file".
              cmd = [ "/bin/fish" ];
              env = [
                "PATH=/bin"
                # fish reads its prompt from $HOME/.config/fish/config.fish.
                "HOME=/root"
              ];
            };
          };

          # `nix run . -- <path>` writes an OCI archive tagged
          # <imageName>:<imageTag>. The raw `image.copyTo` is a passthrough
          # (`skopeo copy nix:<image> "$@"`), so an `oci-archive:<path>` with no
          # ref loads as `untagged`; this bakes the ref into the destination.
          copyToOCI = pkgsHost.writeShellApplication {
            name = "copy-to-oci";
            text = ''
              out="''${1:-image.tar}"
              exec ${image.copyTo}/bin/copy-to "oci-archive:$out:${imageName}:${imageTag}"
            '';
          };
        in
        {
          apps = {
            # nix run . -- <path>   → OCI archive tagged <name>:<tag>,
            # loadable with `container image load -i <path>`.
            default = flake-utils.lib.mkApp { drv = copyToOCI; };

            # Generic skopeo passthrough for any other destination, e.g.
            #   nix run .#copyTo -- docker://ghcr.io/me/img:latest
            copyTo = flake-utils.lib.mkApp { drv = image.copyTo; };
          };
        }
      );
}

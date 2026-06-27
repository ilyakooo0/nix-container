# nix-container

A Nix flake that builds an **OCI image** (via
[`nix2container`](https://github.com/nlewo/nix2container)) for running with
Apple's [`container`](https://github.com/apple/container) CLI on macOS.

It's a plain, single-process image — no NixOS, no systemd — defined in
[`flake.nix`](./flake.nix). `init` runs your host login shell (`$SHELL`); you
choose what else it ships via a per-project `container.nix`.

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled.
- Apple's [`container`](https://github.com/apple/container) CLI installed, with
  services started: `container system start` (first run downloads a Linux
  kernel).
- A **Linux builder** — the image *contents* are Linux binaries, which can't be
  built on macOS. Use a [remote builder][builders] or, on Apple Silicon, the
  `nix-darwin` `linux-builder`. With one configured, `nix` dispatches Linux
  builds to it automatically (most packages also come prebuilt from the binary
  cache, so the builder is only needed for the uncached bits).

[builders]: https://nix.dev/manual/nix/latest/advanced-topics/distributed-builds

## Packages

`init` builds the image from a **`container.nix`** in the current directory — a
`{ pkgs, nur }` function returning the package list (`nur` is
[NUR](https://github.com/nix-community/NUR), for packages outside nixpkgs). It
is **required**; there is no default set.

```nix
# ./container.nix
{ pkgs, nur }: with pkgs; [
  coreutils
  git
  go
  nur.repos.charmbracelet.crush
]
```

Your host shell (`$SHELL`) is added and run automatically — no need to list it.

Point at a different file with `-c`/`--config`:

```sh
nix run github:ilyakooo0/nix-container -- init --config envs/ci.nix
```

## Quick start

No clone needed — `nix run` drives everything. Run it from a project directory
that holds a `container.nix`; the container is named after that directory.

```sh
# build the image, load it, and create the container (named after $PWD):
nix run github:ilyakooo0/nix-container -- init

# start it and attach — drops you into your shell:
nix run github:ilyakooo0/nix-container -- start
```

- `init` builds the OCI archive in a temp dir, loads it into `container`,
  deletes the temp file, then (re)creates the container. It mounts the current
  directory at `/workspace` (the container's working directory) and your
  `~/.config` at `/root/.config`.
- `--ssh` forwards your host SSH agent socket into the container (so `git` over
  SSH works with your keys).
- Add more mounts by passing them through (mounts can only be set at creation):

  ```sh
  nix run github:ilyakooo0/nix-container -- init -v $HOME/data:/data
  ```

Working from a checkout, [`./c init`](./c) / `./c start` are equivalent — and
`c` can be symlinked onto your `$PATH` and run from any project.

## Re-running after a rebuild

Just run `init` again — it reloads the image and replaces the existing container
(removing the old one first), so there's nothing to clean up:

```sh
nix run github:ilyakooo0/nix-container -- init
```

## Customize further

Fork or clone to change what isn't per-project — `config.cmd`/`env` or the image
name — in [`flake.nix`](./flake.nix). The flake also exposes build helpers, both
taking a `{ pkgs, nur }: [ ... ]` function:

- `lib.<system>.mkImage` → an OCI image.
- `lib.<system>.copyWith` → a skopeo copy app, for building/pushing the image
  anywhere skopeo can write (e.g. a registry):

  ```sh
  drv=$(nix build --no-link --print-out-paths --impure --expr \
    '(builtins.getFlake "github:ilyakooo0/nix-container").lib.${builtins.currentSystem}.copyWith (import ./container.nix)')
  $drv/bin/copy-to docker://ghcr.io/me/img:latest
  ```

The flake uses `flake-utils` over `{aarch64,x86_64}-{darwin,linux}`; the host
system maps to the matching Linux target automatically (an Intel Mac builds an
`amd64` image), so there's nothing to change per-arch.

## How it works

- **Contents** are built from `pkgsLinux` → the Linux builder.
- **Assembly** (`nix2container` + the `skopeo` copy) runs on your Mac, so a
  single `init` produces a loadable archive.
- Apple's `container` runs each container in its own lightweight Linux VM and
  consumes standard OCI images — no `--privileged` or systemd needed.

## License

[MIT](./LICENSE).

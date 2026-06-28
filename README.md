# nix-container

A Nix flake that builds an **OCI image** (via
[`nix2container`](https://github.com/nlewo/nix2container)) for running with
Apple's [`container`](https://github.com/apple/container) CLI on macOS.

It's a plain, single-process image — no NixOS, no systemd — defined in
[`flake.nix`](./flake.nix). `c init` detects your host login shell, bundles it,
and runs it by default; `c start` drops you into a [`zellij`](https://zellij.dev)
session. You choose what else it ships via a per-project `container.nix`.

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled.
- Apple's [`container`](https://github.com/apple/container) CLI installed, with
  services started: `container system start` (first run downloads a Linux
  kernel).
- A **Linux builder** *only if you use packages that aren't in the binary
  cache*. The image is assembled entirely on macOS — the root filesystem is just
  a host-built symlink tree over the **substituted** Linux store paths — so a
  fully-cached package set needs no builder. Compiling a Linux package that
  `cache.nixos.org` doesn't have does, though: use a [remote builder][builders]
  or, on Apple Silicon, the `nix-darwin` `linux-builder`.

[builders]: https://nix.dev/manual/nix/latest/advanced-topics/distributed-builds

## Packages

`init` builds the image from a **`container.nix`** in the current directory — a
`{ pkgs, nur }` function returning the package list (`nur` is
[NUR](https://github.com/nix-community/NUR), for packages outside nixpkgs). It
is **required**; there is no default set.

```nix
# ./container.nix
{ pkgs, nur }: with pkgs; [
  git
  go
  nur.repos.charmbracelet.crush
]
```

Your **host login shell** (detected by `c init`, bash fallback), **coreutils**,
[**zellij**](https://zellij.dev) (the session `c start` launches), **Nix** itself
(with CA certs and `nix-command`/`flakes` enabled, single-user), and the ncurses
**terminfo** database are always included — no need to list them.

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

# start it and attach — drops you into a zellij session:
nix run github:ilyakooo0/nix-container -- start
```

- `init` builds the OCI archive in a temp dir, loads it into `container`,
  deletes the temp file, then (re)creates the container. It mounts the current
  directory at `/workspace` (the container's working directory).
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
name — in [`flake.nix`](./flake.nix). The flake also exposes build helpers:

- `lib.<system>.copyWith` → a skopeo copy app for a `{ pkgs, nur }: [ ... ]`
  function, for building/pushing the image anywhere skopeo can write (e.g. a
  registry):

  ```sh
  drv=$(nix build --no-link --print-out-paths --impure --expr \
    '(builtins.getFlake "github:ilyakooo0/nix-container").lib.${builtins.currentSystem}.copyWith (import ./container.nix)')
  $drv/bin/copy-to docker://ghcr.io/me/img:latest
  ```
- `lib.<system>.mkImage <name> <shell>` → the underlying OCI image (`copyWith`
  defaults these to `nix-container` / `bash`).

The flake uses `flake-utils` over `{aarch64,x86_64}-{darwin,linux}`; the host
system maps to the matching Linux target automatically (an Intel Mac builds an
`amd64` image), so there's nothing to change per-arch.

## How it works

- **Contents** are Linux store paths — downloaded prebuilt from the binary cache
  (only built on a Linux builder if not cached).
- **Assembly** runs entirely on your Mac: `copyToRoot` is a *host-arch* `buildEnv`
  symlink tree over those Linux paths (symlinks are arch-neutral), and
  `nix2container` + `skopeo` package it — so for a cached set, `init` produces a
  loadable Linux image with no Linux build at all.
- Apple's `container` runs each container in its own lightweight Linux VM and
  consumes standard OCI images — no `--privileged` or systemd needed.

## License

[MIT](./LICENSE).

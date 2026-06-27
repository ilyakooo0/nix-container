# nix-container

A Nix flake that builds an **OCI image** (via
[`nix2container`](https://github.com/nlewo/nix2container)) for running with
Apple's [`container`](https://github.com/apple/container) CLI on macOS.

It's a plain, single-process image — no NixOS, no systemd — defined in
[`flake.nix`](./flake.nix). The default command is `fish` (with a configured
prompt), and the image ships a handful of dev/LLM tools: `git`, `jujutsu`,
`ripgrep`, `fd`, `jq`, `nodejs`, `python3`, a Rust + C toolchain,
`charmbracelet.crush`, `openssh`, and more.

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

## Quick start

No clone needed — `nix run` drives everything. Run it from a project directory;
the container is named after that directory.

```sh
# build the image, load it, and create the container (named after $PWD):
nix run github:ilyakooo0/nix-container -- init

# start it and attach — drops you into fish:
nix run github:ilyakooo0/nix-container -- start
```

- `init` builds the OCI archive in a temp dir, loads it into `container`,
  deletes the temp file, then runs `container create --name <dir> --ssh -it`.
- `--ssh` forwards your host SSH agent socket into the container (so `git` over
  SSH works with your keys).
- Mounts can only be set at creation, so pass them to `init` (forwarded to
  `container create`):

  ```sh
  nix run github:ilyakooo0/nix-container -- init -v $PWD:/work
  ```

Working from a checkout, [`./c init`](./c) / `./c start` are equivalent — and
`c` can be symlinked onto your `$PATH` and run from any project.

## Re-running after a rebuild

`container` keeps the loaded image and the created container, so remove them
before re-initialising:

```sh
container rm <dir>                       # the container is named after the directory
container image rm nix-container:latest
nix run github:ilyakooo0/nix-container -- init
```

## Manual steps

`init` is just a wrapper; you can run the pieces yourself for more control. The
`image` app is nix2container's skopeo wrapper (`skopeo copy nix:<image> "$@"`) —
it takes the ref name from the destination, so spell out the tag:

```sh
# 1. build a tagged OCI archive
nix run github:ilyakooo0/nix-container#image -- oci-archive:image.tar:nix-container:latest

# 2. load, create, start
container image load --input image.tar
container create --name myctr --ssh -it nix-container:latest
container start -ai myctr
```

## Other image destinations

The same `image` app can copy anywhere skopeo can:

```sh
nix run github:ilyakooo0/nix-container#image -- docker://ghcr.io/me/img:latest   # push to a registry
nix run github:ilyakooo0/nix-container#image -- docker-daemon:nix-container:latest # local Docker daemon
```

## Configuring packages

The image ships a curated tool set (`defaultPackages` in
[`flake.nix`](./flake.nix)). To use your own set **without forking**, drop a
`nix-container.nix` in the directory you run `init` from — a `pkgs`-function
returning the package list:

```nix
# ./nix-container.nix
pkgs: with pkgs; [
  fish       # the default cmd is /bin/fish, so include it (or change config.cmd)
  coreutils
  go
  terraform
]
```

`nix run github:ilyakooo0/nix-container -- init` (and `./c init`) then builds an
image with **exactly** those packages, replacing the default set. It's a full
replacement, so include the basics you need.

## Customize further

Fork or clone to change what isn't per-project — the default package set,
`config.cmd`/`env`, or the image name — by editing `defaultPackages` / `mkImage`
in [`flake.nix`](./flake.nix). `mkImage` and `lib.<system>.copyWith` are exposed
for building images from your own flake.

The flake uses `flake-utils` over `{aarch64,x86_64}-{darwin,linux}`; the host
system maps to the matching Linux target automatically (an Intel Mac builds an
`amd64` image), so there's nothing to change per-arch.

## How it works

- **Contents** (`copyToRoot`) are built from `pkgsLinux` → the Linux builder.
- **Assembly** (`nix2container` + the `skopeo` copy) runs on your Mac, so a
  single `nix run` produces a loadable archive.
- Apple's `container` runs each container in its own lightweight Linux VM and
  consumes standard OCI images — no `--privileged` or systemd needed.

## License

[MIT](./LICENSE).

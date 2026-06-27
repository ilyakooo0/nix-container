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

## Steps

### 1. Build the image archive

`nix run` builds the Linux contents (on your Linux builder) and writes a tagged
OCI archive locally via `skopeo`. Pass the output path; the image is tagged
`nix-container:latest`.

```sh
nix run . -- image.tar.gz
```

### 2. Load it into `container`

```sh
container image load --input image.tar.gz
```

### 3. Create and start the container

```sh
container create --name nixos --ssh -it nix-container:latest
container start -ai nixos
```

- `--ssh` forwards your host SSH agent socket into the container (so `git` over
  SSH etc. works with your keys).
- `-it` / `-ai` give an interactive TTY; `start -ai` attaches to it.

You land in `fish`. Exit the shell to stop the container.

> **Shortcut:** the [`c`](./c) script bundles the workflow and names the
> container after the current directory (handy for per-project containers). It
> resolves the flake from its own location, so you can symlink it onto your
> `$PATH` and run it from any project:
>
> ```sh
> ./c init                 # build + load the image, then create the container
> ./c init -v $PWD:/work    # add create-time mounts (set only at creation)
> ./c start                # start and attach
> ```
>
> `c init` builds the archive in a temp dir, loads it, and deletes it — so no
> `image.tar.gz` is left lying around.

## Re-running after a rebuild

`container` keeps the loaded image and the created container, so to pick up a
new build, remove the old ones first:

```sh
nix run . -- image.tar.gz            # rebuild the archive
container rm nixos                   # remove the old container (stop it first if running)
container image rm nix-container:latest
container image load --input image.tar.gz
container create --name nixos --ssh -it nix-container:latest
container start -ai nixos
```

## Other image destinations

`nix run .#copyTo` is nix2container's generic skopeo wrapper
(`skopeo copy nix:<image> "$@"`) — the argument is any skopeo destination:

```sh
nix run .#copyTo -- docker://ghcr.io/me/nixos:latest    # push to a registry
nix run .#copyTo -- docker-daemon:nix-container:latest # local Docker daemon
```

## Customize

Edit the `buildImage` call in [`flake.nix`](./flake.nix):

- Add packages to `copyToRoot.paths`.
- Change the default process via `config.cmd`.
- Add env vars via `config.env`.

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

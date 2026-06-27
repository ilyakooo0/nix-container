# container-nix

A Nix flake that builds an **OCI image** (via
[`nix2container`](https://github.com/nlewo/nix2container)) for running with
Apple's [`container`](https://github.com/apple/container) CLI on macOS.

It's a plain, single-process image — no NixOS, no systemd — defined in
[`flake.nix`](./flake.nix). `nix2container` produces a real OCI image directly,
so there's no `dockerTools` docker-archive → OCI conversion step.

- Image contents: **aarch64-linux** (built on your remote Linux builder).
- The image is assembled/copied from your **Mac** (aarch64-darwin), so a single
  `nix run` does the whole thing.

## Build & load into Apple `container`

```sh
# Write the image to an OCI archive (runs skopeo locally; builds the
# aarch64-linux contents on your remote builder automatically):
nix run . -- oci-archive:nixos.tar:nixos-container:latest

# Make sure the container services are running (one-time kernel download
# on first use), then load and run:
container system start
container image load -i nixos.tar
container run -it nixos-container:latest                 # default cmd: /bin/bash
container run --rm nixos-container:latest /bin/sh -c 'uname -m'   # a one-off command
```

Note: Apple's `container run` takes the command **directly after the image** —
there is no `--` separator (a `--` is parsed as the executable name). The image
sets `config.cmd` (not `entrypoint`), so the command you pass *replaces* the
default `/bin/bash` instead of being appended to it.

The default app is nix2container's generic skopeo wrapper
(`skopeo copy nix:<image> "$@"`), so the argument is any skopeo destination —
here `oci-archive:<path>:<name>:<tag>`.

### Other destinations

```sh
nix run . -- docker://ghcr.io/me/nixos:latest   # push to a registry
nix run .#image.copyToDockerDaemon              # local Docker
nix run .#image.copyToPodman                    # local Podman
nix run .#image.copyToRegistry                  # registry (uses image name/tag)
```

## Customize

Edit the `buildImage` call in [`flake.nix`](./flake.nix):

- Add packages to `copyToRoot.paths`.
- Set the process via `config.entrypoint` / `config.cmd`.
- Add env vars via `config.env`.

The flake is structured with `flake-utils` over `{aarch64,x86_64}-{darwin,linux}`;
the host system maps to the matching Linux target automatically (e.g. an Intel
Mac builds an `amd64` image), so there's nothing to change per-arch.

## Notes

- Building Linux container contents on macOS requires a Linux builder. Yours is
  already configured (`internal.iko.soy`, aarch64-linux), so `nix run` picks it
  up automatically.
- Apple's `container` runs each container in its own lightweight Linux VM and
  consumes standard OCI images — no `--privileged` or systemd needed.

# vivado-distrobox

Run AMD Vivado and Vitis on any Linux distribution with [distrobox](https://distrobox.it).

- One distrobox container per Vivado/Vitis version (several versions can live side by side).
- Strongly advised to install Vivado **outside** the container, in a directory you choose.
  Container should hold only the libraries Vivado needs, so they can be recreated at any time without reinstalling anything.
- `vivado` / `vitis` commands and app-menu entries on your host, as if the tools were installed natively.

Tested with Vivado/Vitis 2025.2 on `ubuntu:24.04`, distrobox 1.8.2.5 and podman, on a KDE Plasma (Wayland) host.

## Requirements

- distrobox, and podman or docker
- `~/.local/bin` on your `PATH` (that's where the `vivado` / `vitis` commands go)
- Disk space for the install: roughly 60–100 GB per version, depending on the devices you select
- AMD's installer for the version you want (download it from AMD; an AMD account is required)

## Quick start

1. Configure `config.env`:

    ```shell
    cp config.env.example config.env
    ```

    and edit it.

2. Create the container:

    ```shell
    ./setup.sh
    ```

3. Install Vivado/Vitis **from inside the container**, e.g.:

    ```shell
    distrobox enter xilinx-2025.2
    cd ~/Downloads/<extracted installer folder>   # home directory is shared with the container
    ./xsetup
    ```

    - **Don't use `sudo`**; install into a directory you own.
    - Remember to set the install directory `XILINX_DIR`.
    - Untick the options that create desktop shortcuts and program group entries.
      Those would start the tools directly on the host, outside the container, where they may be missing libraries.

    Leave the container with `exit` when the installer is done.

4. Run `./setup.sh` again. It finds the install and adds the commands and menu entries.

5. Start Vivado:

    ```shell
    vivado
    ```

### Why not install inside the container?

Everything inside a container is removed when the container is recreated, and `./setup.sh` recreates boxes every time it runs, so it would remove Vivado.

## Usage

On the host:

| Command                         | Starts            |
| ------------------------------- | ----------------- |
| `vivado-2025.2`, `vitis-2025.2` | that version      |
| `vivado`, `vitis`               | `DEFAULT_VERSION` |

Arguments are passed through (`vivado project.xpr`, `vivado -mode tcl` commands work), and the tools run in the current working directory, so `vivado.log` and `vivado.jou` land there.

Commands and menu entries are only added for what installed tools - if installed Vivado without Vitis, there is no `vitis` command.
The app menu gets "Vivado 2025.2" and "Vitis 2025.2" entries (distrobox adds "on xilinx-2025.2" to the name).
They start in `~/.cache/xilinx/2025.2/`, so their log files don't pile up in home directory.
Distrobox also adds an entry that opens a terminal inside the container.

Inside a container (`distrobox enter xilinx-2025.2`):

- `vivado`, `vitis`, `vivado-2025.2`, `vitis-2025.2` work as on the host.
- `xilinx-run <tool> [args]` runs any other tool of the install: `xilinx-run xsim --version`,
  `xilinx-run v++ ...`, `xilinx-run vitis-run ...`.
- `xilinx-run` alone opens the shell with the full Xilinx environment (`settings64.sh` sourced).
- In a container that isn't the default version, prefer `vivado-<version>` or `xilinx-run vivado`:
  plain `vivado` can resolve to the host command in `~/.local/bin` (if that comes first in your `PATH`) and start the default version instead.

## Several Vivado versions

List them in `config.env`:

```sh
VERSIONS="2025.2 2024.2"
DEFAULT_VERSION="2025.2"
XILINX_DIR_2024_2="/data/Xilinx"   # optional: a different directory for one version
```

For each new version follow the [quick start](#quick-start).

## Adding a new Vivado version

Each version needs `versions/<version>.ini`, a fragment of a [distrobox assemble](https://distrobox.it/usage/distrobox-assemble/) file with what's specific to that release, e.g.:

```ini
# Vivado / Vitis 2024.2
image=ubuntu:22.04
additional_packages="libtinfo5 libncurses5 ..."
```

- Pick a Linux distribution and version that AMD supports for that release (see AMD's release notes).
- To find missing libraries, enter the container and run `ldd` on the tool's binaries, looking for `not found`.

## Removing a version

```sh
./setup.sh --remove 2025.2
```

This removes the container, its commands and its menu entries.

## Seeing what setup does

```sh
./setup.sh --dry-run
```

writes the generated distrobox files to `build/` without creating anything.

## Troubleshooting

**"manpath: can't set the locale"** or similar warnings in the container:
the container generates the locales your session uses at the time `./setup.sh` runs.
If you changed your locale settings since, run `./setup.sh` again.

**Vivado's window stays empty or grey:**
Java needs `_JAVA_AWT_WM_NONREPARENTING=1` on Wayland and on some tiling window managers.
The launcher sets it automatically on Wayland.
On an X11 tiling window manager (i3, dwm, ...), add `export _JAVA_AWT_WM_NONREPARENTING=1` to your shell configuration; distrobox passes it into the container.

**My shell prompt looks plain inside the container:**
the container shares your home directory, and with it your dotfiles, but it has its own `/usr`.
If your shell configuration loads files installed under `/usr` (zsh configuration and its powerlevel10k prompt are an example), those files don't exist in the container and your shell falls back to its defaults.
The tools are not affected and should work.

## License

MIT, see [LICENSE](LICENSE). AMD Vivado and Vitis are not part of this repository; they are subject to
AMD's own license terms.

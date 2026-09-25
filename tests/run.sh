#!/usr/bin/env bash
# Tests for container/xilinx-run and setup.sh --dry-run. Needs no distrobox. Run: tests/run.sh
# Fake installs and configs are written with a literal $ on purpose:
# shellcheck disable=SC2016
set -uo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(realpath "$(mktemp -d)")
trap 'rm -rf -- "$tmp"' EXIT
failures=0

# expect <name> <wanted exit code> <text wanted in output> -- <command...>
expect() {
    local name=$1 want_rc=$2 want_text=$3 out rc
    shift 4
    out=$("$@" 2>&1)
    rc=$?
    if [[ $rc == "$want_rc" && $out == *"$want_text"* ]]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n     exit %s (wanted %s), wanted text: %s\n     output:\n%s\n' \
            "$name" "$rc" "$want_rc" "$want_text" "$out"
        failures=$((failures + 1))
    fi
}

# expect_absent <name> <text that must not appear> <file (must exist)>
expect_absent() {
    if [[ ! -f $3 ]]; then
        printf 'FAIL %s\n     %s does not exist\n' "$1" "$3"
        failures=$((failures + 1))
    elif grep -qF -- "$2" "$3"; then
        printf 'FAIL %s\n     found "%s" in %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    else
        printf 'ok   %s\n' "$1"
    fi
}

# fake_install <root> <dir holding settings64.sh, relative to root> <tools...>
# settings64.sh puts a bin/ on PATH whose tools print their name, args, cwd and Java variable.
fake_install() {
    local dir="$1/$2" tool
    mkdir -p "$dir/bin"
    printf 'export PATH="%s/bin:$PATH"\n' "$dir" >"$dir/settings64.sh"
    for tool in "${@:3}"; do
        printf '#!/bin/sh\necho "ran %s args=[$*] cwd=$(pwd) java=${_JAVA_AWT_WM_NONREPARENTING:-unset}"\n' \
            "$tool" >"$dir/bin/$tool"
        chmod +x "$dir/bin/$tool"
    done
}

# --- container/xilinx-run --------------------------------------------------------

links=$tmp/links
mkdir -p "$links"
for name in xilinx-run vivado vitis vivado-2025.2 vitis-2025.2; do
    ln -s "$repo/container/xilinx-run" "$links/$name"
done

# in_box <XILINX_DIR> <command...>: run like inside a container made by setup.sh (10 s limit catches self-restart loops)
in_box() {
    local dir=$1
    shift
    timeout 10 env -u _JAVA_AWT_WM_NONREPARENTING -u WAYLAND_DISPLAY -u XILINX_RUN_DIR \
        XILINX_DIR="$dir" XILINX_VERSION=2025.2 PATH="$links:/usr/bin:/bin" "$@"
}

new=$tmp/new
fake_install "$new" 2025.2/Vivado vivado vitis xsim
old=$tmp/old
fake_install "$old" Vitis/2025.2 vivado vitis
vivado_only=$tmp/vivado-only
fake_install "$vivado_only" 2025.2/Vivado vivado

expect "versioned name starts the tool with args" 0 "ran vivado args=[-mode tcl]" -- in_box "$new" "$links/vivado-2025.2" -mode tcl
expect "plain name starts the tool" 0 "ran vitis args=[]" -- in_box "$new" "$links/vitis"
expect "older install layout is found" 0 "ran vitis args=[]" -- in_box "$old" "$links/vitis"
expect "xilinx-run <tool> runs any tool" 0 "ran xsim args=[--version]" -- in_box "$new" "$links/xilinx-run" xsim --version
shell_mode() { echo 'command -v xsim' | in_box "$new" env SHELL=/bin/sh "$links/xilinx-run"; }
expect "xilinx-run alone opens SHELL with the tools on PATH" 0 "$new/2025.2/Vivado/bin/xsim" -- shell_mode
expect "missing install gives a clear error" 1 "Vivado/Vitis 2025.2 not found in $tmp/nothing" -- in_box "$tmp/nothing" "$links/vivado"
expect "tool missing from install: error, no self-restart" 1 "vitis not found in the 2025.2 install" -- in_box "$vivado_only" "$links/vitis"
expect "outside a container: clear error" 1 "XILINX_DIR and XILINX_VERSION are not set" -- env -u XILINX_DIR -u XILINX_VERSION "$links/vivado"
expect "Wayland sets the Java fix" 0 "java=1" -- in_box "$new" env WAYLAND_DISPLAY=wayland-0 "$links/vivado"
expect "X11 leaves the Java variable unset" 0 "java=unset" -- in_box "$new" "$links/vivado"
expect "user's own Java value is kept" 0 "java=0" -- in_box "$new" env WAYLAND_DISPLAY=wayland-0 _JAVA_AWT_WM_NONREPARENTING=0 "$links/vivado"
expect "XILINX_RUN_DIR is created and used" 0 "cwd=$tmp/runs/2025.2" -- in_box "$new" env XILINX_RUN_DIR="$tmp/runs/2025.2" "$links/vivado"

# --- setup.sh --dry-run ----------------------------------------------------

home=$tmp/home
mkdir -p "$home"
vers=$tmp/versions
mkdir -p "$vers"
printf 'image=ubuntu:24.04\n' >"$vers/2025.2.ini"
printf 'image=ubuntu:22.04\n' >"$vers/2024.2.ini"
n=0

# cfg <config.env text>: next dry run uses this config and a fresh build dir ($build)
cfg() {
    n=$((n + 1))
    build=$tmp/build$n
    printf '%s\n' "$1" >"$tmp/config$n.env"
}

# dry [VAR=value...]: setup.sh --dry-run with only the given environment
dry() {
    env -i HOME="$home" PATH="$PATH" CONFIG_FILE="$tmp/config$n.env" BUILD_DIR="$build" \
        VERSIONS_DIR="$vers" "$@" "$repo/setup.sh" --dry-run
}

# hook_file <path in container> <ini>: decode the file an init hook writes into the container
hook_file() {
    sed -n "s#^init_hooks=\"echo \([A-Za-z0-9+/=]*\) [|] base64 -d > $1;\"\$#\1#p" "$2" | base64 -d
}

cfg 'XILINX_DIR="$HOME/Xilinx"
VERSIONS="2025.2"
DEFAULT_VERSION="2025.2"'
expect "missing dir under HOME: would create" 0 "Would create $home/Xilinx" -- dry
expect "no install yet: next steps shown" 0 "distrobox enter xilinx-2025.2" -- dry
expect "non-UTF-8 locale is warned about" 0 "LC_MONETARY=fr_FR.ISO-8859-1 is not a UTF-8 locale" -- \
    dry LANG=pl_PL.UTF-8 LC_TIME=de_DE.utf8 LC_NUMERIC=C LC_MONETARY=fr_FR.ISO-8859-1
ini=$build/xilinx-2025.2.ini
expect "one section per version" 0 "[xilinx-2025.2]" -- cat "$ini"
expect "version file included" 0 "image=ubuntu:24.04" -- cat "$ini"
expect "host locales generated" 0 'init_hooks="locale-gen en_US.UTF-8 pl_PL.UTF-8 de_DE.UTF-8;"' -- cat "$ini"
expect "install dir passed to container" 0 "additional_flags=\"--env XILINX_DIR=$home/Xilinx\"" -- cat "$ini"
expect "version passed to container" 0 'additional_flags="--env XILINX_VERSION=2025.2"' -- cat "$ini"
expect_absent "no mount for a dir under HOME" "volume=" "$ini"
expect_absent "no exports before install" "exported_" "$ini"
hook_file /usr/local/bin/xilinx-run "$ini" >"$tmp/embedded"
expect "launcher embedded unchanged" 0 "" -- cmp "$repo/container/xilinx-run" "$tmp/embedded"
expect "launcher links created" 0 'init_hooks="ln -sf xilinx-run /usr/local/bin/vivado-2025.2;"' -- cat "$ini"
dry LANG=C >/dev/null 2>&1
expect "LANG=C: only en_US" 0 'init_hooks="locale-gen en_US.UTF-8;"' -- cat "$ini"

fake_install "$home/Xilinx" 2025.2/Vivado vivado
fake_install "$home/Xilinx" 2025.2/Vitis vitis
mkdir -p "$home/Xilinx/2025.2/Vivado/doc/images"
touch "$home/Xilinx/2025.2/Vivado/doc/images/vivado_logo.png"
mkdir -p "$tmp/outside/Xilinx"
fake_install "$tmp/outside/Xilinx" Vivado/2024.2 vivado
cfg 'XILINX_DIR="$HOME/Xilinx"
VERSIONS="2025.2 2024.2"
DEFAULT_VERSION="2025.2"
XILINX_DIR_2024_2="'"$tmp"'/outside/Xilinx"'
expect "two versions rendered" 0 "Wrote $build/xilinx-2024.2.ini" -- dry
ini=$build/xilinx-2025.2.ini
old_ini=$build/xilinx-2024.2.ini
expect "versioned vivado command exported" 0 'exported_bins="/usr/local/bin/vivado-2025.2"' -- cat "$ini"
expect "versioned vitis command exported" 0 'exported_bins="/usr/local/bin/vitis-2025.2"' -- cat "$ini"
expect "default version exports plain vivado" 0 'exported_bins="/usr/local/bin/vivado"' -- cat "$ini"
expect "default version exports plain vitis" 0 'exported_bins="/usr/local/bin/vitis"' -- cat "$ini"
expect_absent "other versions don't export plain commands" 'exported_bins="/usr/local/bin/vivado"' "$old_ini"
expect "vivado menu entry exported" 0 'exported_apps="/usr/local/share/applications/xilinx-vivado-2025.2.desktop"' -- cat "$ini"
expect "vitis menu entry exported" 0 'exported_apps="/usr/local/share/applications/xilinx-vitis-2025.2.desktop"' -- cat "$ini"
expect "Vivado-only install: vivado exported" 0 'exported_bins="/usr/local/bin/vivado-2024.2"' -- cat "$old_ini"
expect_absent "Vivado-only install: no vitis command" 'exported_bins="/usr/local/bin/vitis-2024.2"' "$old_ini"
expect_absent "Vivado-only install: no vitis menu entry" "xilinx-vitis-2024.2.desktop" "$old_ini"
hook_file /usr/local/share/applications/xilinx-vivado-2025.2.desktop "$ini" >"$tmp/vivado.desktop"
expect "menu entry uses a per-version icon name" 0 "Icon=xilinx-vivado-2025.2" -- cat "$tmp/vivado.desktop"
expect "install's icon copied into the container, never failing the container start" 0 \
    "init_hooks=\"cp -f $home/Xilinx/2025.2/Vivado/doc/images/vivado_logo.png /usr/share/pixmaps/xilinx-vivado-2025.2.png || true;\"" -- cat "$ini"
expect_absent "no icon copy when the install has no icon" "/usr/share/pixmaps/xilinx-vitis-2025.2" "$ini"
expect "menu entry starts in the cache dir" 0 "Exec=env XILINX_RUN_DIR=$home/.cache/xilinx/2025.2 /usr/local/bin/vivado-2025.2" -- cat "$tmp/vivado.desktop"
hook_file /usr/local/share/applications/xilinx-vitis-2025.2.desktop "$ini" >"$tmp/vitis.desktop"
expect "missing icon falls back to a generic one" 0 "Icon=applications-engineering" -- cat "$tmp/vitis.desktop"
expect "per-version dir override" 0 "--env XILINX_DIR=$tmp/outside/Xilinx" -- cat "$old_ini"
expect "dir outside HOME is mounted" 0 "volume=\"$tmp/outside/Xilinx:$tmp/outside/Xilinx\"" -- cat "$old_ini"

mkdir -p "$tmp/home2/Xilinx"
cfg 'XILINX_DIR="'"$tmp"'/home2/Xilinx"
VERSIONS="2025.2"
DEFAULT_VERSION="2025.2"'
dry >/dev/null 2>&1
expect "dir sharing HOME's prefix is mounted" 0 "volume=\"$tmp/home2/Xilinx:$tmp/home2/Xilinx\"" -- cat "$build/xilinx-2025.2.ini"

cfg 'XILINX_DIR="'"$tmp"'/missing/Xilinx"
VERSIONS="2025.2"
DEFAULT_VERSION="2025.2"'
expect "missing dir outside HOME: error with the fix" 1 "sudo mkdir -p" -- dry
cfg 'XILINX_DIR="$HOME/My Xilinx"
VERSIONS="2025.2"
DEFAULT_VERSION="2025.2"'
expect "path with spaces is refused" 1 "paths with spaces are not supported" -- dry
cfg 'XILINX_DIR="$HOME/Xilinx"
VERSIONS="2025.2"
DEFAULT_VERSION="2024.2"'
expect "default must be in VERSIONS" 1 "DEFAULT_VERSION 2024.2 is not listed in VERSIONS" -- dry
cfg 'XILINX_DIR="$HOME/Xilinx"
VERSIONS="2099.1"
DEFAULT_VERSION="2099.1"'
expect "version without a versions/ file" 1 "no $vers/2099.1.ini" -- dry
cfg 'XILINX_DIR="$HOME/Xilinx"
VERSIONS="latest"
DEFAULT_VERSION="latest"'
expect "malformed version" 1 "invalid version 'latest'" -- dry
expect "missing config.env" 1 "Copy config.env.example to config.env" -- \
    env -i HOME="$home" PATH="$PATH" CONFIG_FILE="$tmp/none.env" "$repo/setup.sh" --dry-run
expect "unknown option shows usage" 2 "Usage:" -- "$repo/setup.sh" --bogus

# --- summary ---------------------------------------------------------------

if ((failures)); then
    printf '\n%d test(s) failed\n' "$failures"
    exit 1
fi
printf '\nall tests passed\n'

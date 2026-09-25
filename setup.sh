#!/usr/bin/env bash
# setup.sh: create one distrobox per AMD Vivado/Vitis version listed in config.env.
#
# Usage:
#   ./setup.sh                  create or update every container in VERSIONS
#   ./setup.sh --dry-run        only write build/*.ini and print what would happen
#   ./setup.sh --remove <ver>   remove that container with its commands and menu entries
#
# Tests override paths with CONFIG_FILE, BUILD_DIR and VERSIONS_DIR.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_file=${CONFIG_FILE:-$repo_dir/config.env}
build_dir=${BUILD_DIR:-$repo_dir/build}
versions_dir=${VERSIONS_DIR:-$repo_dir/versions}
launcher=$repo_dir/container/xilinx-run

die() {
    printf 'setup.sh: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'setup.sh: warning: %s\n' "$*" >&2
}

usage() {
    sed -n '2,8s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

box_name() {
    printf 'xilinx-%s\n' "$1"
}

check_version() {
    [[ $1 =~ ^[0-9]{4}\.[0-9]+$ ]] || die "invalid version '$1' (expected e.g. 2025.2)"
}

require_tools() {
    command -v distrobox >/dev/null || die "distrobox is not installed, see https://distrobox.it"
    command -v podman >/dev/null || command -v docker >/dev/null || die "podman or docker is required"
}

load_config() {
    [[ -f $config_file ]] || die "$config_file not found. Copy config.env.example to config.env and edit it."
    # shellcheck source=/dev/null
    source "$config_file"
    [[ -n ${XILINX_DIR:-} ]] || die "XILINX_DIR is not set in $config_file"
    [[ -n ${VERSIONS:-} ]] || die "VERSIONS is not set in $config_file"
    [[ -n ${DEFAULT_VERSION:-} ]] || die "DEFAULT_VERSION is not set in $config_file"
    local ver default_listed=0
    for ver in $VERSIONS; do
        check_version "$ver"
        [[ -f $versions_dir/$ver.ini ]] || die "no $versions_dir/$ver.ini for version $ver"
        if [[ $ver == "$DEFAULT_VERSION" ]]; then
            default_listed=1
        fi
    done
    ((default_listed)) || die "DEFAULT_VERSION $DEFAULT_VERSION is not listed in VERSIONS"
}

# install_dir <ver>: absolute install directory (XILINX_DIR_<ver> overrides XILINX_DIR)
install_dir() {
    local override="XILINX_DIR_${1//./_}"
    realpath -m -- "${!override:-$XILINX_DIR}"
}

under_home() {
    local home
    home=$(realpath -m -- "$HOME")
    [[ $1 == "$home" || $1 == "$home"/* ]]
}

# is_installed <dir> <ver>: settings64.sh exists in the 2025.x or the older layout
is_installed() {
    local f
    for f in "$1/$2/Vivado" "$1/$2/Vitis" "$1/Vivado/$2" "$1/Vitis/$2"; do
        if [[ -f $f/settings64.sh ]]; then
            return 0
        fi
    done
    return 1
}

# tool_installed <dir> <ver> <tool>: the install has that tool (vivado or vitis), in either layout
tool_installed() {
    local product=Vivado
    if [[ $3 == vitis ]]; then
        product=Vitis
    fi
    [[ -x $1/$2/$product/bin/$3 || -x $1/$product/$2/bin/$3 ]]
}

# prepare_dir <dir> <dry_run>: make sure the install directory exists
prepare_dir() {
    if [[ $1 == *[[:space:]]* || $HOME == *[[:space:]]* ]]; then
        die "paths with spaces are not supported: $1"
    fi
    if [[ -d $1 ]]; then
        return 0
    fi
    if ! under_home "$1"; then
        die "$1 does not exist. Create it first: sudo mkdir -p '$1' && sudo chown \"\$USER:\" '$1'"
    fi
    if (($2)); then
        printf 'Would create %s\n' "$1"
    else
        mkdir -p -- "$1"
    fi
}

# host_locales: en_US.UTF-8 (Vivado forces it) plus every UTF-8 locale the host session uses
host_locales() {
    local -a locales=(en_US.UTF-8)
    local name value locale seen=' '
    for name in LANG LC_ALL $(compgen -e | { grep '^LC_' || true; } | sort); do
        value=${!name:-}
        case $value in
            '' | C | C.UTF-8 | C.utf8 | POSIX) continue ;;
        esac
        if [[ $seen == *" $value "* ]]; then
            continue
        fi
        seen+="$value "
        if [[ $value =~ ^([A-Za-z_]+)\.(UTF-8|utf8|utf-8|UTF8)(@[A-Za-z]+)?$ ]]; then
            locale="${BASH_REMATCH[1]}.UTF-8${BASH_REMATCH[3]}"
            if [[ " ${locales[*]} " != *" $locale "* ]]; then
                locales+=("$locale")
            fi
        else
            warn "$name=$value is not a UTF-8 locale; not generating it in the container"
        fi
    done
    printf '%s\n' "${locales[*]}"
}

# icon_source <dir> <ver> <tool>: the tool's icon file in the install, if there is one
icon_source() {
    local -a candidates=()
    local f
    case $3 in
        vivado) candidates=("$1/$2/Vivado/doc/images/vivado_logo.png" "$1/Vivado/$2/doc/images/vivado_logo.png") ;;
        vitis) candidates=("$1/$2/Vitis/ide/electron-app/lnx64/resources/app/resources/icons/vitis-logo-latest.png") ;;
    esac
    for f in "${candidates[@]}"; do
        if [[ -f $f ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

# desktop_entry <tool> <ver> <icon>
desktop_entry() {
    local title=Vivado
    if [[ $1 == vitis ]]; then
        title=Vitis
    fi
    cat <<EOF
[Desktop Entry]
Type=Application
Name=$title $2
Comment=AMD $title $2 in distrobox $(box_name "$2")
Exec=env XILINX_RUN_DIR=$HOME/.cache/xilinx/$2 /usr/local/bin/$1-$2
Icon=$3
Terminal=false
Categories=Development;Electronics;
EOF
}

# write_hook <path in container>: init hook line that writes stdin to that file inside the container
write_hook() {
    printf 'init_hooks="echo %s | base64 -d > %s;"\n' "$(base64 -w0)" "$1"
}

# render_ini <ver>: the distrobox ini for one version
render_ini() {
    local ver=$1 dir tool icon src bin=/usr/local/bin apps=/usr/local/share/applications pixmaps=/usr/share/pixmaps
    dir=$(install_dir "$ver")

    printf '# Generated by setup.sh from versions/%s.ini and config.env. Do not edit; re-run ./setup.sh.\n' "$ver"
    printf '[%s]\n' "$(box_name "$ver")"
    cat -- "$versions_dir/$ver.ini"
    printf '\n'
    cat <<EOF
additional_packages="gcc git locales"
pull=true
replace=true
start_now=false
additional_flags="--env XILINX_DIR=$dir"
additional_flags="--env XILINX_VERSION=$ver"
EOF
    if ! under_home "$dir"; then
        printf 'volume="%s:%s"\n' "$dir" "$dir"
    fi
    printf 'init_hooks="locale-gen %s;"\n' "$(host_locales)"
    printf 'init_hooks="update-locale;"\n'
    write_hook "$bin/xilinx-run" <"$launcher"
    printf 'init_hooks="chmod 755 %s/xilinx-run;"\n' "$bin"
    for tool in vivado vitis "vivado-$ver" "vitis-$ver"; do
        printf 'init_hooks="ln -sf xilinx-run %s/%s;"\n' "$bin" "$tool"
    done

    is_installed "$dir" "$ver" || return 0
    printf 'init_hooks="mkdir -p %s %s;"\n' "$apps" "$pixmaps"
    for tool in vivado vitis; do
        # Only what is installed: a menu entry for a missing tool would silently do nothing.
        if ! tool_installed "$dir" "$ver" "$tool"; then
            continue
        fi
        # A per-version icon name in the container's pixmaps: distrobox-export copies it to
        # ~/.local/share/icons and distrobox rm deletes it again (it can't for absolute paths).
        # A failing hook would stop the container from starting, hence "|| true".
        icon=applications-engineering
        if src=$(icon_source "$dir" "$ver" "$tool"); then
            icon=xilinx-$tool-$ver
            printf 'init_hooks="cp -f %s %s/%s.%s || true;"\n' "$src" "$pixmaps" "$icon" "${src##*.}"
        fi
        desktop_entry "$tool" "$ver" "$icon" | write_hook "$apps/xilinx-$tool-$ver.desktop"
        printf 'exported_bins="%s/%s-%s"\n' "$bin" "$tool" "$ver"
        if [[ $ver == "$DEFAULT_VERSION" ]]; then
            printf 'exported_bins="%s/%s"\n' "$bin" "$tool"
        fi
        printf 'exported_apps="%s/xilinx-%s-%s.desktop"\n' "$apps" "$tool" "$ver"
    done
}

next_steps() {
    cat <<EOF

$1: no install found in $2 yet. Next:
  1. distrobox enter $(box_name "$1")
  2. Run AMD's installer (xsetup) there and install into $2.
     Untick the desktop shortcut and program group options.
  3. Re-run ./setup.sh to add the commands and menu entries.
EOF
}

remove_box() {
    check_version "$1"
    require_tools
    distrobox rm --force "$(box_name "$1")"
    rm -f -- "$build_dir/$(box_name "$1").ini"
}

main() {
    local dry_run=0 ver dir ini
    case ${1:-} in
        '') ;;
        --dry-run) dry_run=1 ;;
        --remove)
            [[ $# -eq 2 ]] || die "usage: ./setup.sh --remove <version>"
            remove_box "$2"
            return
            ;;
        -h | --help)
            usage
            return
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac

    load_config
    if ((!dry_run)); then
        require_tools
    fi
    mkdir -p -- "$build_dir"
    for ver in $VERSIONS; do
        dir=$(install_dir "$ver")
        prepare_dir "$dir" "$dry_run"
        ini=$build_dir/$(box_name "$ver").ini
        render_ini "$ver" >"$ini"
        printf 'Wrote %s\n' "$ini"
        if ((!dry_run)); then
            distrobox assemble create --file "$ini"
        fi
        if ! is_installed "$dir" "$ver"; then
            next_steps "$ver" "$dir"
        fi
    done
}

main "$@"

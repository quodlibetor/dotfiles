#!/bin/sh

set -eu

script_dir="$(cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P)"

# install package-manager-provided things
bash "${script_dir}/install-base" || true

if ! chezmoi="$(command -v chezmoi)"; then
    bin_dir="${HOME}/.local/bin"
    chezmoi="${bin_dir}/chezmoi"
    echo "Installing chezmoi to '${chezmoi}'" >&2
    if command -v curl >/dev/null; then
        chezmoi_install_script="$(curl -fsSL https://chezmoi.io/get)"
    elif command -v wget >/dev/null; then
        chezmoi_install_script="$(wget -qO- https://chezmoi.io/get)"
    else
        echo "To install chezmoi, you must have curl or wget installed." >&2
        exit 1
    fi
    sh -c "${chezmoi_install_script}" -- -b "${bin_dir}"
    unset chezmoi_install_script bin_dir
fi

set -- init --apply --no-tty --no-pager --keep-going --source="${script_dir}"

echo "Running 'chezmoi $*'" >&2
"$chezmoi" "$@" || true

if [[ -e $HOME/init.sh ]]; then
    "$HOME/init.sh"
fi

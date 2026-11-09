#!/bin/bash
# Installs user-level scripts into ~/.local/bin and the autostart entry.
# System patches (patches/) are NOT applied automatically, see README.
set -e
here=$(cd "$(dirname "$0")" && pwd)
bindir=${BINDIR:-$HOME/.local/bin}
mkdir -p "$bindir" "$HOME/.config/autostart"
install -m755 "$here"/bin/* "$bindir"/
sed "s#@BINDIR@#$bindir#" "$here/autostart/display-auto.desktop" > "$HOME/.config/autostart/display-auto.desktop"
echo "Installed to $bindir. Log out/in (or run display-auto) to start the display daemon."

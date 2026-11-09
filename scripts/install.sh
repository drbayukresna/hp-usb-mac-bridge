#!/bin/sh
# Builds hpbridge in release mode and installs it to a bin directory.
# Usage: scripts/install.sh [PREFIX]   (default PREFIX: ~/.local)
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
PREFIX="${1:-$HOME/.local}"
swift build -c release
mkdir -p "$PREFIX/bin"
cp .build/release/hpbridge "$PREFIX/bin/hpbridge"
echo "Installed $PREFIX/bin/hpbridge"
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) echo "Add $PREFIX/bin to your PATH to run 'hpbridge' directly." ;;
esac

#!/bin/bash
set -e
cd "$(dirname "$0")"
meson setup build --prefix=/usr/local --reconfigure 2>/dev/null || meson setup build --prefix=/usr/local
ninja -C build
sudo ninja -C build install
echo "Installed xmonad-wlr and libno-redirect.so to /usr/local"

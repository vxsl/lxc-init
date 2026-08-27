#!/bin/bash

clone_if_not_exists() {
    local repo_url="$1"
    local target_dir="${2:-$(basename "$repo_url" .git)}"
    
    if [ -d "$target_dir" ]; then
        echo "Directory '$target_dir' already exists. Skipping clone."
    else
        if [ "$3" = "--sudo" ]; then
            sudo git clone "$repo_url" "$target_dir"
        else
            git clone "$repo_url" "$target_dir"
        fi
    fi
}


# Git identity: override via GIT_NAME/GIT_EMAIL env vars before running.
name="${GIT_NAME:-$(git config --global user.name || echo "Your Name")}"
email="${GIT_EMAIL:-$(git config --global user.email || echo "you@example.com")}"
update="sudo dnf update"
install="sudo dnf install -yq"
gdm_conf="/etc/gdm/custom.conf"
desktop_file="/usr/share/xsessions/xmonad.desktop"
dnf_conf="/etc/dnf/dnf.conf"
SCRIPT_PATH=$(readlink -f "$0")
DIRNAME=$(dirname "$SCRIPT_PATH")
BRANCH=$(cd "$DIRNAME" && git rev-parse --abbrev-ref HEAD)

# optional init routine
if [ "$1" = "--init" ]; then
    if [ ! "$2" ]; then
        echo "Please provide a timezone, ex. 'America/Vancouver'"
        exit 1
    fi && \
    timedatectl set-timezone "$2" && \
    $update
fi && \

# install X11 support
$install xorg-x11-server-Xorg && \

# bump inotify instance limit (default 128 causes "unable to watch file, too many open files" with multiple editors/agents)
echo 'fs.inotify.max_user_instances=512' | sudo tee /etc/sysctl.d/90-inotify.conf > /dev/null && \
sudo sysctl --system > /dev/null && \

# dnf init
grep -q "^assumeyes=True" "$dnf_conf" || sudo sed -i '/^\[main\]/a assumeyes=True' "$dnf_conf" || echo -e "[main]\nassumeyes=True" | sudo tee -a "$dnf_conf" && \

# init git
$install git && \
if ! command -v tig >/dev/null 2>&1; then
    $install ncurses-devel && \
    clone_if_not_exists https://github.com/vxsl/tig /usr/local/src/tig --sudo && \
    cd /usr/local/src/tig && \
    sudo git config --global --add safe.directory /usr/local/src/tig && \
    sudo git checkout ansi-support-delta-workaround && \
    sudo make prefix=/usr/local && \
    sudo make install prefix=/usr/local
fi && \

# patched picom (SIGUSR2 hot-reload of shaders for flash-free night-light on Asahi)
if ! nm /usr/local/bin/picom 2>/dev/null | grep -q shader_reload_enable; then
    $install libev-devel uthash-devel xcb-util-devel xcb-util-image-devel \
             xcb-util-renderutil-devel xcb-util-wm-devel libconfig-devel pcre2-devel \
             pixman-devel libXext-devel libpng-devel libdrm-devel libepoxy-devel \
             dbus-devel meson ninja-build && \
    clone_if_not_exists https://github.com/vxsl/picom /usr/local/src/picom --sudo && \
    cd /usr/local/src/picom && \
    sudo git config --global --add safe.directory /usr/local/src/picom && \
    sudo git checkout shader-hot-reload && \
    sudo meson setup build && \
    sudo ninja -C build && \
    sudo ninja -C build install
fi && \
git config --global user.email "$email" && \
git config --global user.name "$name" && \
git config --global --add --bool push.autoSetupRemote true && \

# install neovim (config in dotfiles step)
$install neovim && \

# install and configure zsh
$install curl zsh && \
clone_if_not_exists https://github.com/romkatv/powerlevel10k.git $HOME/.zsh/powerlevel10k && \
clone_if_not_exists https://github.com/wting/autojump $HOME/.zsh/autojump && \
mkdir -p ~/.zsh/fzf && \
([ -d ~/.zsh/fzf/.git ] || git clone https://github.com/junegunn/fzf ~/.zsh/fzf) && \
if ! command -v xob >/dev/null 2>&1; then
    $HOME/.zsh/fzf/install
fi && \
([ -f ~/.zsh/antigen.zsh ] || curl -L git.io/antigen > ~/.zsh/antigen.zsh) && \
if [ "$(getent passwd $(whoami) | cut -d: -f7)" != "$(which zsh)" ]; then
    chsh -s $(which zsh)
fi && \


# install and configure xmonad, xmobar, dmenu
$install xmobar fastfetch dmenu && \
clone_if_not_exists https://github.com/vxsl/.xmonad $HOME/.xmonad && \
cd $HOME/.xmonad && \
(git checkout $BRANCH 2>/dev/null || git checkout --track origin/$BRANCH) && \
git config --local status.showUntrackedFiles no && \
clone_if_not_exists https://github.com/xmonad/xmonad $HOME/.xmonad/xmonad && \
clone_if_not_exists https://github.com/xmonad/xmonad-contrib $HOME/.xmonad/xmonad-contrib && \
$install libX11-devel libXft-devel libXinerama-devel libXrandr-devel libXScrnSaver-devel gcc gcc-c++ gmp gmp-devel make ncurses ncurses-compat-libs xz perl pkg-config && \
if [ ! -f "$HOME/.ghcup/bin/stack" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
fi && \
if [ ! -f "$HOME/.xmonad/stack.yaml" ]; then
    $HOME/.ghcup/bin/stack init
fi && \
if ! command -v xmonad >/dev/null 2>&1; then
    $HOME/.ghcup/bin/stack install
fi && \

# register xmonad as DE
if [ ! -f "$desktop_file" ]; then
    sudo cp $DIRNAME/xmonad.desktop "$desktop_file" || exit 1
fi && \

# fix X11 lag on MacBook internal display: force 60Hz via lightdm display-setup-script.
# X11 defaults to EDID preferred mode (120Hz on eDP-1); Apple DCP overhead at 120Hz
# causes input/render lag that doesn't appear on HDMI (60Hz default).
#
# The DISPLAY guard is load-bearing: lightdm runs this as root before opening the
# PAM session and aborts the session if it exits non-zero. Wayland sessions have no
# DISPLAY, so a bare xrandr exits 1 and every Hyprland/sway/GNOME login silently
# bounces back to the greeter (only X sessions like xmonad would start).
#
# Keep this byte-identical to .dotfiles/etc/lightdm/display-setup.sh — setup-stow.sh
# below runs `stow --adopt -t /etc etc`, which moves whatever is already on disk into
# the repo. If the two drift, this copy wins and dirties the dotfiles checkout.
sudo tee /etc/lightdm/display-setup.sh > /dev/null <<'DISPLAY_SETUP'
#!/bin/sh
# LightDM runs this as root once the seat's display server is ready, and aborts
# the session if it exits non-zero. Wayland sessions have no DISPLAY, so an
# unguarded xrandr here fails and bounces you straight back to the greeter.
[ -n "$DISPLAY" ] || exit 0

xrandr --output eDP-1 --mode 3024x1890 --rate 60
exit 0
DISPLAY_SETUP
sudo chmod +x /etc/lightdm/display-setup.sh && \
if grep -q "^display-setup-script=" /etc/lightdm/lightdm.conf 2>/dev/null; then
    true
elif grep -q "^#display-setup-script=" /etc/lightdm/lightdm.conf 2>/dev/null; then
    sudo sed -i "s|^#display-setup-script=.*|display-setup-script=/etc/lightdm/display-setup.sh|" /etc/lightdm/lightdm.conf
else
    sudo sed -i "/^\[Seat:\*\]/a display-setup-script=/etc/lightdm/display-setup.sh" /etc/lightdm/lightdm.conf
fi && \

# install convenience scripts
$install xdotool pactl && \
clone_if_not_exists https://github.com/vxsl/bin $HOME/bin && \
cd $HOME/bin && \
(git checkout $BRANCH 2>/dev/null || git checkout --track origin/$BRANCH) && \
# dev-workflow-tools is a submodule of ~/bin; without this, fzedit/rr/oneshot
# and friends are an empty directory on a fresh box.
git submodule update --init --recursive && \

# install dotfiles
$install dunst nitrogen arandr xautolock xsetroot xclip xwininfo parallel xdg-desktop-portal-gtk && \
clone_if_not_exists https://github.com/vxsl/.dotfiles $HOME/.dotfiles && \
cd $HOME/.dotfiles && \
(git checkout $BRANCH 2>/dev/null || git checkout --track origin/$BRANCH) && \
git submodule update --init --recursive && \
$install stow && \
cd $HOME/.dotfiles && sudo ./setup-stow.sh && \

sudo grubby --update-kernel=ALL --args="hid_apple.swap_opt_cmd=1 hid_apple.swap_fn_leftctrl=1 hid_apple.fnmode=2"

# remap Caps Lock to Escape at kernel level (evdev/hwdb)
echo -e 'evdev:input:b0019v05ACp0352*\n KEYBOARD_KEY_70039=esc' | sudo tee /etc/udev/hwdb.d/90-caps-to-escape.hwdb > /dev/null
sudo systemd-hwdb update

# copy hid_apple modprobe config as a real file (dracut doesn't follow stow symlinks)
# sudo cp --remove-destination $HOME/.dotfiles/etc/modprobe.d/hid_apple.conf /etc/modprobe.d/hid_apple.conf && \
# rebuild initramfs so hid_apple modprobe options (modifier key swaps) apply at boot
# sudo dracut --force && \

# run rescreen on display connect/disconnect via udev + systemd user service
sudo tee /etc/udev/rules.d/95-display-hotplug.rules > /dev/null <<'UDEV'
ACTION=="change", SUBSYSTEM=="drm", TAG+="systemd", ENV{SYSTEMD_USER_WANTS}="rescreen.service"
UDEV
# start the scarlett-keepalive user service when the Focusrite Scarlett is plugged in
# (USB vendor 1235 = Focusrite-Novation, product 821a = Scarlett 4i4 4th Gen)
sudo tee /etc/udev/rules.d/96-focusrite-keepalive.rules > /dev/null <<'UDEV'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1235", ATTR{idProduct}=="821a", TAG+="systemd", ENV{SYSTEMD_USER_WANTS}="scarlett-keepalive.service"
UDEV
sudo udevadm control --reload-rules
mkdir -p $HOME/.config/systemd/user
cat > $HOME/.config/systemd/user/rescreen.service <<EOF
[Unit]
Description=Run rescreen on display hotplug

[Service]
Type=oneshot
Environment=DISPLAY=:0
ExecStart=$HOME/bin/rescreen
EOF
systemctl --user daemon-reload
systemctl --user enable scarlett-keepalive.service 2>/dev/null || true

# install xob and other volume stuff
$install python3-pip && \
pip3 install pulsectl && \
clone_if_not_exists https://github.com/florentc/xob /usr/local/src/xob --sudo && \
cd /usr/local/src/xob && \
$install autoreconf aclocal libX11-devel libXrender-devel libconfig-devel && \
if ! command -v xob >/dev/null 2>&1; then
    sudo make && sudo make install
fi && \


# install xidlehook
if ! command -v cargo >/dev/null 2>&1; then
    $install cargo
fi && \
clone_if_not_exists https://github.com/jD91mZM2/xidlehook $HOME/dev/xidlehook && \
if [ ! -f "$HOME/.cargo/bin/xidlehook" ]; then
    cd $HOME/dev/xidlehook && \
    cargo build --release --bins && \
    mkdir -p $HOME/.cargo/bin &&
    cp $HOME/dev/xidlehook/target/release/xidlehook $HOME/.cargo/bin
fi && \

# install zig (for ly)
if ! command -v zig >/dev/null 2>&1; then
    # Detect architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        ZIG_ARCH="x86_64"
    elif [ "$ARCH" = "aarch64" ]; then
        ZIG_ARCH="aarch64"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi
    
    ZIG_VERSION="0.15.1"
    ZIG_FILENAME="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_FILENAME}"
    
    sudo cd /usr/local/src && \
    sudo wget "$ZIG_URL" && \
    sudo mkdir -p /usr/local/src/zig && \
    sudo tar -xf "$ZIG_FILENAME" -C /usr/local/src/zig && \
    sudo rm "$ZIG_FILENAME" && \
    sudo ln -s "/usr/local/src/zig/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
fi && \


# install ly
$install pam-devel libxcb-devel xorg-x11-xauth brightnessctl && \
if ! command -v ly >/dev/null 2>&1; then
    clone_if_not_exists https://github.com/fairyglade/ly /usr/local/src/ly --sudo && \
    cd /usr/local/src/ly && \
    sudo zig build && \
    sudo zig build installexe -Dinit_system=systemd && \
    sudo systemctl disable gdm lightdm 2>/dev/null || true && \
    sudo systemctl enable ly@tty2 && \
    # https://codeberg.org/fairyglade/ly/issues/494#issuecomment-2926150
    chcon system_u:object_r:xdm_exec_t:s0 $(which ly)
fi && \

# install snap, misc. snaps
$install snapd fuse2-libs && \
sudo ln -sf /var/lib/snapd/snap /snap && \
sudo snap install obsidian --classic
# sudo snap install code --classic && \

# install cursor/vscode extensions
if command -v cursor >/dev/null 2>&1; then
    cd $HOME/.dotfiles && sh install-cursor-extensions.sh
fi

# install nvm and LTS node
if rpm -q nodejs >/dev/null 2>&1; then
    sudo dnf remove -y nodejs
fi
export NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi && \
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" && \
if [ ! -d "$NVM_DIR/versions/node" ] || [ -z "$(ls -A "$NVM_DIR/versions/node")" ]; then
    nvm install --lts && \
    nvm use --lts
fi && \

# nvm is only loaded by interactive zsh (see .zshrc), so anything the session spawns
# -- xmonad scratchpads, systemd user units, and neovim's Mason installing language
# servers -- sees no node toolchain at all. .profile puts ~/.local/bin on PATH
# unconditionally, so shim the toolchain there. Mason needs npm specifically: without
# it, eslint-lsp fails to install and <leader>j silently loses its eslint step.
# corepack enable creates the yarn shim a packageManager field may require.
# ln -sfn (not -s) so re-running after a node upgrade re-points these.
corepack enable 2>/dev/null || true
NODE_BIN="$(dirname "$(nvm which current 2>/dev/null)")" && \
mkdir -p "$HOME/.local/bin" && \
if [ -d "$NODE_BIN" ]; then
    for b in node npx npm corepack yarn pnpm; do
        [ -e "$NODE_BIN/$b" ] && ln -sfn "$NODE_BIN/$b" "$HOME/.local/bin/$b"
    done
fi && \

# install widevine (DRM support for chromium/firefox)
$install widevine-installer && \
if [ ! -f /var/lib/widevine/libwidevinecdm.so ]; then
    sudo widevine-installer
fi && \

# install misc. gui progs
$install firefox chromium-browser alacritty flameshot redshift dmenu ranger xmodmap tmux delta zoxide xinput playerctl thunar google-noto-emoji-color-fonts cava && \

# install rofi, xclip, bat, fd (fzedit's file listing is built on fd)
$install rofi xclip bat fd-find && \
if ! command -v clipmenu >/dev/null 2>&1; then
    $install libXfixes-devel && \
    clone_if_not_exists https://github.com/cdown/clipmenu /usr/local/src/clipmenu --sudo && \
    cd /usr/local/src/clipmenu && \
    sudo make install
fi && \
# install eww
if ! command -v eww >/dev/null 2>&1; then
    sudo dnf install gtk3-devel gtk-layer-shell-devel pango-devel gdk-pixbuf2-devel libdbusmenu-gtk3-devel cairo-devel cairo-gobject-devel glib2-devel glibc-devel && \
    clone_if_not_exists https://github.com/elkowar/eww.git $HOME/dev/eww && \
    cd $HOME/dev/eww && \
    # --locked: dbusmenu-glib 0.1.0 is broken with glib>=0.20 (https://github.com/ralismark/dbusmenu-rs/issues/3)
    # eww's Cargo.lock pins glib to 0.18.5 which works. Remove --locked once dbusmenu-glib is fixed.
    # DEFAULT features = x11 + wayland: one binary that auto-detects the session
    # (X11 under xmonad, Wayland under Hyprland). Do NOT pass --no-default-features.
    cargo build --release --locked && \
    mkdir -p $HOME/.cargo/bin && \
    cp target/release/eww $HOME/.cargo/bin/
fi && \


dnf install gnome-themes extra
gsettings set org.gnome.desktop.interface color-scheme prefer-dark 
gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark

# install eza
if ! command -v eza >/dev/null 2>&1; then
    cargo install eza
fi && \

# install yazi
sudo dnf copr enable lihaohong/yazi -y && $install yazi && \

# install btm
sudo dnf copr enable atim/bottom -y && $install bottom && \

# source .profile
source $HOME/.profile && \

# go home
cd $HOME && \
zsh

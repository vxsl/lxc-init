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


name="Kyle Grimsrud-Manz"
email="kylegm@urbanlogiq.com"
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

# install X11 and Wayland support
$install xorg-x11-server-Xorg wayland meson ninja-build wlroots-devel wayland-protocols-devel libxkbcommon-devel scdoc && \

# build and install cage (Wayland kiosk compositor)
if ! command -v cage >/dev/null 2>&1; then
    clone_if_not_exists https://github.com/cage-kiosk/cage /tmp/cage-build && \
    cd /tmp/cage-build && \
    meson setup build --buildtype=release && \
    meson compile -C build && \
    sudo cp build/cage /usr/local/bin/cage
fi && \

# create xmonad wayland session entry
sudo tee /usr/local/bin/xmonad-wayland-session > /dev/null <<'SESSION_SCRIPT'
#!/bin/bash
# Session: xmonad inside rootful Xwayland on cage (Wayland kiosk)

LOG=/tmp/xmonad-wayland-session.log
exec > "$LOG" 2>&1
set -x

# Clean stale X lock files from prior sessions
for lock in /tmp/.X*-lock; do
    [ -f "$lock" ] || continue
    pid=$(tr -d ' ' < "$lock")
    kill -0 "$pid" 2>/dev/null || rm -f "$lock" "/tmp/.X11-unix/X${lock//[^0-9]/}" 2>/dev/null
done

# Read connected DRM outputs
declare -a OUTPUT_NAMES
declare -a OUTPUT_WS
declare -a OUTPUT_HS
declare -a OUTPUT_MMW
declare -a OUTPUT_MMH
TOTAL_W=0
TOTAL_H=0

for conn in /sys/class/drm/card2-*/status; do
    [ "$(cat "$conn")" = "connected" ] || continue
    dir="$(dirname "$conn")"
    first_mode=$(head -1 "$dir/modes" 2>/dev/null)
    [ -z "$first_mode" ] && continue
    w=${first_mode%x*}; h=${first_mode#*x}
    name=$(basename "$dir"); name=${name#card2-}
    mmw=$(cat "$dir/../../drm_connector_attrs/connector_id/phys_dimensions_mm" 2>/dev/null | cut -dx -f1)
    mmh=$(cat "$dir/../../drm_connector_attrs/connector_id/phys_dimensions_mm" 2>/dev/null | cut -dx -f2)
    [ -z "$mmw" ] && mmw=$((w * 25 / 96))
    [ -z "$mmh" ] && mmh=$((h * 25 / 96))
    OUTPUT_NAMES+=("$name")
    OUTPUT_WS+=("$w")
    OUTPUT_HS+=("$h")
    OUTPUT_MMW+=("$mmw")
    OUTPUT_MMH+=("$mmh")
    TOTAL_W=$((TOTAL_W + w))
    [ "$h" -gt "$TOTAL_H" ] && TOTAL_H=$h
done
[ "$TOTAL_W" -eq 0 ] && TOTAL_W=3024
[ "$TOTAL_H" -eq 0 ] && TOTAL_H=1890

cage -- Xwayland :5 -geometry "${TOTAL_W}x${TOTAL_H}" -host-grab &
CAGE_PID=$!

for i in $(seq 1 50); do
    xdpyinfo -display :5 &>/dev/null && break
    sleep 0.1
done

export DISPLAY=:5
export GDK_BACKEND=x11
unset WAYLAND_DISPLAY
unset XDG_SESSION_TYPE

# Carve Xwayland framebuffer into logical monitors for xmonad/Xinerama.
echo "=== xrandr --query ===" && xrandr --query
echo "=== xrandr --listmonitors ===" && xrandr --listmonitors

if [ ${#OUTPUT_NAMES[@]} -gt 1 ]; then
    # Rootful Xwayland creates one connected output (typically XWAYLAND0) spanning
    # the full framebuffer. Assigning it to monitor-0 removes the automatic
    # full-framebuffer monitor entry (per RandR spec: setmonitor deletes any monitor
    # that shares the same outputs). monitor-1..N use "none" (virtual, no output).
    XRANDR_CONN_OUTPUT=$(xrandr --query | awk '/ connected/ {print $1; exit}')
    [ -z "$XRANDR_CONN_OUTPUT" ] && XRANDR_CONN_OUTPUT="none"
    echo "Connected RandR output: $XRANDR_CONN_OUTPUT"

    X_OFFSET=0
    for i in "${!OUTPUT_NAMES[@]}"; do
        w="${OUTPUT_WS[$i]}"; h="${OUTPUT_HS[$i]}"
        mmw="${OUTPUT_MMW[$i]}"; mmh="${OUTPUT_MMH[$i]}"
        if [ "$i" -eq 0 ]; then
            xrandr --setmonitor "monitor-${i}" "${w}/${mmw}x${h}/${mmh}+${X_OFFSET}+0" "$XRANDR_CONN_OUTPUT"
        else
            xrandr --setmonitor "monitor-${i}" "${w}/${mmw}x${h}/${mmh}+${X_OFFSET}+0" none
        fi
        X_OFFSET=$((X_OFFSET + w))
    done

    echo "=== xrandr --listmonitors (after setup) ===" && xrandr --listmonitors
fi

xmonad

kill $CAGE_PID 2>/dev/null
SESSION_SCRIPT
sudo chmod +x /usr/local/bin/xmonad-wayland-session && \

sudo tee /usr/share/wayland-sessions/xmonad-wayland.desktop > /dev/null <<'DESKTOP'
[Desktop Entry]
Name=xmonad (Wayland)
Comment=xmonad inside rootful Xwayland on cage
Exec=/usr/local/bin/xmonad-wayland-session
Type=Application
DesktopNames=GNOME
DESKTOP


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

# install convenience scripts
$install xdotool pactl && \
clone_if_not_exists https://github.com/vxsl/bin $HOME/bin && \
cd $HOME/bin && \
(git checkout $BRANCH 2>/dev/null || git checkout --track origin/$BRANCH) && \

# install dotfiles
$install dunst nitrogen arandr xautolock picom xsetroot xclip xwininfo parallel xdg-desktop-portal-gtk && \
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
    sudo systemctl disable gdm && \
    sudo systemctl enable ly && \
    sudo systemctl disable getty@tty2.service && \
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

# install widevine (DRM support for chromium/firefox)
$install widevine-installer && \
if [ ! -f /var/lib/widevine/libwidevinecdm.so ]; then
    sudo widevine-installer
fi && \

# install misc. gui progs
$install firefox chromium-browser alacritty flameshot redshift dmenu ranger xmodmap tmux delta zoxide xinput playerctl thunar google-noto-emoji-color-fonts && \

# install rofi, xclip, bat
$install rofi xclip bat && \
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
    cargo build --release --locked --no-default-features --features x11 && \
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

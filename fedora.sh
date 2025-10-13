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
email="hi@kylegrimsrudma.nz"
update="sudo dnf update"
install="sudo dnf install -yq"
gdm_conf="/etc/gdm/custom.conf"
desktop_file="/usr/share/xsessions/xmonad.desktop"
dnf_conf="/etc/dnf/dnf.conf"
SCRIPT_PATH=$(readlink -f "$0")
DIRNAME=$(dirname "$SCRIPT_PATH")

# optional init routine
if [ "$1" = "--init" ]; then
    if [ ! "$2" ]; then
        echo "Please provide a timezone, ex. 'America/Vancouver'"
        exit 1
    fi && \
    timedatectl set-timezone "$2" && \
    $update
fi && \

# install X, disable Wayland
$install xorg-x11-server-Xorg && \
if [[ -f "$gdm_conf" ]]; then
    sudo sed -i '/^#*WaylandEnable/c\WaylandEnable=false' "$gdm_conf"
else
    echo "$gdm_conf not found to disable Wayland"
    exit 1
fi && \

# dnf init
grep -q "^assumeyes=True" "$dnf_conf" || sudo sed -i '/^\[main\]/a assumeyes=True' "$dnf_conf" || echo -e "[main]\nassumeyes=True" | sudo tee -a "$dnf_conf" && \

# init git
if ! command -v tig >/dev/null 2>&1; then
    $install git tig && \
fi && \
git config --global user.email "$email" && \
git config --global user.name "$name" && \

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

# install dotfiles
$install dunst nitrogen arandr xautolock picom xsetroot xclip xwininfo parallel && \
clone_if_not_exists https://github.com/vxsl/.dotfiles $HOME/.dotfiles && \
cd $HOME/.dotfiles && \
git submodule update --init --recursive
$install stow && \
cd $HOME/.dotfiles && ./setup-stow.sh && \

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
$install snapd && \
sudo ln -sf /var/lib/snapd/snap /snap && \
sudo snap install obsidian --classic
# sudo snap install code --classic && \

# install node
if ! command -v node >/dev/null 2>&1; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    nvm install node && \
    nvm use node 
fi && \

# install misc. gui progs
$install firefox chromium-browser alacritty flameshot redshift dmenu ranger xmodmap tmux delta && \

# install rofi, xclip, bat
$install rofi xclip bat && \
if ! command -v clipmenu >/dev/null 2>&1; then
    clone_if_not_exists https://github.com/cdown/clipmenu /usr/local/src/clipmenu --sudo && \
    cd /usr/local/src/clipmenu && \
    sudo make install 
fi && \
# install eww
if ! command -v eww >/dev/null 2>&1; then
    sudo dnf install gtk3-devel gtk-layer-shell-devel pango-devel gdk-pixbuf2-devel libdbusmenu-gtk3-devel cairo-devel glib2-devel glibc-devel
    git clone --depth=1 https://github.com/elkowar/eww.git
fi && \


dnf install gnome-themes extra
gsettings set org.gnome.desktop.interface color-scheme prefer-dark 
gsettings set org.gnome.desktop.interface gtk-theme Adwaita-dark

# install btm
sudo dnf copr enable atim/bottom -y && $install bottom && \

# source .profile
source $HOME/.profile && \

# go home
cd $HOME && \
zsh

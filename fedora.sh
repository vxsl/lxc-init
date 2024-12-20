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

# timedatectl set-timezone America/Vancouver

update="sudo dnf update"
install="sudo dnf install -yq"
SCRIPT_PATH=$(readlink -f "$0")
DIRNAME=$(dirname "$SCRIPT_PATH")

$install xorg-x11-server-Xorg
gdm_conf="/etc/gdm/custom.conf"
if [[ -f "$gdm_conf" ]]; then
    sudo sed -i '/^#*WaylandEnable/c\WaylandEnable=false' "$gdm_conf"
else
    echo "$gdm_conf not found to disable Wayland"
    exit 1
fi && \

$update && \
$install git tig curl zsh neovim && \
git config --global user.email "hi@kylegrimsrudma.nz" && \
git config --global user.name "Kyle Grimsrud-Manz" && \
clone_if_not_exists https://github.com/wting/autojump $HOME/.zsh/autojump && \
mkdir -p ~/.zsh/fzf && \
([ -d ~/.zsh/fzf/.git ] || git clone https://github.com/junegunn/fzf ~/.zsh/fzf) && \
([ -f ~/.zsh/antigen.zsh ] || curl -L git.io/antigen > ~/.zsh/antigen.zsh) && \
if [ "$(getent passwd $(whoami) | cut -d: -f7)" != "$(which zsh)" ]; then
    chsh -s $(which zsh)
fi && \

$install xmobar fastfetch && \

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
cd $HOME/.xmonad && \
$HOME/.ghcup/bin/stack install

desktop_file="/usr/share/xsessions/xmonad.desktop"
if [ ! -f "$desktop_file" ]; then
    sudo cp $DIRNAME/xmonad.desktop "$desktop_file"
fi && \

$install xdotool && \
clone_if_not_exists https://github.com/vxsl/bin $HOME/bin && \

$install dunst nitrogen arandr xautolock picom xsetroot && \
clone_if_not_exists https://github.com/vxsl/.dotfiles $HOME/.dotfiles && \
$install stow && \
cd $HOME/.dotfiles && ./setup-stow.sh && \

[ -f ~/.profile ] && grep -q "export EDITOR=nvim" ~/.profile || echo "export EDITOR=nvim" >> ~/.profile
[ -f ~/.profile ] && grep -q "export GIT_EDITOR=nvim" ~/.profile || echo "export GIT_EDITOR=nvim" >> ~/.profile

$install python3-pip && \
pip3 install pulsectl && \
clone_if_not_exists https://github.com/florentc/xob /usr/local/src/xob --sudo && \
cd /usr/local/src/xob && \
$install autoreconf aclocal libX11-devel libXrender-devel libconfig-devel && \
sudo make && sudo make install && \

$install cargo && \
clone_if_not_exists https://github.com/jD91mZM2/xidlehook $HOME/dev/xidlehook && \
cd $HOME/dev/xidlehook && \
cargo build --release --bins && \
mkdir -p $HOME/.cargo/bin &&
cp $HOME/dev/xidlehook/target/release/xidlehook $HOME/.cargo/bin && \

$install snapd && \
sudo ln -s /var/lib/snapd/snap /snap && \
snap install obsidian --classic && \
snap install code --classic && \

source $HOME/.profile && \
$install firefox alacritty && \
cd $HOME && \
zsh

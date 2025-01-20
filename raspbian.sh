#!/bin/bash

set -e
# trap 'rc=$?; echo "error code $rc at $LINENO"; exit $rc' ERR

for arg in "$@"; do
    case "$arg" in
        --install-xmonad-as-pkg*)
            install_xmonad_as_pkg=true
            ;;
    esac
done

step() {
    echo -e 
    echo "========================================================================"
    echo "* $@"
    echo "------------------------------------------------------------------------"
}

clone_if_not_exists() {
    local repo_url="$1"
    local target_dir="${2:-$(basename "$repo_url" .git)}"
    
    if [ -d "$target_dir" ]; then
        echo "already cloned '$target_dir'"
    else
        if [ "$3" = "--sudo" ]; then
            sudo git clone "$repo_url" "$target_dir"
        else
            git clone "$repo_url" "$target_dir"
        fi
    fi
}

declare -A pkgs_ubuntu_debian
pkgs_ubuntu_debian["dmenu"]="suckless-tools"
pkgs_ubuntu_debian["libXinerama-devel"]="libxinerama-dev"
pkgs_ubuntu_debian["libXrandr-devel"]="libxrandr-dev"
pkgs_ubuntu_debian["libXScrnSaver-devel"]="libxss-dev"
pkgs_ubuntu_debian["gcc-c++"]="g++"
pkgs_ubuntu_debian["gmp"]="libgmp-dev"
pkgs_ubuntu_debian["gmp-devel"]="libgmp-dev"
pkgs_ubuntu_debian["ncurses"]="libncurses-dev"
pkgs_ubuntu_debian["ncurses-compat-libs"]="libncurses-dev"
pkgs_ubuntu_debian["xz"]="xz-utils"
pkgs_ubuntu_debian["pactl"]="pulseaudio-utils"
pkgs_ubuntu_debian["xsetroot"]="x11-xserver-utils"
pkgs_ubuntu_debian["xwininfo"]="x11-utils"
pkgs_ubuntu_debian["autoreconf"]="autoconf"
pkgs_ubuntu_debian["aclocal"]="automake"
pkgs_ubuntu_debian["libXrender-devel"]="libxrender-dev"
pkgs_ubuntu_debian["libconfig-devel"]="libconfig-dev"

declare -A pkgs_fedora
pkgs_fedora["libXinerama"]="libXinerama-devel"
pkgs_fedora["libXrandr"]="libXrandr-devel"
pkgs_fedora["libXScrnSaver"]="libXScrnSaver-devel"
pkgs_fedora["gcc"]="gcc"
pkgs_fedora["gmp"]="gmp"
pkgs_fedora["make"]="make"
pkgs_fedora["ncurses"]="ncurses"
pkgs_fedora["xz"]="xz"
pkgs_fedora["perl"]="perl"
pkgs_fedora["pkg-config"]="pkg-config"


distro=$(awk -F= '/^ID=/ { print $2 }' /etc/os-release)

# Select the appropriate package map based on the distro
# https://stackoverflow.com/a/78068508/5827204
case "$distro" in
    "ubuntu" | "debian")
        tmpDef=$(declare -p pkgs_ubuntu_debian) && declare -A pkgs="${tmpDef#*=}"
        ;;
    "fedora")
        tmpDef=$(declare -p pkgs_fedora) && declare -A pkgs="${tmpDef#*=}"
        ;;
    *)
        echo "Unsupported distro: $distro"
        exit 1
        ;;
esac


name="Kyle Grimsrud-Manz"
email="hi@kylegrimsrudma.nz"
upgrade="sudo apt upgrade"
install="sudo apt install -qq -y --no-install-recommends"
gdm_conf="/etc/gdm/custom.conf"
desktop_file="/usr/share/xsessions/xmonad.desktop"
dnf_conf="/etc/dnf/dnf.conf"
SCRIPT_PATH=$(readlink -f "$0")
DIRNAME=$(dirname "$SCRIPT_PATH")

command_exists() {
    command -v $1 >/dev/null 2>&1
    res=$?
    if [ $res -eq 0 ]; then
        echo "command '$1' already exists"
    fi
    return $res
}

install_if_not_exists() {
    local to_install=()

    for el in "$@"; do
        local p
        if [ -v pkgs[$el] ]; then
            p="${pkgs[$el]}"
        else
            p=$el
        fi
        exists_check=$(dpkg -l "$p" 2>/dev/null || echo "")
        exists=$(echo "$exists_check" | grep -q ^ii; echo $?)

        if [ $exists -eq 0 ]; then
            echo "'$p' already installed"
        else
            echo "'$p' not installed, adding to install list"
            to_install+=("$p")
        fi
    done

    if [ ${#to_install[@]} -gt 0 ]; then
        echo "installing: ${to_install[*]}"
        $install "${to_install[@]}"
    fi
}

install_python_module() {
    local pipout
    set +e
    pipout=$(pip3 install "$1" 2>&1)
    set -e
    if [[ $pipout == *"externally-managed-environment"* ]]; then
        install_if_not_exists "python3-$1"
    else
        echo "$pipout"
    fi
}

# optional init routine
if [ "$1" = "--init" ]; then
    if [ ! "$2" ]; then
        echo "Please provide a timezone, ex. 'America/Vancouver'"
        exit 1
    fi 
    timedatectl set-timezone "$2" 
    $upgrade
fi 

install_if_not_exists curl

step "install git and tig"
install_if_not_exists git tig 
git config --global user.email "$email" 
git config --global user.name "$name" 

step "install neovim (config in dotfiles step)"
install_if_not_exists neovim

step "clone dotfiles, linking only .profile, zsh config and neovim config (remaining dotfiles will be linked later)"
install_if_not_exists stow 
clone_if_not_exists https://github.com/vxsl/.dotfiles $HOME/.dotfiles 
cd $HOME/.dotfiles 
git submodule update --init --recursive
if [ ! -L "$HOME/.profile" ]; then
    stow -D xdg-home 
    if [ -f "$HOME/.profile" ]; then
        mv -f $HOME/.profile $HOME/.profile-bak
    fi
    stow -t "$HOME" xdg-home-minimal
fi

step install convenience scripts
install_if_not_exists xdotool pactl 
clone_if_not_exists https://github.com/vxsl/bin $HOME/bin 

step "install and configure zsh (and tmux, because of 'zsh-system-clipboard-set-tmux')"
install_if_not_exists zsh tmux
clone_if_not_exists https://github.com/vxsl/powerlevel10k $HOME/.zsh/powerlevel10k 
clone_if_not_exists https://github.com/wting/autojump $HOME/.zsh/autojump 
if [ ! -d $HOME/.zsh/fzf ]; then
    clone_if_not_exists https://github.com/junegunn/fzf $HOME/.zsh/fzf 
    cd $HOME/.zsh/fzf
    ./install --key-bindings --completion --no-update-rc
fi
([ -f ~/.zsh/antigen.zsh ] || curl -L git.io/antigen > ~/.zsh/antigen.zsh) 
if [ "$(getent passwd $(whoami) | cut -d: -f7)" != "$(which zsh)" ]; then
    sudo chsh -s $(which zsh) $(whoami)
fi 


step install go
[[ ! "$PATH" =~ "/usr/local/go/bin" ]] && export PATH="$PATH:/usr/local/go/bin"
if ! command_exists go; then
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    [[ $ARCH == "x86_64" ]] && ARCH="amd64"
    [[ $ARCH == "aarch64" ]] && ARCH="arm64" || { echo "Unsupported architecture: $ARCH"; exit 1; }

    URL=$(curl -s https://go.dev/VERSION?m=text | head -n1 | xargs -I{} echo "https://go.dev/dl/{}.$OS-$ARCH.tar.gz")
    [[ $(curl -Isf $URL) ]] || { echo "Invalid URL for $OS-$ARCH"; exit 1; }

    TMP_DIR=$(mktemp -d)
    curl -L $URL -o $TMP_DIR/go.tar.gz
    sudo tar -C /usr/local -xzf $TMP_DIR/go.tar.gz
    rm -rf $TMP_DIR

    export PATH=$PATH:/usr/local/go/bin 
    go version
fi

step "install libx11-devel (needed for emptty, xmonad, xob, fastfetch, etc...)"
install_if_not_exists libx11-dev

step install emptty
clone_if_not_exists https://github.com/tvrzna/emptty /usr/local/src/emptty --sudo 
cd /usr/local/src/emptty 
if ! command_exists emptty; then
    echo "Installing emptty"
    install_if_not_exists gcc libpam0g-dev
    sudo make build
    sudo make install-all
    for dm in gdm gdm3 lightdm sddm; do
        sudo systemctl disable --now $dm 2>/dev/null || true
    done
    sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
    sudo touch /etc/systemd/system/getty@tty1.service.d/override.conf 
sudo bash -c 'cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/emptty
EOF'
    sudo systemctl daemon-reload
    sudo systemctl restart getty@tty1
    sudo raspi-config nonint do_boot_behaviour B2
fi


step install X, disable Wayland
install_if_not_exists xauth 
# if [[ -f "$gdm_conf" ]]; then
#     sudo sed -i '/^#*WaylandEnable/c\WaylandEnable=false' "$gdm_conf"
# else
#     echo "$gdm_conf not found to disable Wayland"
#     exit 1
# fi 

# dnf init
# grep -q "^assumeyes=True" "$dnf_conf" || sudo sed -i '/^\[main\]/a assumeyes=True' "$dnf_conf" || echo -e "[main]\nassumeyes=True" | sudo tee -a "$dnf_conf" 

# init git

step install fastfetch
install_if_not_exists cmake
clone_if_not_exists https://github.com/fastfetch-cli/fastfetch /usr/local/src/fastfetch --sudo
cd /usr/local/src/fastfetch
if ! command_exists fastfetch; then
    install_if_not_exists \
        libvulkan1 \
        libxcb-randr0-dev libxrandr-dev libxcb1-dev \
        libwayland-client0 \
        libdrm-dev \
        libglib2.0-dev \
        libdconf1 \
        libmagickcore-6.q16-6-extra imagemagick \
        libchafa0 \
        zlib1g-dev \
        libdbus-1-dev \
        libegl1-mesa-dev libglx-dev libosmesa6-dev \
        ocl-icd-libopencl1 \
        libxfconf-0-dev \
        libsqlite3-dev \
        libelf-dev \
        librpm-dev \
        libpulse-dev \
        libddcutil4
    sudo mkdir -p build
    cd build
    sudo cmake ..
    sudo cmake --build . --target fastfetch
    sudo cp build/fastfetch /usr/local/bin
fi

if [ ! -d $HOME/.xmonad ]; then
    step clone xmonad config
    clone_if_not_exists https://github.com/vxsl/.xmonad $HOME/.xmonad 
    cd $HOME/.xmonad
    git config --local status.showUntrackedFiles no 
fi
if [ "$install_xmonad_as_pkg" == "true" ]; then
    step "'--install-xmonad-as-pkg' option provided: skipping haskell environment setup"
else
    [ -f "$HOME/.ghcup/env" ] && source "$HOME/.ghcup/env" 
    if ! command_exists stack; then
        step haskell environment setup
        cd $HOME/.xmonad 
        resolver=$(grep 'snapshot:' stack.yaml | awk '{print $2}')
        if [ -z "$resolver" ]; then
            echo "stack snapshot not found"
            exit 1
        fi
        ghc_version=$(curl -s "https://www.stackage.org/${resolver}/cabal.config" | grep "^with-compiler: ghc-" | awk -F'-' '{print $3}')
        if [ -z "$ghc_version" ]; then
            echo "Could not find the GHC version for resolver $resolver"
            exit 1
        fi
        echo "running ghcup with BOOTSTRAP_HASKELL_GHC_VERSION=$ghc_version"
        curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_GHC_VERSION=$ghc_version BOOTSTRAP_HASKELL_CABAL_VERSION=latest BOOTSTRAP_HASKELL_INSTALL_STACK=1 BOOTSTRAP_HASKELL_INSTALL_HLS=1 BOOTSTRAP_HASKELL_ADJUST_BASHRC=P sh
        source "$HOME/.ghcup/env" 
    fi 
fi 
if ! command_exists xmonad; then
    step install xmonad
    cd $HOME/.xmonad 
    if [ "$install_xmonad_as_pkg" == "true" ]; then
        install_if_not_exists x11-utils xmonad libghc-xmonad-dev libghc-xmonad-contrib-dev
    else
        clone_if_not_exists https://github.com/xmonad/xmonad $HOME/.xmonad/xmonad 
        clone_if_not_exists https://github.com/xmonad/xmonad-contrib $HOME/.xmonad/xmonad-contrib 
        install_if_not_exists libXinerama-devel libXrandr-devel libXScrnSaver-devel gcc gcc-c++ gmp gmp-devel make ncurses ncurses-compat-libs xz perl pkg-config 
        stack install
    fi
fi 

step install and configure xmonad, xmobar, dmenu
install_if_not_exists xmobar dmenu 

# register xmonad as DE
if [ ! -f "$desktop_file" ]; then
    sudo cp $DIRNAME/xmonad.desktop "$desktop_file"
fi 

step link all dotfiles
install_if_not_exists dunst nitrogen arandr xautolock picom xsetroot xclip xwininfo parallel
cd $HOME/.dotfiles
stow -D xdg-home-minimal 
./setup-stow.sh 

step install xob and other volume stuff
install_if_not_exists python3-pip
install_python_module pulsectl
clone_if_not_exists https://github.com/florentc/xob /usr/local/src/xob --sudo 
cd /usr/local/src/xob 
if ! command_exists xob; then
    install_if_not_exists autoreconf aclocal libXrender-devel libconfig-devel 
    sudo make && sudo make install
fi 

# step install xidlehook
# if ! command_exists xidlehook; then
#     # install_if_not_exists cargo 
#     if ! command_exists cargo; then
#         step installing rust
#         if [ ! -f "$HOME/.cargo/env" ]; then
#             curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
#         fi
#         . $HOME/.cargo/env
#     fi 
#     cargo install xidlehook --bins
# fi
# clone_if_not_exists https://github.com/jD91mZM2/xidlehook /usr/local/src/xidlehook --sudo
# if [ ! -f "$HOME/.cargo/bin/xidlehook" ]; then
#     cd /usr/local/src/xidlehook 
#     if grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null || grep -q "BCM" /proc/cpuinfo 2>/dev/null; then 
#         sudo sh -c 'echo "[profile.release]\ncodegen-units = 1" >> Cargo.toml'
#     fi
#     sudo cargo build --release --bins 
#     mkdir -p $HOME/.cargo/bin
#     sudo cp /usr/local/src/xidlehook/target/release/xidlehook $HOME/.cargo/bin
# fi 

# step install snap, misc. snaps
# install_if_not_exists snapd:snap 
# sudo ln -sf /var/lib/snapd/snap /snap 
# sudo snap install obsidian --classic 
# sudo snap install code --classic 

# source .profile
source $HOME/.profile 

# step install misc. gui progs
# install_if_not_exists firefox alacritty 

# go home
cd $HOME 
zsh

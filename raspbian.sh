#!/bin/bash

# Ensure the script is run with sudo
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with sudo. Exiting..."
  exit 1
fi

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
upgrade="sudo apt upgrade"
install="sudo apt install -qq -y"
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
    $upgrade
fi && \

# Check if WM config has already been done
if ! systemctl get-default | grep -q 'multi-user.target' || \
   systemctl is-active --quiet gdm3 || \
   systemctl is-active --quiet lightdm || \
   systemctl is-active --quiet sddm; then

    # Set boot target to CLI and disable display managers
    echo "Configuring boot target..."
    systemctl set-default multi-user.target
    for dm in gdm3 lightdm sddm; do
        systemctl disable --now $dm 2>/dev/null || true
    done

    # Install xinit if not already installed
    command -v xinit &>/dev/null || apt update && apt install -y xinit

    # Create or update desktop environment selection script
    cat << 'EOF' > /usr/local/bin/choose-de
    #!/bin/bash
    echo "Select a desktop environment:"
    wm_options=("startlxde" "xmonad" "i3" "awesome" "openbox" "sway" "fluxbox" "gnome-session" "startkde" "startxfce4" "cinnamon" "mate-session")

    for i in "${!wm_options[@]}"; do
        echo "$((i + 1))) ${wm_options[$i]}"
    done

    read -p "Choice: " choice
    if (( choice >= 1 && choice <= ${#wm_options[@]} )); then
        exec ${wm_options[$((choice - 1))]}
    else
        echo "Invalid choice. Exiting."
        exit 1
    fi
EOF
    chmod +x /usr/local/bin/choose-de

    # Create or ensure .xinitrc exists for users
    if [[ ! -f /etc/skel/.xinitrc ]]; then
        echo "exec /usr/local/bin/choose-de" > /etc/skel/.xinitrc
    fi

    # Ensure users' .xinitrc exists
    for user_home in /home/*; do
        [[ -d "$user_home" ]] && cp /etc/skel/.xinitrc "$user_home/.xinitrc" && chown "$(basename "$user_home"):$(basename "$user_home")" "$user_home/.xinitrc"
    done

    echo "Configuration complete. System will now boot to CLI."
    echo "Use 'startx' after logging in to choose and start a desktop environment."

fi

# install X, disable Wayland
$install xauth && \
if [[ -f "$gdm_conf" ]]; then
    sudo sed -i '/^#*WaylandEnable/c\WaylandEnable=false' "$gdm_conf"
else
    echo "$gdm_conf not found to disable Wayland"
    exit 1
fi && \

# dnf init
grep -q "^assumeyes=True" "$dnf_conf" || sudo sed -i '/^\[main\]/a assumeyes=True' "$dnf_conf" || echo -e "[main]\nassumeyes=True" | sudo tee -a "$dnf_conf" && \

# init git
$install git tig && \
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
    $HOME/.ghcup/bin/stack init && \
    $HOME/.ghcup/bin/stack install
fi && \

# register xmonad as DE
if [ ! -f "$desktop_file" ]; then
    sudo cp $DIRNAME/xmonad.desktop "$desktop_file"
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
if [ ! command xob >/dev/null 2>&1 ]; then
    sudo make && sudo make install
fi && \

# install xidlehook
$install cargo && \
clone_if_not_exists https://github.com/jD91mZM2/xidlehook $HOME/dev/xidlehook && \
if [ ! -f "$HOME/.cargo/bin/xidlehook" ]; then
    cd $HOME/dev/xidlehook && \
    cargo build --release --bins && \
    mkdir -p $HOME/.cargo/bin &&
    cp $HOME/dev/xidlehook/target/release/xidlehook $HOME/.cargo/bin
fi && \

# install snap, misc. snaps
$install snapd && \
sudo ln -sf /var/lib/snapd/snap /snap && \
sudo snap install obsidian --classic && \
sudo snap install code --classic && \

# source .profile
source $HOME/.profile && \

# install misc. gui progs
$install firefox alacritty && \

# go home
cd $HOME && \
zsh

#!/bin/bash

timedatectl set-timezone America/Vancouver

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

SCRIPT_PATH=$(readlink -f "$0")
DIRNAME=$(dirname "$SCRIPT_PATH")
[ -f ./.zshrc ] && ln -sf $DIRNAME/.zshrc ~/.zshrc
[ -f ./.tigrc ] && ln -sf $DIRNAME/.tigrc ~/.tigrc

[ -f ~/.profile ] && grep -q "export EDITOR=nvim" ~/.profile || echo "export EDITOR=nvim" >> ~/.profile
[ -f ~/.profile ] && grep -q "export GIT_EDITOR=nvim" ~/.profile || echo "export GIT_EDITOR=nvim" >> ~/.profile

sudo apt update && \
sudo apt install -yq git && \
sudo apt install -yq tig && \
sudo apt install -yq curl && \
sudo apt install -yq zsh && \
sudo apt install -yq neovim && \
sudo apt clean && \
mkdir -p ~/.zsh/fzf && \
clone_if_not_exists https://github.com/wting/autojump $HOME/.zsh/autojump && \
([ -d ~/.zsh/fzf/.git ] || git clone https://github.com/junegunn/fzf ~/.zsh/fzf) && \
([ -f ~/.zsh/antigen.zsh ] || curl -L git.io/antigen > ~/.zsh/antigen.zsh) && \
chsh -s $(which zsh) && \
zsh

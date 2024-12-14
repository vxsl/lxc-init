#!/bin/bash

timedatectl set-timezone America/Vancouver

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
sudo apt install -yq autojump && \
sudo apt clean && \
mkdir -p ~/.zsh/fzf && \
([ -d ~/.zsh/fzf/.git ] || git clone https://github.com/junegunn/fzf ~/.zsh/fzf) && \
([ -f ~/.zsh/antigen.zsh ] || curl -L git.io/antigen > ~/.zsh/antigen.zsh) && \
chsh -s $(which zsh) && \
zsh

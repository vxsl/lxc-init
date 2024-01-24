#!/bin/bash

SCRIPT_PATH=$(readlink -f "$0")
DIRNAME=$(dirname "$SCRIPT_PATH")
[ -f ./.zshrc ] && ln -sf $DIRNAME/.zshrc ~/.zshrc
[ -f ./.tigrc ] && ln -sf $DIRNAME/.tigrc ~/.tigrc

[ -f ~/.profile ] && grep -q "export EDITOR=nvim" ~/.profile || echo "export EDITOR=nvim" >> ~/.profile
[ -f ~/.profile ] && grep -q "export GIT_EDITOR=nvim" ~/.profile || echo "export GIT_EDITOR=nvim" >> ~/.profile

sudo apt update && \
sudo apt install -y git && \
sudo apt install -y tig && \
sudo apt install -y curl && \
sudo apt install -y zsh && \
sudo apt install -y neovim && \
sudo apt install -y autojump && \
sudo apt clean && \
mkdir -p ~/.zsh/fzf && \
([ -d ~/.zsh/fzf/.git ] || git clone https://github.com/junegunn/fzf ~/.zsh/fzf) && \
([ -f ~/.zsh/antigen.zsh ] || curl -L git.io/antigen > ~/.zsh/antigen.zsh) && \
chsh -s $(which zsh) && \
zsh

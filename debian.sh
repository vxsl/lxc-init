#!/bin/bash

SCRIPT_PATH=$(readlink -f "$0")
DIRNAME=$(dirname "$SCRIPT_PATH")
[ -f ./.zshrc ] && ln -sf $DIRNAME/.zshrc ~/.zshrc
[ -f ./.tigrc ] && ln -sf $DIRNAME/.tigrc ~/.tigrc

[ -f ~/.profile ] && grep -q "export EDITOR=nvim" ~/.profile || echo "export EDITOR=nvim" >> ~/.profile
[ -f ~/.profile ] && grep -q "export GIT_EDITOR=nvim" ~/.profile || echo "export GIT_EDITOR=nvim" >> ~/.profile

apt install -y git && \
apt install -y tig && \
apt install -y curl && \
apt install -y zsh && \
apt install -y neovim && \
apt install -y autojump && \
apt clean && \
mkdir -p ~/.zsh/fzf && \
([ -d ~/.zsh/fzf/.git ] || git clone https://github.com/junegunn/fzf ~/.zsh/fzf) && \
([ -f ~/.zsh/antigen.zsh ] || curl -L git.io/antigen > ~/.zsh/antigen.zsh) && \
chsh -s $(which zsh) && \
zsh

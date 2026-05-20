#!/bin/sh

# === ANSI color codes ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

echo "\n${GREEN}${BOLD}=== Running post create tasks...${RESET}"

###
sudo apt update
sudo apt upgrade -y
sudo apt install -y build-essential software-properties-common
sudo apt install -y git cron bc curl wget zip unzip
sudo apt install -y xvfb xauth imagemagick ffmpeg jq sqlite3
sudo apt install -y python3 python3-pip
sudo apt install -y fonts-freefont-ttf fonts-liberation fonts-noto-color-emoji \
  fonts-wqy-zenhei libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libnspr4 libnss3 \
  libxcomposite1 libxdamage1 libxrandr2 libgbm1 libxkbcommon0
python3 -m pip install -U "yt-dlp[default]" boto3 graphifyy opencv-python requests

###
curl -fsSL https://claude.ai/install.sh | bash

###
mkdir -p ~/.ssh
chmod 700 ~/.ssh

echo "\n${GREEN}${BOLD}=== Bootstrap script completed successfully!${RESET}"

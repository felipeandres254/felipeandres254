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
python3 -m pip install --break-system-packages \
  requests "yt-dlp[default]" boto3 graphifyy opencv-python openai-whisper

###
curl -fsSL https://opencode.ai/install | bash
graphify install --platform opencode

###
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Restore private files from S3 (if configured)
echo "\n${BLUE}${BOLD}=== Restoring private files from S3...${RESET}"
/bin/bash /workspaces/felipeandres254/.devcontainer/scripts/backup.sh --restore

echo "\n${GREEN}${BOLD}=== Bootstrap script completed successfully!${RESET}"

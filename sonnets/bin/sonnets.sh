#!/bin/sh

export XDG_CONFIG_HOME="/etc/"
export XDG_DATA_HOME="/var/lib/"

export ANTHROPIC_API_KEY=$(systemd-creds decrypt  --name sonnets-anthropic-key      /etc/credstore/sonnets-anthropic-key.cred)
export TELEGRAM_BOT_TOKEN=$(systemd-creds decrypt --name sonnets-telegram-bot-token /etc/credstore/sonnets-telegram-bot-token.cred)
export TELEGRAM_CHAT_IDS=$(systemd-creds decrypt  --name sonnets-telegram-chat-ids  /etc/credstore/sonnets-telegram-chat-ids.cred)

BINARY_DIR="/usr/local/bin/sonnets"
exec "$BINARY_DIR" "$@"

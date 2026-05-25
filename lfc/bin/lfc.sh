#!/bin/sh

export XDG_CONFIG_HOME="/etc/"
export XDG_DATA_HOME="/var/lib/"

export LFC_API_KEY=$(systemd-creds decrypt --name lfc-api-key /etc/credstore/lfc-api-key.cred)
export LFC_EMAILS=$(systemd-creds decrypt --name lfc-emails /etc/credstore/lfc-emails.cred)
export LFC_TELEGRAM_CHAT_IDS=$(systemd-creds decrypt --name lfc-telegram-chat-ids /etc/credstore/lfc-telegram-chat-ids.cred)
export LFC_TELEGRAM_BOT_TOKEN=$(systemd-creds decrypt --name lfc-telegram-bot-token /etc/credstore/lfc-telegram-bot-token.cred)
export LFC_EMAIL_USERNAME=$(systemd-creds decrypt --name lfc-email-username /etc/credstore/lfc-email-username.cred)
export LFC_EMAIL_APP_PASSWORD=$(systemd-creds decrypt --name lfc-email-app-password /etc/credstore/lfc-email-app-password.cred)

BINARY_DIR="/usr/local/bin/lfc"
exec "$BINARY_DIR" "$@"

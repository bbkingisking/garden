#!/bin/sh

BOT_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/cue-notify")
CHAT_ID=$(cat "$CREDENTIALS_DIRECTORY/cue-chat-id")

while IFS= read -r line; do
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="🥁 New release: $line" > /dev/null
done



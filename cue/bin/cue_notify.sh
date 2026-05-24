#!/bin/sh

BOT_TOKEN=$(systemd-creds decrypt --name cue-notify /etc/credstore/cue-notify.cred)
CHAT_ID=$(systemd-creds decrypt --name cue-chat-id /etc/credstore/cue-chat-id.cred)

while IFS= read -r line; do
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="🥁 New release: $line" > /dev/null
done



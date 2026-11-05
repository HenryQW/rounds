---
title: Notifications
description: "How Rounds tells you that a session wants you: a sound on this Mac, and a message to Telegram or Bark when you are away."
---

Rounds tells you when a session goes to Needs input, Failed or Ready. Set it up in Settings, on the Notifications page.

- Sounds on this Mac: turn on Play sounds. A sound plays at once when a session comes into Your Turn. Needs input, Failed and Ready each have their own sound; pick one from the list, or None for no sound, and click Play to hear it. If more than one session comes in at the same time, Rounds plays only the most urgent sound. Sounds do not follow Focus.
- Telegram: make a bot with [@BotFather](https://t.me/BotFather) and copy its token. Send your bot a message, so that it can write to you. Your chat ID is your user ID, from [@userinfobot](https://t.me/userinfobot). In the Telegram row, click Connect… and paste the bot token and the chat ID.
- Bark: install [Bark](https://github.com/Finb/Bark) on your iPhone and copy the device key from the app. In the Bark row, click Connect… and paste the key. Change the server only if you run your own Bark server. Needs input and Failed come as time sensitive.

When you click Save, Rounds checks the values with Telegram or the Bark server first, and saves them only when they work. The checks send no message. If a value is wrong, an orange line in the sheet tells you which one.

Telegram and Bark get a message only when your Mac has had no key or pointer input for the time in Send remote messages after (2 minutes by default; 0 sends at once). A session that you open, or that changes, before then sends no message. Each event sends once. Send for sets the states that send a remote message. Send Test in the row's menu sends a test message; a failure shows in orange in the row until the next message goes through.

Privacy: Rounds sends the state, the session title, the detail and the folder name to Telegram, or to the Bark server and from there to Apple. Rounds never sends prompt text. The token, chat ID and device key stay in your Keychain.

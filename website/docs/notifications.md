---
title: Notifications
description: "How Rounds tells you that a session wants you: a banner on this Mac, and a message to Telegram or Bark when you are away."
---

Rounds tells you when a session goes to Needs input, Failed or Ready. Set it up in Settings, on the Notifications page.

- Banners on this Mac: turn on Show banners. macOS asks you to allow notifications for Rounds. A banner shows at once; a click on it opens the session. Play a sound adds a sound to Needs input and Failed. When you open the session, or its state changes, the banner goes away. If macOS does not allow banners, turn on notifications for Rounds in System Settings, Notifications.
- Telegram: make a bot with [@BotFather](https://t.me/BotFather) and copy its token. Send your bot a message, so that it can write to you. Your chat ID is your user ID, from [@userinfobot](https://t.me/userinfobot). In the Telegram row, click Connect… and paste the bot token and the chat ID.
- Bark: install [Bark](https://github.com/Finb/Bark) on your iPhone and copy the device key from the app. In the Bark row, click Connect… and paste the key. Change the server only if you run your own Bark server. Needs input and Failed come as time sensitive.

Telegram and Bark get a message only when your Mac has had no key or pointer input for the time in Send remote messages after (2 minutes by default; 0 sends at once). A session that you open, or that changes, before then sends no message. Each event sends once. Send for sets the states that send a banner or a message. Send Test in the row's menu sends a test message; a failure shows in orange in the row until the next message goes through.

Privacy: Rounds sends the state, the session title, the detail and the folder name to Telegram, or to the Bark server and from there to Apple. Rounds never sends prompt text. The token, chat ID and device key stay in your Keychain.

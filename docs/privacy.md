# SmartHomeKJ privacy policy

_Last updated: 22 November 2026_

SmartHomeKJ controls the smart devices in your home. It is built to keep your information on your own phone or computer. There are no ads, no analytics, no tracking, and nothing is sold or shared for marketing.

## What stays on your device

Everything you set up stays on the device you use, unless you choose to sign in:

- your homes, rooms, floor plans, devices, scenes, automations and settings
- the addresses, user names, passwords and keys of your devices and their connections (for example a camera's login or a Tuya key)
- the history of what switched on and off, and sensor readings for the last week
- the app's own log of errors, shown in **More → Diagnostics**

SmartHomeKJ talks to your devices directly on your home network. To find them, it looks at the devices on your Wi-Fi (their network addresses, names and the makers of their network cards). That information is used only to show and control your devices, and stays on your device.

## When information leaves your device

Only in these cases, each one something you choose:

| When | What is sent | To whom |
| --- | --- | --- |
| You **sign in or create an account** (optional) | Your email address, your password (checked by Google and never seen by SmartHomeKJ), your name if you give one, and your homes (rooms, devices and their settings, scenes). When control from anywhere is on: what your devices are doing and the commands you send them. | Google Firebase (Authentication and Realtime Database), operated by Google. Your data is readable only by your account and the people you share a home with. |
| You **add your town** for the weather | The name you search for, then the town's coordinates | Open-Meteo (open-meteo.com), which does not need an account |
| You **add a device's cloud** (Tuya, Shelly Cloud, Imou, Philips Hue, Home Assistant) | The key or login you enter, and the commands for those devices | That company or your own Home Assistant, the same as its own app would |
| The app downloaded from **GitHub** checks for a newer version (at most twice a day) | Nothing but the request itself | GitHub. Versions from Google Play, the App Store and the Microsoft Store do not do this; their store updates them. |
| You tap **Copy report** in Diagnostics | Nothing is sent. The report goes to your clipboard, for you to share if you want. | Nobody |

## Deleting your information

- **Your account:** in the app, open **More → Account → Delete account**. Your account, the homes you own and your place in homes shared with you are deleted from the cloud straight away. Only your account's random ID is kept, with no other information, so that your other devices stop syncing.
- **Everything on a device:** uninstall the app, or delete homes in **More → Homes**.
- You can also email the address below and ask us to delete your account.

## Children

SmartHomeKJ is not aimed at children under 13, and does not knowingly collect their information.

## Security

Connections to Firebase, Open-Meteo and device clouds use encryption (HTTPS). Many smart devices only offer unencrypted connections on your home network; SmartHomeKJ uses what each device supports.

## Changes and contact

If this policy changes, the new version will be published here with a new date. For any question or request about your data, contact the developer through the "Contact" address on the app's store page, or open an issue at https://github.com/SW1TF0/HomeOS/issues.

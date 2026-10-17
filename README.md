# SmartMenuKJ

<img src="docs/icon.png" alt="SmartMenuKJ icon: a dot-matrix S with a red dot on black" width="96">

A free smart home app for phones and computers. Draw your home as a floor plan, put your devices where they really are, and control them with a tap. It is styled after Nothing OS: black and white, dot-matrix type and a single red accent.

Everything is free and local-first. There is no subscription and no paywall, and no account is needed: the app talks to your devices directly on your home network, and your homes are saved on your own device. A free account is optional; it keeps your homes in step on every phone and computer and lets you switch things from anywhere.

**[Download for Android](https://github.com/SW1TF0/HomeOS/releases/latest/download/SmartMenuKJ-android.apk)** · [Windows, macOS and Linux](https://github.com/SW1TF0/HomeOS/releases/latest)

| Home | A room | Light controls | Thermostat |
| --- | --- | --- | --- |
| ![Home](docs/screenshots/phone-home.png) | ![Room](docs/screenshots/phone-room.png) | ![Light](docs/screenshots/phone-device.png) | ![Thermostat](docs/screenshots/phone-thermostat.png) |

| Floor plan | Editing the plan | Drawing a room | Editing the home screen |
| --- | --- | --- | --- |
| ![Map](docs/screenshots/phone-map.png) | ![Map editing](docs/screenshots/phone-map-edit.png) | ![Drawing a room](docs/screenshots/phone-map-draw.png) | ![Edit home](docs/screenshots/phone-home-edit.png) |

| Colour | Connections | Adding a Matter device | Light theme |
| --- | --- | --- | --- |
| ![Colour](docs/screenshots/phone-colour.png) | ![Connect](docs/screenshots/phone-connect.png) | ![Matter](docs/screenshots/phone-matter.png) | ![Light theme](docs/screenshots/phone-devices-light.png) |

| Robot vacuum | Alarm | More than one home | Account |
| --- | --- | --- | --- |
| ![Robot vacuum](docs/screenshots/phone-vacuum.png) | ![Alarm](docs/screenshots/phone-alarm.png) | ![Homes](docs/screenshots/phone-homes.png) | ![Account](docs/screenshots/phone-account.png) |

![Desktop](docs/screenshots/desktop-map.png)

## What it does

- **Floor plan.** Add a ready-made room (Kitchen, Bedroom, Garage...) and it drops into a free spot, or draw one by dragging on the dotted grid. Move rooms, resize them from any corner, duplicate or delete them, and undo any change. Devices that are not on the plan wait in a tray at the bottom: drag one into a room and it joins that room. Tap a device on the plan to switch it, hold it for full controls, tap a room to open it.
- **Controls.** Dot-matrix sliders with one-tap presets for brightness and white (Warm, Neutral, Cool, Daylight), a colour ring, a thermostat dial with Eco / Comfort / Warm, blinds you slide open, volume, locks that only open when you hold them, and sensor readings, each shown only when the device supports it. Robot vacuums and mowers get start / pause ringed by their battery, send home, stop, find and suction or cleaning mode; washers, dryers and dishwashers show what they are doing and the time left; alarms arm home / away / night and ask before disarming (the code is never saved); purifiers and fans get speed and presets, humidifiers a dial, and valves, sirens, garage doors, buttons and cameras their own controls. Drag sideways across a light's tile to dim it without opening anything.
- **Home screen.** A dot-matrix clock and a status strip (lights on, temperature inside, locks, open blinds, offline devices) where each pill opens the devices behind it, next to one button that switches everything off. Smoke, carbon monoxide and leaks show first, in red. Then your favourites and your rooms. **Edit home** picks and orders the favourites and rooms.
- **Rooms.** Tap a room on the home screen or the plan to see everything in it: one slider for all its lights, all off / lights on, every device, and a shortcut to edit the room on the plan.
- **Scenes.** Set your devices the way you like, save it as a scene ("Movie night", "Good night"...), and bring it back with one tap. Scenes can run by themselves at a time of day on chosen weekdays. On Android they run even when the app is closed (an exact alarm wakes it); on computers they run while the app is open.
- **Matter, with no hub.** SmartMenuKJ is its own Matter controller: type a device's pairing code and its lights, plugs, sensors, blinds, locks, thermostat, robot vacuum, washer, dishwasher, air purifier, water valve or smoke alarm appear, controlled directly on your network. Matter bridges (Hue, IKEA, Aqara...) bring all their devices at once.
- **Scan network.** Finds everything on your Wi-Fi that answers (mDNS, UPnP / SSDP, Kasa and Yeelight discovery, and a quick check of TV ports): TVs, speakers, plugs, lights, hubs, printers and more. Add anything in one tap, or type a device's IP address.
- **TV remote.** Power, volume, mute, channels, arrows, OK, back, home and play / pause for Samsung, LG, Sony and Roku TVs, plus volume and play / pause for Chromecast, Google TV and UPnP speakers. TVs that are fully off are woken with Wake-on-LAN.
- **More than one home.** Tap the home's name at the top of the home screen to switch homes, add one, rename, reorder or delete them. Each home has its own floor plan, devices, connections and scenes.
- **Account and control from anywhere (optional, free).** Sign in under **Connect** and your homes are saved to your account and stay in step on every device you sign in on. Most devices only answer on your home Wi-Fi, so leave one phone, tablet or computer at home with the app, signed in and plugged in, and turn on **Keep … online from this device** there. Your other devices then switch things through it from anywhere; the home screen shows *Away · through …* when they do. On Android it keeps running in the background with a small notification.
- **Backups.** Copy your whole home (rooms, devices, connections) as text and paste it back on another phone or computer.
- **Light and dark themes**, phone layout with a bottom bar, desktop layout with a side rail.

## Which devices work

No app can speak every protocol on its own, so SmartMenuKJ combines direct local control of the most common open systems with bridges that already cover thousands of brands.

| Connection | What it reaches | How |
| --- | --- | --- |
| **Matter** | Matter lights, plugs, switches, sensors, blinds, thermostats, locks, fans, air purifiers, robot vacuums, washers, dryers, dishwashers, water valves, smoke and CO alarms and air quality sensors, and everything behind a Matter bridge (Hue, IKEA, Aqara, SwitchBot...) | SmartMenuKJ is its own Matter controller: add a device with its pairing code and it is controlled directly on your network. No hub, cloud or account |
| **Home Assistant** | Anything Home Assistant supports: Matter and Thread, Zigbee (ZHA), Z-Wave, Google Nest, Sonos, IKEA, Xiaomi, Tuya, TP-Link, Roborock, Ecovacs, iRobot, thermostats, locks, alarms, cameras, media players and more | Its REST API with a long-lived access token |
| **MQTT & Zigbee2MQTT** | Over 4,000 Zigbee devices through Zigbee2MQTT, plus anything that uses Home Assistant MQTT discovery (Tasmota, ESPHome, Shelly, Valetudo robots, OpenMQTTGateway...), including vacuums, mowers, valves, sirens and buttons, plus any device you describe by topic | Any MQTT broker, live updates |
| **Network devices** | Samsung (Tizen), LG (webOS), Sony Bravia and Roku TVs; Chromecast, Google TV and Nest speakers; UPnP / DLNA TVs, speakers and receivers (Sonos and others); TP-Link Kasa plugs, strips and bulbs; Yeelight; Belkin WeMo. Anything else shows as online / offline and can be woken with Wake-on-LAN | Each device's own local protocol. Samsung and LG TVs ask once on screen to allow the app; Sony TVs need a pre-shared key set under IP control |
| **Valetudo** | Robot vacuums running the cloud-free Valetudo firmware (Roborock, Dreame, Viomi...) | Its local REST API, found by Scan network |
| **Philips Hue** | Hue lights and plugs | The bridge's local API. Press the link button, tap Pair |
| **Shelly** | Gen1, Plus, Pro, Gen3 and Gen4 relays, plugs, dimmers, shutters and H&T sensors | Local HTTP / RPC |
| **Tasmota** | Plugs, bulbs, switches and sensors with Tasmota firmware | Local HTTP commands |
| **WLED** | LED strips and lamps | Local JSON API |
| **ESPHome** | Lights, switches, fans, covers, locks and sensors | The `web_server:` component |
| **Virtual devices** | Placeholders for trying the app or planning before you buy | Built in |

**Matter:** the device has to be on your network already. If it is set up in Google Home, Apple Home, SmartThings or Alexa, open it there and choose *Linked Matter apps* (or *Turn on pairing mode*) to get a new pairing code, then type it in **Connect → Matter** or **Devices → Add device**. It stays in the other app too. Brand-new devices that join Wi-Fi over Bluetooth need to be set up once in another Matter app first; SmartMenuKJ cannot do Bluetooth setup yet.

New device families are added by writing one driver class in `lib/integrations/` and listing it in `lib/integrations/catalog.dart`.

## Getting the app

Builds are made for free by GitHub Actions (`.github/workflows/build.yml`):

- Every push to `main` builds an Android APK, a Windows zip, a Linux tarball and a macOS app, attached to the workflow run under **Artifacts**.
- Pushing a tag such as `v1.0.0`, or running the workflow by hand with a version, also publishes them on the **Releases** page.
- Android builds are signed with the app's own key, which `tool/android_key.py` makes from the `ANDROID_SIGNING_SECRET` repository secret (any text of 16 or more characters), the same key every time. So each version installs over the last one and keeps your home. Without the secret they get a one-off debug key and do not install over other versions.

The macOS app is not signed, so the first time you open it, right-click it and choose Open. iPhone builds need an Apple developer account to sign, so for now build them yourself with Xcode (`flutter build ios`).

### Build it yourself

1. Install [Flutter](https://docs.flutter.dev/get-started/install) (stable channel).
2. `flutter pub get`
3. Run it: `flutter run` (pick a phone, emulator, or `-d windows` / `-d macos` / `-d linux`).

## First steps in the app

1. The app opens with a sample home of virtual devices so you can try everything right away. Delete or move anything you like.
2. Go to **Connect** and tap **Scan network**, or pick a connection and type its address.
3. New devices appear on the **Devices** tab. Open **Map** and tap **Edit**: new devices wait in the tray at the bottom, drag each one into its room.
4. To control your home when you are out, tap **Sign in** on **Connect**, create an account, and on a device that stays at home turn on **Keep … online from this device**.

## For developers

```
lib/
  models/         Device, room, floor and home data (JSON)
  integrations/   One driver per system + catalog + network scan
  state/          HomeStore (all changes go through it), local storage, sample home
  cloud/          Accounts, sync and remote control over Firebase (REST, no SDK)
  theme/          Nothing-style colours and type
  ui/             Screens and shared widgets
test/             Model, driver, store and widget tests
tool/             Screenshot generator
firebase/         Database rules and emulator settings
```

- `flutter analyze` and `flutter test` run on every pull request.
- `flutter test tool/screenshots_test.dart --update-goldens` regenerates the screenshots in `docs/screenshots/`.
- `firebase emulators:exec --only auth,database --config firebase/firebase.json "FIREBASE_EMULATOR=1 flutter test test/firebase_emulator_test.dart"` checks accounts, sync and the database rules against the real Firebase emulators.
- `python3 tool/make_icons.py` redraws the app icon for every platform (needs Pillow).

### Accounts (Firebase)

Accounts use a free Firebase project (Spark plan) through its REST APIs: Email/Password sign-in and the Realtime Database. To use your own project, turn those two on, paste `firebase/database.rules.json` under **Realtime Database → Rules**, and build with `--dart-define=FIREBASE_API_KEY=... --dart-define=FIREBASE_DATABASE_URL=https://....firebasedatabase.app`. The rules let each account read and write only the homes it belongs to.

What is stored: the layout of each home (floors, rooms, devices, scenes, and connections with their addresses, tokens and passwords, so your other devices can use them too), its name, which device keeps it online, and while one does, what the devices are doing and the commands sent through it. Alarm codes are never stored.

## Credits and licences

- App code: MIT licence, see `LICENSE`.
- [Doto](https://fonts.google.com/specimen/Doto) and [Space Grotesk](https://fonts.google.com/specimen/Space+Grotesk) fonts: SIL Open Font License, see `assets/fonts/`.
- SmartMenuKJ is an independent project. It is inspired by Nothing's design language and is not affiliated with or endorsed by Nothing Technology, Philips Hue, Shelly or any other brand named here.

# Releasing SmartHomeKJ

Where each version goes and how. The **Build apps** workflow builds everything on GitHub; the stores then take
their package from there (or, for Apple, from your Mac).

| Where | Package | Built by | Updates |
| --- | --- | --- | --- |
| GitHub Releases | `.apk`, iPhone `.ipa` (unsigned), Windows `.zip`, macOS `.zip`, Linux `.tar.gz` | Build apps, on a `v*` tag | The app checks GitHub |
| Google Play | `SmartMenuKJ-play.aab` | Build apps (artifact) | Google Play |
| Microsoft Store | `SmartMenuKJ-msstore.msix` | Build apps (artifact) | Microsoft Store |
| Apple App Store (iPhone, iPad) | `.ipa` | Your Mac: `./tool/release_apple.sh` | App Store |

Store versions are built with `--dart-define=STORE=play|msstore|appstore`. That turns off the GitHub update
check and the download links, which every store requires. Release builds are obfuscated; the symbols to read
their crash stacks are kept as the private `symbols-*` artifacts of each run
(`flutter symbolize -i stack.txt -d app.android-arm64.symbols`).

## Every release

1. Raise `version:` in `pubspec.yaml` (for example `1.22.0+25`: the part after `+` must go up every time, the
   stores refuse a number they have seen) and `appVersion` in `lib/app_info.dart`.
2. Check the pull request is green on Windows, macOS, Linux, Android and iOS, then merge it.
3. Tag it: `git tag v1.22.0 && git push origin v1.22.0`. **Build apps** publishes the GitHub release and keeps the
   store packages as artifacts of that run (Actions → Build apps → the run → Artifacts).
4. Upload each store package as below.

## Once: the Firebase API key

The key is not in the code. Add it as the repository secret **FIREBASE_API_KEY** (GitHub → Settings → Secrets and
variables → Actions), and on each computer that builds the app copy `firebase.local.example.json` to
`firebase.local.json` (git ignores it) and paste the key in. `./flutterw run` and `./flutterw build` read it. Without
it the app builds and works, with no account or cloud.

In Google Cloud Console → APIs & Services → Credentials, restrict the key to the Identity Toolkit and Firebase
Realtime Database APIs, so a copy of it is no use for anything else.

## Once: the Firebase database rules

Account deletion adds rules that stop a deleted account's other devices from saving again. Paste
`firebase/database.rules.json` into **Firebase console → Realtime Database → Rules** and tap **Publish**. Until
then, deleting an account still works, without that extra protection.

## Google Play

**Once**
1. Make a Google Play developer account (one-time fee) and create the app. Package name:
   `com.smartmenukj.smartmenukj`.
2. App signing: choose **Use Google-generated key** and upload the app's upload certificate. The bundle is signed
   with the same key as the GitHub APK (from the `ANDROID_SIGNING_SECRET` secret), so Play accepts it as the upload
   key.
3. Store listing: text from `docs/store/listing.md`, screenshots from `docs/screenshots/`, icon
   `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` (resize to 512×512).
4. **Privacy policy URL:** `https://github.com/SW1TF0/HomeOS/blob/main/docs/privacy.md`
5. **Data safety** form (the answers match docs/privacy.md):
   - Data collected: **Email address** and **Name** (optional; account management), **Other user-generated
     content**: homes and device settings (optional; app functionality). Encrypted in transit: yes. Users can ask
     for deletion: yes (in the app).
   - No data shared with third parties; no ads; no analytics.
   - Account deletion URL: the privacy policy (section "Deleting your information").
6. **Foreground service** declaration: type `connectedDevice`. Reason: "When the user turns on *Keep this home
   online* on a device that stays at home, the app keeps running to pass commands from the user's other devices to
   the smart devices on the home network. A notification shows while it runs." Add a short video of turning it on
   in More → Account.
7. **Exact alarms:** the app asks for *Alarms & reminders* (SCHEDULE_EXACT_ALARM) only for scenes the user times;
   it is not USE_EXACT_ALARM, so no declaration is needed.

**Each release:** Play Console → Production (or Internal testing first) → Create release → upload
`SmartMenuKJ-play.aab`.

## Microsoft Store

**Once**
1. Make a Microsoft Partner Center account and reserve the name **SmartHomeKJ**.
2. Product identity (Partner Center → the app → Product identity): add two repository secrets on GitHub,
   `MSSTORE_IDENTITY_NAME` (Package/Identity/Name) and `MSSTORE_PUBLISHER` (Package/Identity/Publisher, starts with
   `CN=`). The next Build apps run makes the package with them.
3. Privacy policy URL as above. Capabilities used: Internet, home and work networks (to reach devices).

**Each release:** Partner Center → New submission → Packages → upload `SmartMenuKJ-msstore.msix`. The Store signs
it.

## Apple App Store

Apple apps are signed with your own Apple certificates, so they are built and uploaded from your Mac.

**Once**
1. Join the Apple Developer Program (yearly fee). In App Store Connect create the app with bundle ID
   `com.smartmenukj.smartmenukj`.
2. Open `ios/Runner.xcworkspace` in Xcode → Runner → Signing & Capabilities → pick your **Team** (automatic
   signing).
3. **Multicast networking:** finding devices on the Wi-Fi (mDNS, UPnP, the network scan) sends multicast, which iOS
   allows only with the `com.apple.developer.networking.multicast` entitlement. Request it at
   https://developer.apple.com/contact/request/networking-multicast (explain: "a smart home controller that finds
   the user's lights, plugs and TVs on the home network"). Once approved, add **Multicast Networking** under
   Signing & Capabilities. Without it the app still controls devices added by address or through a hub, but the
   scan finds less.
4. App Privacy in App Store Connect: **Contact info → Email address** and **Name** and **User content → Other**,
   all linked to the user, used for app functionality, not for tracking. Privacy policy URL as above.
5. App Review notes: "The app controls smart devices on the user's home network. To try it without devices, it
   opens with a sample home of virtual devices. An account is optional (More → Account) and can be deleted in the
   app (More → Account → Delete account)."

**The iPhone `.ipa` on GitHub Releases** is built by Build apps without signing, since that needs your Apple
certificate. People install it with a sideloading app (AltStore or Sideloadly), which signs it with their own Apple
ID. A free Apple ID's signature lasts 7 days, and the sideloading app renews it. The App Store version below is
separate and signed by you.

**Each release:** `./tool/release_apple.sh`, then upload the `.ipa` it names with the **Transporter** app (free, Mac
App Store), or `xcrun altool --upload-app`. Submit it for review in App Store Connect.

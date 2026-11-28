# Install apps on your iPhone with no computer

GitHub signs the IPA with your Apple Developer account and puts it on your own install
page. You open the page in Safari and tap **Install**. Apps keep working for about a year.
There's no 7-day refresh and no 3-app limit.

Everything below is done on the iPhone. Steps 1–6 are one-time setup.

## 1. Join the Apple Developer Program ($99/year)
Get the **Apple Developer** app from the App Store, then go to **Account › Enroll Today**.
Approval can take up to 2 days. Wait for the "Welcome" email before step 3.

## 2. Find your iPhone's UDID
Apple needs this ID to allow installs on your phone. iOS doesn't show it in Settings, so:
1. In Safari, go to **udid.tech** and tap **Get UDID**. This is a free third-party site. Its
   profile only reads your phone's ID and model.
2. Open **Settings**, tap **Profile Downloaded**, then **Install**.
3. Safari reopens and shows your UDID (it looks like `00008150-001A2B3C4D5E6F70`). Copy it.

## 3. Make an App Store Connect API key
This lets GitHub make your certificate and profiles for you.
1. In Safari, go to **appstoreconnect.apple.com** and sign in.
2. Go to **Users and Access › Integrations › App Store Connect API**. The first time,
   tap **Request Access** and accept.
3. Under **Team Keys**, tap **+**. Use the name `Signer`, access **Admin**, then **Generate**.
4. Copy the **Issuer ID** (at the top) and the **Key ID** (in the list) into Notes.
5. Tap **Download API Key**. Apple only lets you download it **once**. It saves to
   Files › Downloads as `AuthKey_XXXX.p8`.
6. You need the key's text. In Files, tap and hold the file, choose **Rename**, change
   `.p8` to `.txt`, then open it. Select all the text, including the `-----BEGIN` and
   `-----END` lines, and copy it.

## 4. Make this repository public
Your iPhone downloads the app without your GitHub login, so the files must be public.
On github.com in Safari (use **Request Desktop Website** if a menu is missing), open
**Settings › General › Danger Zone › Change visibility › Public**.

Your Apple key and other secrets stay hidden. Signed apps only install on your own
iPhone. Everything else in the repo, including its history, becomes visible to anyone.

## 5. Add the secrets
Go to **Settings › Secrets and variables › Actions › New repository secret** and add four:

| Name | Value |
| --- | --- |
| `ASC_ISSUER_ID` | Issuer ID from step 3 |
| `ASC_KEY_ID` | Key ID from step 3 |
| `ASC_PRIVATE_KEY` | The whole key text from step 3 |
| `DEVICE_UDID` | Your UDID from step 2 (for more than one iPhone, separate them with commas) |

## 6. First signing and the install page
1. Go to **Actions › Sign IPA › Run workflow** and tap **Run workflow**. Leave the link
   empty to sign the newest Manic EMU build.
2. When it finishes (about 5 minutes), open **Settings › Pages**. Set **Source** to
   **Deploy from a branch**, set **Branch** to `apps` and `/ (root)`, then tap **Save**.
3. After a minute, your page is at
   **https://duhdawgg.github.io/manic-emu-QoL-changes/**. Open it in Safari, tap Share,
   then **Add to Home Screen**.

## Installing
- Tap **Install** on the page, then **Install** on the pop-up. The app appears on your
  Home Screen.
- **First app only:** open **Settings › Privacy & Security › Developer Mode**, turn it on,
  let the phone restart, and tap **Turn On**. This is needed because apps are signed for
  development, which also lets emulators use JIT later. If you'd rather skip Developer
  Mode, choose `adhoc` when you run the workflow.
- If the run shows a yellow warning about **EXTENDED_VIRTUAL_ADDRESSING** or
  **INCREASED_MEMORY_LIMIT**, Apple's API wouldn't turn that switch on. Turn it on by hand
  at developer.apple.com: **Account › Identifiers**, pick the app, tick the box, tap
  **Save**, then run the workflow again. Emulators need it for 3DS games.

## Signing other IPAs
Run **Sign IPA** and paste a link to the IPA (it must start with `https://`). For an IPA
that's only in your Files app, upload it first: on GitHub, go to **Releases › Draft a new
release**, attach the IPA, publish, and copy the file's link.

The app gets a new bundle ID (its usual ID plus your team ID). This means it installs
next to the App Store version instead of replacing it.

## Automatic Manic EMU builds
Once the secrets are set, every `[build]` commit is also signed and added to the page.

## How it works
- `.github/workflows/sign-ipa.yml` runs `Scripts/signer/prepare.py`. That script uses
  Apple's App Store Connect API to make the certificate, register your iPhone and bundle
  IDs, and create fresh profiles. Then [zsign](https://github.com/zhlynn/zsign) (pinned
  to v1.1.3) signs the IPA, and `Scripts/signer/publish.py` updates the page.
- The certificate's private key is stored encrypted on the `signing-state` branch. It can
  only be decrypted with the `ASC_PRIVATE_KEY` secret. If it's lost, a new certificate is
  made automatically.
- Signed IPAs go in the `signed-apps` release. The page and install manifests are on the
  `apps` branch.

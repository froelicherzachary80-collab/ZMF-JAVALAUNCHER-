# Building, downloading and installing (iPhone only, no Mac needed)

## 1. Get the IPA

Every push runs **Build IPA** on a GitHub-hosted macOS runner with Xcode.

* **Easiest on iPhone:** open the repository's **Releases** page in Safari and
  download `ZMFJavaLauncher-v0.1.ipa` from the `latest-build` pre-release.
  This is a direct file download.
* Alternatively: **Actions → Build IPA → latest run → Artifacts →
  ZMFJavaLauncher-v0.1-ipa**. GitHub wraps artifacts in a `.zip`; open it in
  the Files app to extract the `.ipa`. (Artifact downloads require being
  signed in to GitHub.)

To rebuild manually: Actions → Build IPA → *Run workflow* (you can also paste
runtime component URLs there, see [RUNTIME.md](RUNTIME.md)).

## 2. Sign and install with Signulous

The CI IPA is **unsigned** (no Apple certificate is stored in the repo).
Signulous signs it with your registered device's certificate:

1. In Signulous, register your iPhone's UDID (done when you subscribed).
2. Open the Signulous dashboard → **Upload IPA** (or "Sign an IPA") and pick
   `ZMFJavaLauncher-v0.1.ipa` from Files.
3. Sign it and tap **Install**. iOS shows the install prompt.
4. iOS 16+: enable **Settings › Privacy & Security › Developer Mode** if
   prompted, then restart.
5. Open **ZMF Java**.

### Entitlement and compatibility limitations

* **JIT:** signing does not enable JIT. See RUNTIME.md; a debugger-based JIT
  enabler is required for usable performance.
* **Increased memory limit:** only if Signulous's certificate/profile supports
  `com.apple.developer.kernel.increased-memory-limit`; ZMF does not declare it
  because a profile lacking it would make the install fail.
* **LAN discovery:** the game's automatic LAN world discovery uses multicast,
  which needs Apple's restricted multicast entitlement. Join LAN worlds by IP
  instead (iOS asks for Local Network permission on first connection).
* **Microsoft sign-in:** requires an Azure app (client) ID approved for
  Minecraft services. Enter it in Settings › Account › Microsoft application,
  or set the repository variable `ZMF_MSA_CLIENT_ID` before building.
  Redirect URI: `zmflauncher://auth` (Mobile and desktop application platform).
* Bundle ID `dev.zmf.javalauncher` may be changed by the signing service; this
  does not affect the app.

## 3. Optional: CI signing with your own certificate

Add these repository **secrets** and CI will also produce
`ZMFJavaLauncher-v0.1-signed.ipa`:

* `IOS_CERT_P12_BASE64` — base64 of a development/ad-hoc `.p12`
* `IOS_CERT_PASSWORD` — its password
* `IOS_PROFILE_BASE64` — base64 of a matching `.mobileprovision` that
  includes your device

## 4. First run

1. Settings › Account → sign in with Microsoft (owns Java Edition).
2. Installations → New profile (Vanilla or Fabric) → Save.
3. Home → **Play** installs and verifies the version files from Mojang.
4. If runtime components are not embedded, Play lists exactly what is
   missing instead of starting (no fake frames).
5. Settings › Controls Lab lets you try the touch controls and see the Java
   input events they produce without a game running.

# Publishing ZMF Java Launcher

## Where it can be distributed

| Channel | Possible? | Notes |
|---|---|---|
| **GitHub Releases** | Yes (set up) | Tag `vX.Y.Z` → versioned release with IPA, `SHA256SUMS.txt`, `altstore-source.json`. Every push also refreshes the `latest-build` pre-release. |
| **AltStore / SideStore source** | Yes (set up) | Users add `…/releases/latest/download/altstore-source.json` and get updates in-app. |
| **Signing services** (Signulous etc.) | Yes | Users upload the unsigned IPA. |
| **AltStore PAL / EU alternative marketplaces** | Maybe | Requires Apple notarization; Apple may reject apps that download and run code. Not attempted. |
| **Apple App Store / TestFlight** | No | App Review guideline 2.5.2 forbids downloading and executing code, and JIT is unavailable to App Store apps. |

## Cutting a release

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The `Build IPA` workflow builds with `MARKETING_VERSION` = the tag, publishes
the release (tags with a `-`, e.g. `v0.3.0-beta.1`, become pre-releases, which
`releases/latest` skips), and attaches the AltStore source. Release text comes
from `docs/RELEASE_NOTES.md`.

## Microsoft sign-in for the public

Builds ship the public client ID from `project.yml` (override with the
repository variable `ZMF_MSA_CLIENT_ID`). Users never need their own ID.
Until Microsoft approves that ID for Minecraft (https://aka.ms/mce-reviewappid),
everyone's sign-in stops at "waiting for Microsoft approval". Point the review
form at this repository and its releases page: a public project page with a
privacy policy (`PRIVACY.md`) is what reviewers look for.

## Voice relay for the public

Public users need a relay URL. Host one (`voice-relay/`, container image
`ghcr.io/<owner>/zmf-voice-relay`, or `voice-relay/render.yaml`) and set the
repository variable `ZMF_VOICE_RELAY_URL` so it is the default in every
build. Users can still enter their own.

## Rules to keep following

* Never put "Minecraft" in the app name or use Mojang logos/screenshots as
  the icon; keep the "not an official Minecraft product" notice (`NOTICE.md`,
  Settings, release notes).
* Never ship Minecraft game files; the launcher downloads them per user.
* If a build embeds OpenJDK, OpenAL Soft or other copyleft components,
  publish their licenses and source links with that release (`NOTICE.md`).
* Keep `PRIVACY.md` accurate if you change what the app or relay collects.

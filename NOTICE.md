# Notices

**ZMF Java Launcher is not an official Minecraft product. It is not approved by
or associated with Mojang or Microsoft.** "Minecraft" is a trademark of Mojang
Synergies AB. The app ships no Minecraft game files or assets; players
download the game from Mojang's servers with their own licensed account.

## Third-party components

The default IPA contains only ZMF's own code plus Apple system frameworks.

| Component | Where | License |
|---|---|---|
| JNI headers (`jni.h`, `jni_md.h`) from OpenJDK, used at build time | `Native/Generated/jni` (not committed) | GPLv2 with Classpath Exception |
| `ws` (voice relay dependency, server side only) | `voice-relay` | MIT |

If a build embeds optional runtime components (`scripts/fetch-components.sh`),
their licenses apply to that build and must be published with it:

* OpenJDK runtime builds — GPLv2 with Classpath Exception (offer the
  corresponding source, e.g. a link to the exact build's source).
* LWJGL — BSD-3-Clause. GL4ES — MIT. ANGLE — BSD-3-Clause. OpenAL Soft — LGPL-2.1
  (dynamic linking; ship its license and a source link).

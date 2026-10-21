# Privacy

ZMF Java Launcher has no analytics, no ads and no ZMF account system.

**Sign-in.** You sign in on Microsoft's own page. The resulting tokens are
stored only in this device's Keychain and are sent only to Microsoft, Xbox
Live, Mojang/Minecraft services, and the Minecraft servers you join, exactly
as with the official launcher.

**Game files.** Downloaded from Mojang (and from Fabric/Quilt/Modrinth
when you choose mods or modpacks). Stored under Files › ZMF Java.

**ZMF Voice** (only when you connect to a relay):
* The relay operator receives your Minecraft username and UUID (verified via
  Mojang's session server — your access token is **not** sent to the relay),
  the server address and dimension you are in, your in-game position and
  facing, room names you create or join, and your voice audio while you talk.
* The reference relay keeps all of this in memory only, does not record
  audio, and forgets everything when you disconnect. A relay run by someone
  else may behave differently — only connect to relays you trust.
* The microphone is used only while ZMF Voice is connected, and audio is only
  transmitted while push-to-talk is held or voice activation detects speech.

**Logs** stay on your device (Files › ZMF Java › ZMF › logs) and never
contain your access token.

# Flect

An AirPlay receiver for the Mac, made for classrooms. Mirror an iPad to the
teacher's Mac, and from there to the room's Apple TV or projector.

Free and open source (GPL-3.0), funded by value for value: use it for
nothing, and pay what it's worth if it helps your school.

## What works

- iPad and iPhone screen mirroring, decoded in hardware by macOS itself
- Up to twelve devices side by side (four by default), each labelled with its name; click one to enlarge it
- The iPad's sound (AAC-ELD while mirroring, Apple Lossless for music). With several devices you hear the enlarged one, or else the first to connect
- Silence one iPad, or all sound, with a click
- Save what an iPad is showing as a PNG in Pictures ▸ Flect (needs macOS 14.4)
- An optional four-digit code, shown big on screen, so only people in the room can connect
- Full screen, and controls that fade away so the class sees only the iPad
- The display stays awake while mirroring
- One self-contained app: nothing else to install

Tested with four devices mirroring to one Mac at once, on macOS 27 (more than four hasn't been tried yet).
Flect needs macOS 14 or later.

## Using it

1. Open Flect. The first time, allow it to find devices on your local network.
2. On the iPad, open Control Centre, tap **Screen Mirroring**, and choose **Flect – *your Mac's name***.
3. Move the pointer over the picture for **Disconnect** and **Full Screen**.

When several iPads mirror at once they appear side by side, each labelled
with its name. Click one to enlarge it (and hear it); click again, or press
⌘0, to show them all. Hover over an iPad for its buttons: silence it, save a
snapshot of it, enlarge it or disconnect it. With more than four, each iPad
sends a smaller picture so the Wi-Fi keeps up.

⌘S saves a snapshot of the enlarged iPad (or the only one), and ⇧⌘M silences
everything.

**Flect → Settings** changes the name iPads see (a room name works well),
how many can show at once, the on-screen code, and whether the iPad's sound
plays on the Mac.

To show the iPad on the class TV, mirror the Mac to the Apple TV as usual
(Control Centre on the Mac → Screen Mirroring), and put Flect in full screen.

### If the iPad can't see Flect

- The iPad and the Mac must be on the same network. Many school networks keep
  devices apart, or block Bonjour between network segments. Ask IT to allow
  Bonjour/mDNS between them: Apple TVs need exactly the same thing.
- Check **System Settings → Privacy & Security → Local Network**: Flect must be on.
- If the Mac appears twice, the other entry is macOS's own AirPlay Receiver
  (**System Settings → General → AirDrop & Handoff**). You can switch it off
  to avoid confusion.

## Installing on school Macs

`scripts/package.sh` makes two files in `dist/`. Both run on Apple silicon
and Intel Macs with macOS 14 or later:

- **`Flect-<version>.pkg`**: an installer that puts Flect in /Applications, for IT to push with Jamf, Mosyle or another MDM.
- **`Flect-<version>.zip`**: the app on its own.

Flect isn't signed with an Apple Developer ID yet, so:

- **Pushed by IT through an MDM**, it usually installs and opens without warnings. Some MDM install methods only accept signed packages; use one that runs the installer through the MDM's own agent, such as a Jamf policy.
- **Opened by hand** (zip or pkg), macOS blocks it the first time. Within the hour, go to **System Settings → Privacy & Security** and click **Open Anyway**. This needs an administrator password, and each new version needs it again.

The first time each teacher opens Flect, macOS asks whether it may use the
local network: it must be allowed. If the Mac's firewall asks about incoming
connections, allow those too.

## Building

You need Xcode 16 or later.

```bash
scripts/build-openssl.sh
```

```bash
scripts/package.sh
```

The first command builds OpenSSL (a few minutes, once). The second builds the
universal app and both installers. For quick builds for this Mac only,
`scripts/build-app.sh` works with Homebrew's OpenSSL too
(`brew install openssl@3`).

```bash
swift test
```

The tests push real H.264/H.265 video and AAC-ELD/ALAC audio through Flect's
pipelines and talk to the AirPlay server over loopback, so most problems
show up without an iPad.

With a Developer ID, set `FLECT_SIGN_IDENTITY` before packaging, then sign
the .pkg and notarize both files.

## How it fits together

| Folder | What's there |
|---|---|
| `Sources/AirPlayCore/uxplay` | [UxPlay](https://github.com/FDH2/UxPlay)'s AirPlay protocol library, plus the patch in `patches/` |
| `Sources/AirPlayCore/libplist` | libplist 2.7.0, unmodified |
| `Sources/AirPlayCore/bridge` | `flect_receiver.h`: the small C interface Flect uses |
| `Sources/FlectKit` | Receiver, video (VideoToolbox) and audio (AudioToolbox, AVAudioEngine) |
| `Sources/Flect` | The SwiftUI app |

UxPlay does the hard part: the AirPlay protocol, pairing and decryption.
Flect swaps UxPlay's GStreamer windows for macOS's own decoders and builds a
Mac app around them. UxPlay serves one device at a time, so
`patches/uxplay-multiple-clients.patch` lets several connect at once, each
with its own callbacks. `scripts/vendor.sh` refreshes the UxPlay and
libplist copies and reapplies the patch; see `THIRD_PARTY_NOTICES.md` for
credits and licences.

## Next

- The teacher approves each iPad before it appears
- Signed, notarized downloads (needs an Apple Developer ID)
- Plain-English network diagnostics

## Supporting Flect

Flect is free for every school, whatever you pay. If it earns its place in
your classroom, give back what it's worth to you: money, bug reports,
translations or code. How to pay (including by invoice, for schools that
can't make donations) is still being set up.

## Licence

GNU General Public License v3.0 or later. See `LICENSE` and
`THIRD_PARTY_NOTICES.md`.

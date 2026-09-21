# Third-party code in Flect

Flect as a whole is distributed under the GNU General Public License,
version 3 or later (see `LICENSE`). It includes the following work by
others, under licences compatible with the GPL v3.

| Component | Where | Licence | Upstream |
|---|---|---|---|
| UxPlay AirPlay library | `Sources/AirPlayCore/uxplay` | GPL-3.0 (project); individual files LGPL-2.1+ or MIT, as marked | https://github.com/FDH2/UxPlay |
| playfair (FairPlay handshake) | `Sources/AirPlayCore/uxplay/playfair` | GPL-3.0 | via UxPlay |
| llhttp | `Sources/AirPlayCore/uxplay/llhttp` | MIT, © Fedor Indutny | https://github.com/nodejs/llhttp |
| csrp (SRP pairing) | `Sources/AirPlayCore/uxplay/srp.c`, `srp.h` | MIT, © Tom Cocagne | https://github.com/cocagne/csrp |
| libplist 2.7.0 | `Sources/AirPlayCore/libplist` | LGPL-2.1-or-later | https://github.com/libimobiledevice/libplist |
| OpenSSL 3 (libcrypto, linked statically) | build-time dependency | Apache-2.0 | https://www.openssl.org |

## Credits

The AirPlay protocol work in Flect is UxPlay's. UxPlay is maintained by
F. Duncanh (it began as antimof's UxPlay) and builds on:

- [RPiPlay](https://github.com/FD-/RPiPlay) by Florian Draschbacher
- [AirplayServer](https://github.com/dsafa22/AirplayServer) by dsafa22
- [shairplay](https://github.com/juhovh/shairplay) by Juho Vähä-Herttua
- [playfair](https://github.com/EstebanKubata/playfair)
- many other contributors, named in the source file headers

Flect replaces UxPlay's GStreamer renderers with macOS's own video and
audio frameworks, and adds the app around them.

## Keeping the copies current

`scripts/vendor.sh` records exactly which UxPlay commit and libplist
release are included (see `Sources/AirPlayCore/uxplay/VERSION` and
`Sources/AirPlayCore/libplist/VERSION`), and refreshes them unmodified.

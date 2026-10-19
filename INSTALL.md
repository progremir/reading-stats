# Install guide (for an agent)

Follow this top to bottom to set up reading-stats for someone: their e-reader running KOReader
syncs reading time and highlights to a server they own, viewable on the web and in iPhone widgets.

You need the user for a few physical steps (plugging in the e-reader, tapping on it). Everything
else you can do yourself. Stop and ask when a step says **Ask**.

## 0. Gather facts first

**Ask** the user, and write down the answers:

1. Which e-reader? Kindle, Kobo, PocketBook or Android/Boox. If it's a Kindle: the model and the
   exact firmware version (Settings → Device Options → Device Info), or plug it in and read
   `system/version.txt` from the drive; the serial number's first 6 characters identify the model.
2. Is KOReader already installed? (On a Kindle that means it's already jailbroken.)
3. Do they have a Railway account (and is the `railway` CLI logged in: `railway whoami`)?
4. Do they want a custom domain? If so, where is its DNS (e.g. Cloudflare)?
5. Do they want the iPhone widget? That needs a Mac with Xcode and an Apple Developer team ID.
6. Their time zone (IANA name, e.g. `Europe/Berlin`), used for "today" and streaks.

Where the e-reader mounts: macOS `/Volumes/Kindle` (or `/Volumes/KOBOeReader`), Linux
`/media/$USER/Kindle`. Paths below write `$DEVICE` for it.

## 1. Get KOReader onto the device

Skip if KOReader is installed.

- **Kobo / PocketBook / Android**: follow the official install guide for that platform from
  https://github.com/koreader/koreader/wiki. No jailbreak is needed.
- **Kindle**: it must be jailbroken first, and the right method depends on the exact firmware.
  1. Open https://kindlemodding.org/jailbreak-wizard.html and pick the method for the model and
     firmware. Read that method's page fully; methods change as Amazon patches them.
  2. Firmware 5.19.6 and later may have no working method. If the wizard has none, stop and tell
     the user rather than trying anything else.
  3. Follow the method's own Wi-Fi instructions exactly (some need Wi-Fi on until the end; others
     want airplane mode). Copying the jailbreak file to `$DEVICE/documents/` is usually your part;
     opening it on the device is the user's.
  4. After it reports success, KPM (the package manager) is installed. Have the user type in the
     Kindle home screen search bar: `;kpm update`, then `;kpm install koreader`.
  5. Updates: the jailbreak usually installs update blocking. Confirm with the method's page.
- Have the user open KOReader once and then exit it (menu → Exit). KOReader writes its settings
  file on first run, and the next steps need it.

On a Kindle, the USB drive does **not** mount while KOReader is running. If the Mac sees the
device on USB (`ioreg -p IOUSB` / `lsusb`) but no drive appears, the user must exit KOReader.

## 2. Deploy the server

From the repo root:

```sh
railway init --name reading-stats          # or link an existing project
railway add --service web
openssl rand -base64 18 | tr -d '/+=' | cut -c1-20 > .password      # git-ignored
openssl rand -hex 24 > .widget-token                                # git-ignored
railway variable set --service web --skip-deploys \
  AUTH_USER=reader AUTH_PASSWORD="$(cat .password)" \
  SESSION_SECRET="$(openssl rand -hex 32)" WIDGET_TOKEN="$(cat .widget-token)" \
  TZ_NAME=<their IANA time zone> DATA_DIR=/data
railway volume add -m /data                 # stats and highlights live here; without it a deploy wipes them
railway up --detach
railway domain                              # prints the *.up.railway.app URL
```

Wait for the deployment to reach SUCCESS (`railway deployment list --json`), then verify with
`$SERVER` set to the URL:

```sh
curl -s -o /dev/null -w "%{http_code}\n" $SERVER/healthz                                  # 200
curl -s -o /dev/null -w "%{http_code}\n" -u "reader:$(cat .password)" -X PROPFIND $SERVER/dav/koreader/   # 207
```

Optional, recommended: push the repo to a private GitHub repo and connect it as the service's
source (Railway MCP `connect-service-source`, or the dashboard). Every push to `main` then deploys.

### Custom domain (optional)

1. `railway domain <host> --port 8080 --json` prints a CNAME target and a `_railway-verify` TXT record.
2. Create both records at the DNS host. On Cloudflare, create the CNAME **DNS only (grey cloud)**
   so Railway can issue the certificate; proxying can be turned on afterwards.
3. Poll Railway's domain status until verified and the certificate is valid. Records can take
   several minutes to appear on Cloudflare's nameservers. Resolvers (including the user's Mac)
   may cache the earlier "does not exist" answer for up to 30 minutes; test with
   `curl --resolve host:443:<ip>` or DNS-over-HTTPS instead of trusting local DNS.

Use the final URL as `$SERVER` from here on.

## 3. Configure KOReader

The user plugs the e-reader in with KOReader **closed**. Then:

```sh
python3 scripts/configure_koreader.py --device $DEVICE --server $SERVER --password "$(cat .password)" \
  [--home-dir /mnt/us/documents/Books] [--ssh-key ~/.ssh/id_ed25519.pub]
```

It backs up the settings it changes, sets the stats sync server, installs the
`highlightsync` plugin and adds a stats-sync-on-close profile. It refuses to write if the result
would not be a valid Lua table. Don't hand-edit KOReader's `.lua` settings instead of this; if you
must, KOReader must be closed and the result must parse as Lua.

`--home-dir` is how the **device** sees the folder (Kindle: `/mnt/us/...`), not the Mac path.
Only pass `--ssh-key` if the user wants SSH; it only helps when their router lets devices reach
each other (guest networks and "client isolation" block it).

Eject the drive (`diskutil eject $DEVICE`), then have the user, with Wi-Fi on:

1. Open KOReader and any book, read a page or two.
2. Top menu → wrench (Tools) → Reading statistics → Synchronize. It should say "Successfully synchronized".
3. Make a highlight.

Within a minute, check:

```sh
curl -s -u "reader:$(cat .password)" $SERVER/api/library | python3 -m json.tool | head -40
```

`stats` should be non-empty and the book should list the highlight. After this, highlights
upload a few seconds after they change and stats sync on Wi-Fi connect, every 30 minutes, and
on book close. Nothing needs the user to close books.

If highlights don't arrive: plug the device in (KOReader closed) and read
`$DEVICE/koreader/crash.log`; the plugin logs every step as `HighlightSync: ...`. Queued uploads
wait in `$DEVICE/koreader/settings/highlightsync_outbox/`.

## 4. Books (optional cleanup)

KOReader opens EPUB, MOBI, AZW, PDF, FB2, CBZ and more, but **not `.azw3`** and nothing with
Amazon DRM.

- Put books in one folder (e.g. `$DEVICE/documents/Books`) and pass that folder as `--home-dir`.
- Convert DRM-free `.azw3` to EPUB with KindleUnpack (https://github.com/kevinhendricks/KindleUnpack):
  `python3 lib/kindleunpack.py -s book.azw3 outdir` and take `outdir/mobi8/*.epub`.
  A MOBI file is DRM-protected if the 16-bit big-endian value at offset 12 of record 0 is nonzero;
  `.kfx` files from Amazon purchases are DRM-protected. Leave those for the stock reader.
- On FAT-formatted devices don't use `:` in file names (use ` - `), and delete macOS `._*` files.
- Moving a book? Move its `<name>.sdr` folder with it, renamed to match; it holds the reading position.

## 5. iPhone widget (optional)

Needs Xcode, `xcodegen` (`brew install xcodegen`) and the user's Apple Developer team ID.

```sh
READING_SERVER=$SERVER ios/make-secrets.sh          # writes the git-ignored ios/Shared/Secrets.swift
cd ios
DEVELOPMENT_TEAM=<team id> BUNDLE_ID_PREFIX=<reverse domain, e.g. com.example> xcodegen generate
xcodebuild -project Reading.xcodeproj -scheme Reading -configuration Release \
  -destination 'id=<iPhone UDID from `xcrun devicectl list devices`>' \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> build/Build/Products/Release-iphoneos/Reading.app
```

The app is the site in a web view (the user signs in once). Widgets: "Reading" (today, streak,
week, current book; Home and Lock Screen) and "Reading calendar" (GitHub-style grid). They read
`/api/widget` with the widget token and refresh about every 30 minutes.

## 6. Extras the user may want (Kindle, jailbroken)

- **Remove lock-screen ads**: the "Disable ADs" scriptlet from https://scriptlets.notmarek.com.
  Read it before copying it to `$DEVICE/documents/`; the user opens it from the Kindle library and
  the device reboots.
- **Custom screensaver**: https://github.com/chengandre/kindle-custom-screensaver (check its tested
  models). Images go in `$DEVICE/screensavers/`; resize to the screen (Paperwhite 11: 1236×1648)
  and convert to grayscale. It must be re-enabled from its library item after every reboot.
- **Recommendations off**: stock setting, Settings → Device Options → Advanced Options → Home and Library.

## 7. Hand over

Tell the user, without making them read this file:

- the site URL, username `reader` and the password (in `.password`); it signs in for 180 days
- where to put books, and that highlights and stats sync on their own over Wi-Fi
- that nothing needs a book to be closed
- how to add the widgets (Home Screen → Edit → Add Widget → Reading)

## Known pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Kindle on USB but no drive | KOReader is running | Exit KOReader |
| "No route to host" to the Kindle over Wi-Fi | Router client isolation, or the Kindle's Wi-Fi asleep | Wake it; else use USB, or Tailscale |
| Only some books show in KOReader | `.azw3` isn't supported | Convert to EPUB |
| Stats sync error "file is not a database" once | First sync, nothing on the server yet | Harmless; next sync works |
| Data gone after a deploy | No volume mounted at `/data` | `railway volume add -m /data` before relying on it |
| Custom domain not resolving locally | Negative DNS cache | Wait, or flush: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |

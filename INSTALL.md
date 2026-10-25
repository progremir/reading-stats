# Install guide (for an agent)

Follow this top to bottom to set up reading-stats for someone: their e-reader running KOReader
syncs reading time and highlights to a server they own, viewable on the web and in iPhone widgets.
One server can hold several readers (a couple, a family), each with their own account. Do step 2
once per server, and steps 1, 3, 4 and 5 once per reader.

You need the user for a few physical steps (plugging in the e-reader, tapping on it). Everything
else you can do yourself. Stop and ask when a step says **Ask**.

## 0. Gather facts first

**Ask** the user, and write down the answers:

0. Who will use it, and is there already a reading-stats server? One person, or several sharing
   one server? If a server exists, get its URL and an admin's sign-in, and skip to "Adding a
   reader" in step 2. Pick a lowercase username for each extra reader (letters, digits, `_`).
1. Which e-reader (for each reader)? Kindle, Kobo, PocketBook or Android/Boox. If it's a Kindle: the model and the
   exact firmware version (Settings → Device Options → Device Info), or plug it in and read
   `system/version.txt` from the drive; the serial number's first 6 characters identify the model.
2. Is KOReader already installed? (On a Kindle that means it's already jailbroken.)
3. Do they have a Railway account (and is the `railway` CLI logged in: `railway whoami`)?
4. Do they want a custom domain? If so, where is its DNS (e.g. Cloudflare)?
5. Do they want the iPhone app and widgets? Each reader installs it from TestFlight (step 5);
   nothing to build.
6. Their time zone (IANA name, e.g. `Europe/Berlin`), used for "today" and streaks. Readers on
   one server can have different ones.

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

Secrets live in git-ignored files at the repo root: `.password` is the first admin's account
password, `.cookies` holds a signed-in session for the commands below, and `.users/` holds each
reader's e-reader (device) password as `.users/<name>.device-password`. Account passwords are
for signing in on the web; e-readers never get them.

From the repo root:

```sh
railway init --name reading-stats          # or link an existing project
railway add --service web
openssl rand -base64 18 | tr -d '/+=' | cut -c1-20 > .password      # git-ignored
railway variable set --service web --skip-deploys \
  AUTH_USER=reader AUTH_PASSWORD="$(cat .password)" TZ_NAME=<their IANA time zone> DATA_DIR=/data
railway volume add -m /data                 # accounts and reading data live here; without it a deploy wipes them
railway up --detach
railway domain                              # prints the *.up.railway.app URL
```

The first start creates the admin account `reader` from `AUTH_PASSWORD` (it's read only while
there are no accounts). Wait for the deployment to reach SUCCESS (`railway deployment list
--json`), set `$SERVER` to the URL, then sign in and make the first reader's e-reader password:

```sh
curl -s -o /dev/null -w "%{http_code}\n" $SERVER/healthz                    # 200
curl -s -c .cookies -o /dev/null -w "%{redirect_url}\n" \
  -d "username=reader&password=$(cat .password)" $SERVER/login             # $SERVER/ (not ?e=bad)
mkdir -p .users
curl -s -b .cookies -H 'Content-Type: application/json' -d '{"label":"Kindle"}' \
  $SERVER/api/account/devices | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])' \
  > .users/reader.device-password
curl -s -o /dev/null -w "%{http_code}\n" -u "reader:$(cat .users/reader.device-password)" \
  -X PROPFIND $SERVER/dav/koreader/                                         # 207
```

Optional, recommended: push the repo to a private GitHub repo and connect it as the service's
source (Railway MCP `connect-service-source`, or the dashboard). Every push to `main` then deploys.

### Adding a reader

People are added by an admin, on the site (Account → Admin → Add a person) or with the same API.
For `alice`, signed in as an admin (`.cookies` from above):

```sh
J='Content-Type: application/json'
curl -s -b .cookies -H "$J" -d '{"name":"alice","tz":"<their IANA time zone>"}' $SERVER/api/admin/users
# {"password": "..."}: her temporary password. Give it to her; she picks her own at first sign-in.
ID=$(curl -s -b .cookies $SERVER/api/admin/users | python3 -c '
import json, sys; print(next(u["id"] for u in json.load(sys.stdin)["users"] if u["name"] == "alice"))')
curl -s -b .cookies -H "$J" -d "{\"id\":$ID,\"action\":\"new_device\",\"label\":\"Kindle\"}" \
  $SERVER/api/admin/users/action | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])' \
  > .users/alice.device-password
curl -s -o /dev/null -w "%{http_code}\n" -u "alice:$(cat .users/alice.device-password)" \
  -X PROPFIND $SERVER/dav/koreader/                                         # 207
```

No redeploy is needed. A new account starts empty, with its data in `/data/users/alice/dav`.
Temporary and device passwords are shown only once; if one is lost, reset it or make a new one.

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
python3 scripts/configure_koreader.py --device $DEVICE --server $SERVER \
  --user <name> --password "$(cat .users/<name>.device-password)" \
  [--home-dir /mnt/us/documents/Books] [--ssh-key ~/.ssh/id_ed25519.pub]
```

Use the reader's **device password**, not their account password: it's stored on the e-reader,
and it can be revoked on its own from the account page if the device is lost.

Check you're configuring the right person's device before writing: on a Kindle, the serial
(`ioreg -p IOUSB -l -w0 | grep '"USB Serial Number" = "G'`) tells two devices of the same model apart.

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
curl -s -u "<name>:$(cat .users/<name>.device-password)" $SERVER/api/library | python3 -m json.tool | head -40
```

`stats` should be non-empty and the book should list the highlight. After this, highlights
upload a few seconds after they change and stats sync on Wi-Fi connect, every 30 minutes, and
on book close. Nothing needs the user to close books.

If highlights don't arrive: plug the device in (KOReader closed) and read
`$DEVICE/koreader/crash.log`; the plugin logs every step as `HighlightSync: ...`. Queued uploads
wait in `$DEVICE/koreader/settings/highlightsync_outbox/`.

Books sent from the web (Books tab → Send to e-reader) wait in the account's `/dav/koreader/inbox/`
until the plugin downloads them into an `Inbox` folder in KOReader's home folder, on Wi-Fi connect
and every 30 minutes; Tools → "Get books sent from the web" fetches them right away. To test:

```sh
curl -s -u "<name>:$(cat .users/<name>.device-password)" -T book.epub "$SERVER/api/inbox/book.epub"
```

## 4. Books (optional cleanup)

KOReader opens EPUB, MOBI, AZW, PDF, FB2, CBZ and more, but **not `.azw3`** and nothing with
Amazon DRM.

- Put books in one folder (e.g. `$DEVICE/documents/Books`) and pass that folder as `--home-dir`.
- Convert DRM-free `.azw3` to EPUB with KindleUnpack (https://github.com/kevinhendricks/KindleUnpack):
  `python3 lib/kindleunpack.py -s book.azw3 outdir` and take `outdir/mobi8/*.epub`, or with
  calibre's `ebook-convert book.azw3 book.epub`.
  A MOBI file is DRM-protected if the 16-bit big-endian value at offset 12 of record 0 is nonzero.
- Books sent with Send to Kindle land in `$DEVICE/documents/Downloads/Items01/`, often as `.kfx`.
  Those personal documents are usually DRM-free (the file starts with `CONT`, and there is no
  `DRMION` marker or voucher). Convert them with calibre plus jhowell's KFX Input plugin:
  `ebook-convert book.kfx book.epub`. `.kfx` books bought from Amazon are DRM-protected; leave
  those for the stock reader.
- On FAT-formatted devices don't use `:` in file names (use ` - `), and delete macOS `._*` files.
- Moving a book? Move its `<name>.sdr` folder with it, renamed to match; it holds the reading position.

## 5. iPhone app and widgets (optional)

Each reader opens https://testflight.apple.com/join/KPEdXnF8 on their iPhone, installs TestFlight
if asked, then installs Reading Stats. On first launch the app asks for the server address
(`$SERVER`; `https://` is assumed, and a plain `http://` server on the home network works too),
then shows the same sign-in as the website. It gets a widget token for that phone from the server
and shares it with its widgets through an App Group.

**Building it yourself instead** (to change the app, or not use TestFlight) needs Xcode,
`xcodegen` (`brew install xcodegen`) and an Apple Developer team ID:

```sh
cd ios
DEVELOPMENT_TEAM=<team id> BUNDLE_ID_PREFIX=<reverse domain, e.g. com.example> xcodegen generate
xcodebuild -project Reading.xcodeproj -scheme Reading -configuration Release \
  -destination 'id=<iPhone UDID from `xcrun devicectl list devices`>' \
  -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <UDID> build/Build/Products/Release-iphoneos/Reading.app
```

The same build works for any server and reader. Rerun `xcodegen generate` after adding Swift
files. Automatic signing registers the App Group `group.<prefix>.reading` the first time.

The phone must be in the team's device list and have Developer Mode on (Settings → Privacy &
Security; it restarts). `-allowProvisioningDeviceRegistration` adds the phone to the developer
account; tell the user that's happening, since it's their account. If the first build fails with
"Build input file cannot be found: …mobileprovision", the new profile was still downloading:
run the same command again.

Each reader enters the server address, then signs in with their own username. Within a few seconds the phone
appears under "iPhone widgets" on their account page and the widgets fill in. Signing out
clears the widgets; signing in as someone else switches them. "Change server" under the sign-in
form goes back to the address screen. Widgets: "Reading" (today, streak,
week, current book; Home and Lock Screen) and "Reading calendar" (GitHub-style grid). They
refresh about every 30 minutes.

## 6. Extras the user may want (Kindle, jailbroken)

- **Remove lock-screen ads**: the "Disable ADs" scriptlet from https://scriptlets.notmarek.com.
  Read it before copying it to `$DEVICE/documents/`; the user opens it from the Kindle library and
  the device reboots.
- **Custom screensaver**: https://github.com/chengandre/kindle-custom-screensaver (check its tested
  models). Images go in `$DEVICE/screensavers/`; resize to the screen (Paperwhite 11: 1236×1648)
  and convert to grayscale. It must be re-enabled from its library item after every reboot.
- **Recommendations off**: stock setting, Settings → Device Options → Advanced Options → Home and Library.

## 7. Hand over

Tell the user, for each reader, without making them read this file:

- the site URL, their username and password (`.password` for the first admin, the temporary
  password for others, which they replace at first sign-in); it signs in for 180 days, and each
  person sees only their own books
- that the account page (Account tab) is where they change their password, see their devices and
  sign out other sessions, and, for admins, where the admin page is
- where to put books, and that highlights and stats sync on their own over Wi-Fi
- that Books → Send to e-reader puts books in the e-reader's Inbox folder the next time it's online
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
| Server exits with "No accounts yet" | First start without `AUTH_PASSWORD` | Set `AUTH_PASSWORD` and redeploy |
| KOReader sync says unauthorized | It has the account password, or the device password was revoked | Make a device password and rerun step 3 with it |
| Signed in, but only the account page shows | A temporary password: the user must choose their own first | Change it on the account page |
| Widgets empty after installing the app | Not signed in to the app yet | Open the app and sign in |
| API call answers "Cross-site request refused" | A POST without `Content-Type: application/json` | Send JSON with that header |
| Scripted WebDAV requests get 403 | Cloudflare bot protection blocks Python's default User-Agent | Send a custom `User-Agent` header |

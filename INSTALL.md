# Install guide (for an agent)

Follow this top to bottom to set up reading-stats for someone: their e-reader running KOReader
syncs reading time and highlights to a server they own, viewable on the web and in iPhone widgets.
One server can hold several readers (a couple, a family), each with their own account. Do steps
1, 3, 4 and 5 once per reader; step 2 once per server.

You need the user for a few physical steps (plugging in the e-reader, tapping on it). Everything
else you can do yourself. Stop and ask when a step says **Ask**.

## 0. Gather facts first

**Ask** the user, and write down the answers:

0. Who will use it, and is there already a reading-stats server? One person, or several sharing
   one server? If a server exists, get its URL and skip to "Adding a reader" in step 2. If two
   people each already have a server and want one, see "Merging two servers" after step 7.
   Pick a username for each extra reader (letters, digits, `_`).
1. Which e-reader (for each reader)? Kindle, Kobo, PocketBook or Android/Boox. If it's a Kindle: the model and the
   exact firmware version (Settings → Device Options → Device Info), or plug it in and read
   `system/version.txt` from the drive; the serial number's first 6 characters identify the model.
2. Is KOReader already installed? (On a Kindle that means it's already jailbroken.)
3. Do they have a Railway account (and is the `railway` CLI logged in: `railway whoami`)?
4. Do they want a custom domain? If so, where is its DNS (e.g. Cloudflare)?
5. Do they want the iPhone widget? That needs a Mac with Xcode and an Apple Developer team ID.
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

Secrets live in git-ignored files at the repo root. The first account uses `.password` and
`.widget-token`; every other reader uses `.users/<name>.password` and `.users/<name>.widget-token`.
Below, `$PASSWORD_FILE` means the reader's password file and `$USERNAME` their username (`reader`
for the first account).

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

### Adding a reader

For each extra person on the same server (`alice` here), from the repo root of the server's
linked checkout:

```sh
mkdir -p .users
openssl rand -base64 18 | tr -d '/+=' | cut -c1-20 > .users/alice.password     # git-ignored
openssl rand -hex 24 > .users/alice.widget-token                               # git-ignored
USERS=$(railway variables --service web --kv | sed -n 's/^USERS=//p' | python3 -c '
import json, sys
users = json.loads(sys.stdin.read() or "{}")
name, tz = sys.argv[1], sys.argv[2]
users[name] = {"password": open(".users/%s.password" % name).read().strip(),
               "widget_token": open(".users/%s.widget-token" % name).read().strip(), "tz": tz}
print(json.dumps(users))' alice <their IANA time zone>)
railway variable set --service web "USERS=$USERS"              # redeploys
```

This merges into any existing `USERS`; never overwrite it with only the new person, or the
others lose their accounts (their data stays on the volume). Wait for the deployment, then check
the server log lists every account (`railway logs --service web | grep listening` prints
`users: reader, alice`) and that the new login works:

```sh
curl -s -o /dev/null -w "%{http_code}\n" -u "alice:$(cat .users/alice.password)" -X PROPFIND $SERVER/dav/koreader/   # 207
```

A new account starts empty. Its data lives in `/data/users/alice/dav`, apart from everyone else's.

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
  --user $USERNAME --password "$(cat $PASSWORD_FILE)" \
  [--home-dir /mnt/us/documents/Books] [--ssh-key ~/.ssh/id_ed25519.pub]
```

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
curl -s -u "$USERNAME:$(cat $PASSWORD_FILE)" $SERVER/api/library | python3 -m json.tool | head -40
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

## 5. iPhone widget (optional)

Needs Xcode, `xcodegen` (`brew install xcodegen`) and the user's Apple Developer team ID.

Each build carries one reader's widget token, so build once per reader. For the first account:

```sh
READING_SERVER=$SERVER ios/make-secrets.sh          # writes the git-ignored ios/Shared/Secrets.swift
```

For anyone else, pass their token:

```sh
WIDGET_TOKEN="$(cat .users/alice.widget-token)" READING_SERVER=$SERVER ios/make-secrets.sh
```

Then build and install on that reader's iPhone:

```sh
cd ios
DEVELOPMENT_TEAM=<team id> BUNDLE_ID_PREFIX=<reverse domain, e.g. com.example> xcodegen generate
xcodebuild -project Reading.xcodeproj -scheme Reading -configuration Release \
  -destination 'id=<iPhone UDID from `xcrun devicectl list devices`>' \
  -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <UDID> build/Build/Products/Release-iphoneos/Reading.app
```

Run `make-secrets.sh` again before building for the next reader, or the build carries the
previous person's token. Readers' phones can share one bundle ID; give a build its own
`BUNDLE_ID_PREFIX` only if one phone needs two readers' apps side by side.

The phone must be in the team's device list and have Developer Mode on (Settings → Privacy &
Security; it restarts). `-allowProvisioningDeviceRegistration` adds the phone to the developer
account; tell the user that's happening, since it's their account. If the first build fails with
"Build input file cannot be found: …mobileprovision", the new profile was still downloading:
run the same command again.

The app is the site in a web view; each reader signs in once with their own username. Widgets: "Reading" (today, streak,
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

Tell the user, for each reader, without making them read this file:

- the site URL, their username and password (`.password` for `reader`, `.users/<name>.password`
  for others); it signs in for 180 days, and each person sees only their own books
- where to put books, and that highlights and stats sync on their own over Wi-Fi
- that nothing needs a book to be closed
- how to add the widgets (Home Screen → Edit → Add Widget → Reading)

## Merging two servers into one

When two people each have a server and want to share one, keep the server that has the most
data (it becomes the first account's) and move the other person in as an extra account:

1. Add them with "Adding a reader" in step 2, reusing their current password and widget token
   (copy their `.password` and `.widget-token` into `.users/<name>.*`). Their iPhone widgets then
   keep working.
2. Copy their files over WebDAV: from the old server's `/dav/koreader/` and
   `/dav/koreader/highlights/`, GET each file (`statistics.sqlite3`, `highlights/*.json`,
   `highlights/clippings.txt`) with the old login, and PUT it to the same path on the new server
   as the new user. Behind Cloudflare, give scripted requests a User-Agent: its bot protection
   answers 403 to Python's default one.
3. Compare `/api/library` on both: book count, highlight count and `stats.total` should match.
4. With their e-reader plugged in, rerun step 3 with `--user <name>` and the new `$SERVER`.
5. If their iPhone app was built for the old URL, either rebuild it (step 5), or move the old
   domain to the new server's service (delete it on the old service, add it on the new one,
   update the CNAME and `_railway-verify` TXT records) so the old URL keeps working.
6. Only then delete the old Railway project. It holds the only other copy of their data, so
   confirm with the user first.

## Known pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Kindle on USB but no drive | KOReader is running | Exit KOReader |
| "No route to host" to the Kindle over Wi-Fi | Router client isolation, or the Kindle's Wi-Fi asleep | Wake it; else use USB, or Tailscale |
| Only some books show in KOReader | `.azw3` isn't supported | Convert to EPUB |
| Stats sync error "file is not a database" once | First sync, nothing on the server yet | Harmless; next sync works |
| Data gone after a deploy | No volume mounted at `/data` | `railway volume add -m /data` before relying on it |
| Custom domain not resolving locally | Negative DNS cache | Wait, or flush: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| Server won't start after setting `USERS` | Invalid JSON, a short password, a repeated name or a shared widget token | Read `railway logs`; the error names the problem |
| A reader's login stopped working after adding someone | `USERS` was overwritten instead of merged | Add them back; their data is still in `/data/users/<name>` |
| Widgets show someone else's reading | That build has another reader's token | Rerun `make-secrets.sh` with the right `WIDGET_TOKEN` and rebuild |
| Scripted WebDAV requests get 403 | Cloudflare bot protection blocks Python's default User-Agent | Send a custom `User-Agent` header |

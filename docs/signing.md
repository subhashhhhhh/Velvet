# Signing and updates

Releases are signed with a self-signed certificate called **Velvet Self-Signed**,
the same one for every release. Velvet isn't notarized (that needs a paid Apple
developer account), so this isn't about Gatekeeper. Signing with one fixed
certificate does two things:

- **The in-app updater can trust a download.** Before it replaces the running
  app, it checks that the downloaded Velvet is intact and signed with exactly
  the certificate the running app was signed with. Only the private key in the
  maintainer's keychain can make that signature, so a changed or substituted
  download is refused.
- **macOS sees every build as the same app.** An ad-hoc signed app is identified
  by its exact build, so each update looked like a new app to privacy settings.

`scripts/release.sh` signs with it and stops if it's missing. `install.sh` uses
it when it's in the keychain, so a local build can also install releases.

## Back up the certificate

**If the private key is lost, installed copies stop accepting updates:** a
release signed with a new certificate is refused, and people must download it
by hand once. Export a backup and keep the file and its password somewhere
safe, such as a password manager:

```bash
security export -t identities -f pkcs12 -k ~/Library/Keychains/login.keychain-db \
  -P "choose-a-password" -o ~/Desktop/Velvet-Self-Signed.p12
```

macOS asks for your login password to allow the export. The file holds the
private key, so don't commit it or leave it on the desktop.

To restore it on another Mac:

```bash
security import Velvet-Self-Signed.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "the-password" -T /usr/bin/codesign
```

## Creating it (once)

This was done once, on 9 November 2026, and must **not** be repeated while the
original exists: a new certificate is a different identity.

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout key.pem -out cert.pem \
  -subj "/CN=Velvet Self-Signed" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
# -legacy: macOS can't import OpenSSL 3's default PKCS#12 encryption.
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "Velvet Self-Signed" \
  -out identity.p12 -passout pass:temporary
security import identity.p12 -k ~/Library/Keychains/login.keychain-db -P temporary -T /usr/bin/codesign
rm key.pem cert.pem identity.p12
```

`security find-identity -p codesigning` lists it as `CSSMERR_TP_NOT_TRUSTED`,
which is expected for a self-signed certificate and doesn't stop `codesign`.

## How an update is installed

1. Once a day (30 seconds after launch at the earliest, while **Settings ›
   About › Check for updates automatically** is on), Velvet reads
   `updates/latest.json` from the repository through raw.githubusercontent.com,
   and falls back to GitHub's API. A newer version shows in Settings › About,
   and gets one notification if Velvet may already post notifications.
2. The release must carry `Velvet-<version>-AppleSilicon.zip`.
3. The zip is downloaded to `~/Library/Caches/VelvetUpdate` and its SHA-256 is
   compared with the manifest's (or the digest GitHub reports).
4. It's unzipped with `ditto`, and the app inside must have Velvet's bundle ID,
   the advertised version, and a valid signature from the same certificate.
5. Only then is the installed Velvet replaced, and Velvet relaunches.

A build signed any other way (ad hoc, or with a development certificate) offers
the release page instead of installing. Homebrew's cask declares
`auto_updates true`, so `brew upgrade` leaves a self-updating Velvet alone.

To test the updater, build a Debug copy signed with the certificate, serve a
release JSON and zip from a local HTTP server, and start the copy with
`VELVET_UPDATE_FEED=<feed URL>` and `-VelvetUpdateTest YES`.

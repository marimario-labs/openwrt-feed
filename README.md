# openwrt-feed

Signed OpenWrt package feed served at https://feed.openwrt.marimario.me/ (Cloudflare Pages, `public/` on `main`).

The test key `ed08b382f5d92ab5` in the git history was temporary. Do not trust it.

## Layout

- `public/<release>/all/` — packages and the signed index for each OpenWrt release
  (`24.10`: `Packages`, `Packages.gz`, `Packages.sig` signed with usign; `25.12`:
  `packages.adb` signed with an RSA key)
- `public/keys/marimario.pub` (usign) and `public/keys/marimario.pem` (apk) — public keys
- `public/<project>/install.sh` — per-project one-line installer

## Key fingerprints

Published once here; projects link to this file.

- usign key id: `{{PENDING}}` (`usign -F -p marimario.pub`)
- apk pubkey sha256 (DER): `{{PENDING}}` (`openssl pkey -pubin -in marimario.pem -outform DER | sha256sum`)

## Publishing

Signing happens on the maintainer machine inside the pinned SDK containers
(`openwrt/sdk:x86-64-v24.10.8`, `openwrt/sdk:x86-64-v25.12.6`); pushing `main`
deploys via Cloudflare Pages.

```sh
./publish.sh --gen-keys                 # once: create keys/ (gitignored, keep secret)
./publish.sh <release> <pkg>...         # add packages, rebuild + re-sign + verify index, push
./publish.sh --withdraw <release> <file># remove a published package, rebuild + re-sign
./publish.sh --verify                   # verify the published indexes against keys/
./selftest.sh                           # end-to-end test against a scratch clone
```

Rules enforced by `publish.sh`:

- The index is rebuilt from every package in `public/<release>/all/` (the feed is
  shared across projects), so a release publishes for all projects at once.
- Published `.ipk`/`.apk` files are never modified or deleted; `--withdraw` is the
  only exception (it removes the file, rebuilds and re-signs the index).
- Every release is tagged `release/<UTC timestamp>`; immutability is checked
  against the previous release tag.

To publish `install.sh`, `faq.html` or the public keys, copy them under `public/`
and commit; only package files are guarded.

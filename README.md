# Watti

![Watti app icon](Assets/readme-hero.png)

## Why

I built Watti because my super old mac’s battery is in terrible shape. I need to know often how many watts I am getting from a certain charger. My battery will puke even on the best chargers, but I want to know still what my current input is.

I found a cool api surfaced by Apple that allows you to get the familyCode of a charger, so we can name chargers.

For other old mac users, you will likely appreciate the TTL concept, ie, if unplugged now, how long your computer will last before blacking out.

I thought I would share with others who might be having the same issue as I am. But the expectation is that no one will find or use this. I may resort to just installing this on my friend’s machines. ;)

Ping me with questions —

Happy hacking,

Reif  
reif@thegoodproject.net

---

Menu bar app that shows power/wattage details on macOS.

Sponsored by **The Good Project** — contact `reif@thegoodproject.net`.

## Install (no Terminal)

1. Download **`Watti.dmg`** (recommended):  
   https://github.com/reif-is-a-foofie/Watti/releases/latest/download/Watti.dmg
2. Double‑click it to open, then drag **`Watti.app`** onto **Applications**.
3. Open **Watti** from **Applications**.
4. If macOS blocks it, open **System Settings → Privacy & Security**, then click **Open Anyway** and try again.
   - Quick link (may not be clickable in GitHub; copy/paste into Safari): `x-apple.systempreferences:com.apple.preference.security?Privacy`
   - Or run in Terminal: `open "x-apple.systempreferences:com.apple.preference.security?Privacy"`

Archives are also attached to each release: **`Watti-macos.zip`** and **`Watti-macos.tar.gz`**.

A `.zip` of the same app is also attached to each release if you prefer that format.

## Local build

```bash
./scripts/make_icon.sh
./build.sh
open build/Watti.app
```

## GitHub Releases (macOS)

Push a tag like `v1.0.0` and GitHub Actions will attach **`Watti.dmg`**, **`Watti-macos.tar.gz`**, and **`Watti-macos.zip`** to the release.


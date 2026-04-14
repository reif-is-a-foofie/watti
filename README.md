# Watti

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

<img src="Assets/Watti.iconset/icon_256x256@2x.png" alt="Watti app icon" width="128" height="128" />

![Watti popover: live watts, named charger, power source, unplugged runtime (TTL), time to full, and charger profile](Assets/watti-screenshot.png)

![Fully charged with power boost](Assets/watti-fully-charged.png)

Sponsored by **The Good Project** — contact `reif@thegoodproject.net`.

## Install (no Terminal)

1. Download **`Watti-macos.tar.gz`** — direct link to the latest release asset:  
   https://github.com/reif-is-a-foofie/watti/releases/latest/download/Watti-macos.tar.gz  
   (If that 404s, open [Releases](https://github.com/reif-is-a-foofie/watti/releases) and download `Watti-macos.tar.gz` from the newest version — the link works once a release includes that file.)
2. Double-click the archive; macOS unpacks it beside the download.
3. Drag **`Watti.app`** into **Applications**.
4. Open it from Applications the first time (right-click → **Open** if Gatekeeper complains about an unsigned download).

A `.zip` of the same app is also attached to each release if you prefer that format.

## Local build

```bash
./scripts/make_icon.sh
./build.sh
open build/Watti.app
```

## GitHub Releases (macOS)

Push a tag like `v1.0.0` and GitHub Actions will attach **`Watti-macos.tar.gz`** and **`Watti-macos.zip`** to the release.


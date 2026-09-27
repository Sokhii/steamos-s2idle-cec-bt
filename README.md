# steamos-s2idle-cec-bt

SteamOS helper for DIY boxes that use a **DisplayPort → HDMI CEC** adapter (UGREEN and similar) plus **wake-on-Bluetooth**.

This is a replacement for the CEC half of [steamos-cec-bt-wake](https://github.com/xXJSONDeruloXx/steamos-cec-bt-wake). That project talks to SteamOS `cecd` over D-Bus from a `suspend.target` unit. On s2idle (`rtcwake -m freeze` / Game Mode sleep) that unit often never runs, and `cecd` `Wake` can fire before HPD. Manual `cec-ctl --image-view-on` still works.

This installer instead:

1. Drops a script in `/etc/systemd/system-sleep/` so it runs on **every** resume (`post`), including freeze/s2idle.
2. Waits a few seconds, then sends the same CEC packets that already work:
   - `IMAGE_VIEW_ON` to the TV
   - `ACTIVE_SOURCE` with your real physical address
3. Enables USB `power/wakeup` on the Bluetooth radio (udev + boot service), same pattern as the forum USB-remote rule and steamos-cec-bt-wake.

It **disables** `cec-wake.service` and `cec-sleep.service` from the old project so two wake paths do not fight. It does not delete that repo’s files unless you uninstall that project yourself.

TV **off** on sleep stays with SteamOS Settings → CEC / `suspend_tv`.

## Install (SteamOS Desktop, Konsole)

```bash
sudo bash install.sh --install
```

Optional overrides if autodetect is wrong:

```bash
sudo CEC_PHYSICAL_ADDRESS=4.0.0.0 CEC_DELAY=5 bash install.sh --install
sudo BT_VENDOR=0e8d BT_PRODUCT=0616 bash install.sh --install
```

Find BT IDs with `lsusb`. Find CEC address with `cec-ctl -d /dev/cec0`.

```bash
sudo bash install.sh --verify
sudo bash install.sh --uninstall
```

After install: Game Mode → Sleep → wait 10+ minutes → wake with the controller. The TV should come on without opening Konsole.

## What gets written

| Path | Role |
|---|---|
| `/etc/systemd/system-sleep/steamos-s2idle-cec-bt.sh` | resume hook |
| `/etc/udev/rules.d/91-steamos-s2idle-cec-bt-bt-wakeup.rules` | BT USB wakeup |
| `/etc/udev/rules.d/99-steamos-s2idle-cec-bt-btusb-mediatek.rules` | only if `0e8d:0616` |
| `/etc/systemd/system/steamos-s2idle-cec-bt-bt-wakeup.service` | enable wakeup at boot |
| `/var/lib/steamos-s2idle-cec-bt/` | helper + state |
| `/etc/atomic-update.conf.d/steamos-s2idle-cec-bt.conf` | keep files across SteamOS updates |

## Publish your own GitHub copy

1. Create an empty repo (example name `steamos-s2idle-cec-bt`).
2. Add `install.sh` and this README.
3. Install line for others:

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/steamos-s2idle-cec-bt/main/install.sh | sudo bash -s -- --install
```

Do not publish until you have confirmed Game Mode sleep → long wait → BT wake → TV on.

## Not in scope

- Kernel VRR / G-Sync PCON whitelist (amdgpu #4773)
- Flashing UGREEN firmware
- Replacing SteamOS `cecd` for the TV remote while the PC is awake

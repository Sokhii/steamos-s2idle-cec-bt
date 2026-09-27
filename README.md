# steamos-s2idle-cec-bt

SteamOS helper for DIY boxes that use a **DisplayPort → HDMI CEC** adapter (UGREEN and similar) plus **wake-on-Bluetooth**.

This replaces the CEC half of [steamos-cec-bt-wake](https://github.com/xXJSONDeruloXx/steamos-cec-bt-wake). That project talks to SteamOS `cecd` over D-Bus from a `suspend.target` unit. On s2idle (`rtcwake -m freeze` / Game Mode sleep) that unit often never runs. Manual `cec-ctl --image-view-on` on `/dev/cec0` still works.

This installer instead:

1. Drops a script in `/etc/systemd/system-sleep/` so it runs on **every** resume (`post`), including freeze/s2idle.
2. Sends the same CEC packets that already work:
   - `IMAGE_VIEW_ON` to the TV
   - `ACTIVE_SOURCE` with your real physical address
3. Enables USB `power/wakeup` on the Bluetooth radio (udev + boot service).

If the old project's `cec-wake.service` / `cec-sleep.service` are still present, they are disabled so the two wake paths do not fight.

TV **off** on sleep stays with SteamOS Settings → CEC / `suspend_tv`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Sokhii/steamos-s2idle-cec-bt/main/install.sh | sudo bash -s -- --install
```

## Verify

```bash
curl -fsSL https://raw.githubusercontent.com/Sokhii/steamos-s2idle-cec-bt/main/install.sh | sudo bash -s -- --verify
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Sokhii/steamos-s2idle-cec-bt/main/install.sh | sudo bash -s -- --uninstall
```

Optional overrides if autodetect is wrong:

```bash
curl -fsSL https://raw.githubusercontent.com/Sokhii/steamos-s2idle-cec-bt/main/install.sh | sudo CEC_PHYSICAL_ADDRESS=4.0.0.0 bash -s -- --install
curl -fsSL https://raw.githubusercontent.com/Sokhii/steamos-s2idle-cec-bt/main/install.sh | sudo BT_VENDOR=0e8d BT_PRODUCT=0616 bash -s -- --install
```

Find BT IDs with `lsusb`. Find CEC address with `cec-ctl -d /dev/cec0`.

After install: Game Mode → Sleep → wait 10+ minutes → wake with the controller.

## What gets written

| Path | Role |
|---|---|
| `/etc/systemd/system-sleep/steamos-s2idle-cec-bt.sh` | resume hook |
| `/etc/udev/rules.d/91-steamos-s2idle-cec-bt-bt-wakeup.rules` | BT USB wakeup |
| `/etc/udev/rules.d/99-steamos-s2idle-cec-bt-btusb-mediatek.rules` | only if `0e8d:0616` |
| `/etc/systemd/system/steamos-s2idle-cec-bt-bt-wakeup.service` | enable wakeup at boot |
| `/var/lib/steamos-s2idle-cec-bt/` | helper + state |
| `/etc/steamos-s2idle-cec-bt.conf` | saved settings |
| `/etc/atomic-update.conf.d/steamos-s2idle-cec-bt.conf` | keep files across SteamOS updates |

## Not in scope

- Kernel VRR / G-Sync PCON whitelist (amdgpu #4773)
- Flashing UGREEN firmware
- Replacing SteamOS `cecd` for the TV remote while the PC is awake

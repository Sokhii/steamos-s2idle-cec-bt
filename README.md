# steamos-s2idle-cec-bt

SteamOS helper for DIY boxes that use a **DisplayPort → HDMI CEC** adapter (UGREEN and similar) plus **wake-on-Bluetooth**.

This replaces the CEC half of [steamos-cec-bt-wake](https://github.com/xXJSONDeruloXx/steamos-cec-bt-wake). That project talks to SteamOS `cecd` over D-Bus from a `suspend.target` unit. On s2idle (`rtcwake -m freeze` / Game Mode sleep) that unit often never runs. Manual `cec-ctl --image-view-on` on `/dev/cec0` still works.

This installer instead:

1. Drops a script in `/etc/systemd/system-sleep/` so it runs on every sleep/resume, including freeze/s2idle.
2. On sleep (`pre`): `cec-ctl --standby` to the TV.
3. On resume (`post`): `IMAGE_VIEW_ON` and `ACTIVE_SOURCE` with your real physical address.
4. Enables USB `power/wakeup` on the Bluetooth radio (udev + boot service).

SteamOS `wake_tv` / `suspend_tv` can stay enabled. This hook does not disable other projects.

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

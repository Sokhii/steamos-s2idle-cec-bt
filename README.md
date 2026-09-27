# steamos-s2idle-cec-bt

One helper (`/var/lib/steamos-s2idle-cec-bt/cec-control`):

- `standby` — `cec-ctl --standby` (called by `tv-sleep.service`)
- `wake` — `cec-ctl` Image View On, then SteamOS `cecd` `SetActiveSource` / `Wake` after 3s (called by the `/etc` sleep hook)

Bluetooth USB wakeup is unchanged. No `steamos-readonly`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Sokhii/steamos-s2idle-cec-bt/main/install.sh | sudo bash -s -- --install
```

```bash
curl -fsSL https://raw.githubusercontent.com/Sokhii/steamos-s2idle-cec-bt/main/install.sh | sudo bash -s -- --verify
```

```bash
curl -fsSL https://raw.githubusercontent.com/Sokhii/steamos-s2idle-cec-bt/main/install.sh | sudo bash -s -- --uninstall
```

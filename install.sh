#!/usr/bin/env bash
# steamos-s2idle-cec-bt
# One helper: standby + wake. Units/hook only call that helper.
# Wake: cec-ctl IMAGE_VIEW_ON, then cecd SetActiveSource (SteamOS HDMI jump).
# No steamos-readonly.
set -euo pipefail

NAME="steamos-s2idle-cec-bt"
PREFIX="/var/lib/${NAME}"
ETC_CONF="/etc/${NAME}.conf"
HELPER="${PREFIX}/cec-control"
HOOK="/etc/systemd/system-sleep/${NAME}.sh"
SLEEP_SERVICE="/etc/systemd/system/${NAME}-tv-sleep.service"
BT_HELPER="${PREFIX}/enable-bluetooth-wakeup"
UDEV_BT="/etc/udev/rules.d/91-${NAME}-bt-wakeup.rules"
UDEV_MTK="/etc/udev/rules.d/99-${NAME}-btusb-mediatek.rules"
BT_SERVICE="/etc/systemd/system/${NAME}-bt-wakeup.service"
KEEP="/etc/atomic-update.conf.d/${NAME}.conf"

CEC_DEVICE="${CEC_DEVICE:-/dev/cec0}"
CEC_PHYS="${CEC_PHYSICAL_ADDRESS:-}"
DESKTOP_USER="${DESKTOP_USER:-deck}"
BT_VENDOR="${BT_VENDOR:-}"
BT_PRODUCT="${BT_PRODUCT:-}"

log()  { printf '%s: %s\n' "$NAME" "$*"; }
die()  { printf '%s: %s\n' "$NAME" "$*" >&2; exit 1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo"
}

phys_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%s\n' $(( (a << 12) | (b << 8) | (c << 4) | d ))
}

detect_phys() {
  local out
  [[ -e "$CEC_DEVICE" ]] || return 1
  out="$(cec-ctl -d "$CEC_DEVICE" --skip-info 2>/dev/null | awk '/Physical Address/{print $NF; exit}')"
  if [[ -z "$out" ]]; then
    out="$(cec-ctl -d "$CEC_DEVICE" 2>/dev/null | awk '/Physical Address/{print $NF; exit}')"
  fi
  [[ -n "$out" && "$out" != "f.f.f.f" ]] || return 1
  printf '%s\n' "$out"
}

detect_bt_usb() {
  local hci link vendor product
  for hci in /sys/class/bluetooth/hci*; do
    [[ -e "$hci" ]] || continue
    link="$hci"
    while [[ -n "$link" && "$link" != "/" ]]; do
      if [[ -f "$link/idVendor" && -f "$link/idProduct" ]]; then
        vendor="$(tr -d '[:space:]' <"$link/idVendor")"
        product="$(tr -d '[:space:]' <"$link/idProduct")"
        printf '%s %s\n' "$vendor" "$product"
        return 0
      fi
      link="$(readlink -f "$link/.." 2>/dev/null || true)"
    done
  done
  return 1
}

write_helper() {
  local phys="$1" phys_int="$2" uid
  uid="$(id -u "$DESKTOP_USER")"
  mkdir -p "$PREFIX"
  cat >"$HELPER" <<EOF
#!/bin/bash
# Installed by ${NAME}
CEC_DEVICE="${CEC_DEVICE}"
PHYS="${phys}"
PHYS_INT="${phys_int}"
DESKTOP_USER="${DESKTOP_USER}"
UID_NUM="${uid}"
CEC_DEST="com.steampowered.CecDaemon1"
CEC_PATH="/com/steampowered/CecDaemon1/Devices/Cec0"
CEC_IFACE="com.steampowered.CecDaemon1.CecDevice1"

log() { logger -t ${NAME} "\$*"; }

cecd_call() {
  local method="\$1"; shift
  sudo -u "\$DESKTOP_USER" \\
    XDG_RUNTIME_DIR="/run/user/\$UID_NUM" \\
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$UID_NUM/bus" \\
    gdbus call --session --dest "\$CEC_DEST" --object-path "\$CEC_PATH" \\
      --method "\$CEC_IFACE.\$method" "\$@" >/dev/null 2>&1 || true
}

case "\$1" in
  standby)
    log "standby"
    if [[ -e "\$CEC_DEVICE" ]]; then
      /usr/bin/cec-ctl -d "\$CEC_DEVICE" --to 0 --standby || true
    fi
    ;;
  wake)
    log "wake"
    if [[ -e "\$CEC_DEVICE" ]]; then
      /usr/bin/cec-ctl -d "\$CEC_DEVICE" --to 0 --image-view-on || true
    fi
    log "cecd SetActiveSource \$PHYS_INT (\$PHYS)"
    cecd_call SetActiveSource "\$PHYS_INT"
    cecd_call Wake
    ;;
  *)
    echo "usage: \$0 standby|wake" >&2
    exit 1
    ;;
esac
EOF
  chmod 755 "$HELPER"
}

write_hook() {
  mkdir -p /etc/systemd/system-sleep
  cat >"$HOOK" <<EOF
#!/bin/bash
logger -t ${NAME} "sleep hook \$1 \$2"
case "\$1" in
  post)
    "${HELPER}" wake &
    ;;
esac
exit 0
EOF
  chmod 755 "$HOOK"
}

write_sleep_service() {
  cat >"$SLEEP_SERVICE" <<EOF
[Unit]
Description=CEC TV Standby before sleep (${NAME})
Before=sleep.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=${HELPER} standby

[Install]
WantedBy=sleep.target
EOF
}

write_bt_helper() {
  mkdir -p "$PREFIX"
  cat >"$BT_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
vendor="${1:?vendor ID required}"
product="${2:?product ID required}"
found=0
for dev in /sys/bus/usb/devices/*; do
  [[ -f "$dev/idVendor" && -f "$dev/idProduct" && -f "$dev/power/wakeup" ]] || continue
  [[ "$(tr -d '[:space:]' <"$dev/idVendor")" == "$vendor" ]] || continue
  [[ "$(tr -d '[:space:]' <"$dev/idProduct")" == "$product" ]] || continue
  echo enabled > "$dev/power/wakeup"
  printf 'Enabled wakeup for %s (%s:%s)\n' "$(basename "$dev")" "$vendor" "$product"
  found=1
done
(( found >= 1 )) || { echo "Bluetooth USB device $vendor:$product not found" >&2; exit 1; }
EOF
  chmod 755 "$BT_HELPER"
}

write_udev_bt() {
  local vendor="$1" product="$2"
  cat >"$UDEV_BT" <<EOF
ACTION=="add|bind", SUBSYSTEM=="usb", ATTR{idVendor}=="${vendor}", ATTR{idProduct}=="${product}", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
EOF
}

write_udev_mtk() {
  local vendor="$1" product="$2"
  if [[ "$vendor" == "0e8d" && "$product" == "0616" ]]; then
    cat >"$UDEV_MTK" <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0e8d", ATTR{idProduct}=="0616", RUN+="/bin/sh -c 'echo 0e8d 0616 > /sys/bus/usb/drivers/btusb/new_id'"
EOF
  else
    rm -f "$UDEV_MTK"
  fi
}

write_bt_service() {
  local vendor="$1" product="$2"
  cat >"$BT_SERVICE" <<EOF
[Unit]
Description=Enable Bluetooth USB wakeup (${NAME})
After=bluetooth.target

[Service]
Type=oneshot
ExecStart=${BT_HELPER} ${vendor} ${product}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_conf() {
  local phys="$1" phys_int="$2" vendor="$3" product="$4"
  cat >"$ETC_CONF" <<EOF
CEC_DEVICE=${CEC_DEVICE}
CEC_PHYSICAL_ADDRESS=${phys}
CEC_PHYSICAL_INTEGER=${phys_int}
DESKTOP_USER=${DESKTOP_USER}
BT_VENDOR=${vendor}
BT_PRODUCT=${product}
EOF
  cat >"${PREFIX}/state.conf" <<EOF
CEC_DEVICE=${CEC_DEVICE}
CEC_PHYSICAL_ADDRESS=${phys}
CEC_PHYSICAL_INTEGER=${phys_int}
BT_VENDOR=${vendor}
BT_PRODUCT=${product}
EOF
}

write_keep() {
  mkdir -p /etc/atomic-update.conf.d
  cat >"$KEEP" <<EOF
${ETC_CONF}
${HOOK}
${SLEEP_SERVICE}
${UDEV_BT}
${UDEV_MTK}
${BT_SERVICE}
${KEEP}
EOF
}

cmd_install() {
  need_root
  command -v cec-ctl >/dev/null || die "cec-ctl not found"
  mkdir -p "$PREFIX" /etc/systemd/system-sleep /etc/udev/rules.d /etc/atomic-update.conf.d

  if [[ -z "$CEC_PHYS" ]]; then
    CEC_PHYS="$(detect_phys || true)"
  fi
  [[ -n "$CEC_PHYS" ]] || die "could not read CEC physical address. Set CEC_PHYSICAL_ADDRESS=4.0.0.0"
  local phys_int
  phys_int="$(phys_to_int "$CEC_PHYS")"

  if [[ -z "$BT_VENDOR" || -z "$BT_PRODUCT" ]]; then
    read -r BT_VENDOR BT_PRODUCT <<<"$(detect_bt_usb || true)"
  fi
  [[ -n "$BT_VENDOR" && -n "$BT_PRODUCT" ]] || die "could not detect Bluetooth USB id. Set BT_VENDOR=xxxx BT_PRODUCT=yyyy from lsusb"

  write_helper "$CEC_PHYS" "$phys_int"
  write_hook
  write_sleep_service
  write_bt_helper
  write_udev_bt "$BT_VENDOR" "$BT_PRODUCT"
  write_udev_mtk "$BT_VENDOR" "$BT_PRODUCT"
  write_bt_service "$BT_VENDOR" "$BT_PRODUCT"
  write_conf "$CEC_PHYS" "$phys_int" "$BT_VENDOR" "$BT_PRODUCT"
  write_keep

  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb || true
  systemctl daemon-reload
  systemctl enable "$(basename "$SLEEP_SERVICE")"
  systemctl enable --now "$(basename "$BT_SERVICE")"

  log "installed"
  log "  helper         $HELPER"
  log "  CEC phys       $CEC_PHYS ($phys_int)"
  log "  HDMI jump      cecd SetActiveSource"
  log "  BT USB         ${BT_VENDOR}:${BT_PRODUCT}"
}

cmd_uninstall() {
  need_root
  systemctl disable --now "$(basename "$BT_SERVICE")" 2>/dev/null || true
  systemctl disable "$(basename "$SLEEP_SERVICE")" 2>/dev/null || true
  rm -f "$HOOK" "$UDEV_BT" "$UDEV_MTK" "$BT_SERVICE" "$SLEEP_SERVICE" "$ETC_CONF" "$KEEP"
  rm -f "/etc/systemd/system/sleep.target.wants/$(basename "$SLEEP_SERVICE")"
  rm -f "/etc/systemd/system/multi-user.target.wants/$(basename "$BT_SERVICE")"
  rm -rf "$PREFIX"
  udevadm control --reload-rules || true
  systemctl daemon-reload
  log "removed ${NAME} files"
}

cmd_verify() {
  echo "helper:      $([[ -x $HELPER ]] && echo OK "$HELPER" || echo MISSING)"
  echo "hook:        $([[ -x $HOOK ]] && echo OK "$HOOK" || echo MISSING)"
  echo "tv-sleep:    $(systemctl is-enabled "$(basename "$SLEEP_SERVICE")" 2>/dev/null || echo absent)"
  echo "bt service:  $(systemctl is-enabled "$(basename "$BT_SERVICE")" 2>/dev/null || echo absent) / $(systemctl is-active "$(basename "$BT_SERVICE")" 2>/dev/null || echo absent)"
  echo "cec device:  $(ls -l "$CEC_DEVICE" 2>&1)"
  if [[ -f $ETC_CONF ]]; then
    echo "--- $ETC_CONF ---"
    cat "$ETC_CONF"
  fi
}

usage() {
  cat <<EOF
$NAME
  --install
  --uninstall
  --verify

Env: CEC_DEVICE CEC_PHYSICAL_ADDRESS DESKTOP_USER BT_VENDOR BT_PRODUCT
EOF
}

case "${1:-}" in
  --install) cmd_install ;;
  --uninstall) cmd_uninstall ;;
  --verify) cmd_verify ;;
  -h|--help|"") usage ;;
  *) die "unknown arg $1" ;;
esac

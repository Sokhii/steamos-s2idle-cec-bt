#!/usr/bin/env bash
# steamos-s2idle-cec-bt
# CEC TV wake via cec-ctl after s2idle (not cecd D-Bus / suspend.target)
# Bluetooth USB wakeup via udev + oneshot service (same idea as steamos-cec-bt-wake)
set -euo pipefail

NAME="steamos-s2idle-cec-bt"
PREFIX="/var/lib/${NAME}"
ETC_CONF="/etc/${NAME}.conf"
HOOK="/etc/systemd/system-sleep/${NAME}.sh"
BT_HELPER="${PREFIX}/enable-bluetooth-wakeup"
UDEV_BT="/etc/udev/rules.d/91-${NAME}-bt-wakeup.rules"
UDEV_MTK="/etc/udev/rules.d/99-${NAME}-btusb-mediatek.rules"
BT_SERVICE="/etc/systemd/system/${NAME}-bt-wakeup.service"
KEEP="/etc/atomic-update.conf.d/${NAME}.conf"
OLD_KEEP="/etc/atomic-update.conf.d/steamos-cec-bt-wake.conf"

CEC_DEVICE="${CEC_DEVICE:-/dev/cec0}"
CEC_PHYS="${CEC_PHYSICAL_ADDRESS:-}"
BT_VENDOR="${BT_VENDOR:-}"
BT_PRODUCT="${BT_PRODUCT:-}"

log()  { printf '%s: %s\n' "$NAME" "$*"; }
die()  { printf '%s: %s\n' "$NAME" "$*" >&2; exit 1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo"
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

write_hook() {
  local phys="$1"
  cat >"$HOOK" <<EOF
#!/bin/bash
# Installed by ${NAME}. Runs on every systemd sleep/resume.
# \$1 is pre|post. TV-off is left to SteamOS suspend_tv.
case "\$1" in
  post)
    if [[ -e ${CEC_DEVICE} ]]; then
      /usr/bin/cec-ctl -d ${CEC_DEVICE} --to 0 --image-view-on || true
      /usr/bin/cec-ctl -d ${CEC_DEVICE} --active-source phys-addr=${phys} || true
    fi
    ;;
esac
exit 0
EOF
  chmod 755 "$HOOK"
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
# ${NAME} — enable USB remote wakeup on the Bluetooth radio
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
  local phys="$1" vendor="$2" product="$3"
  cat >"$ETC_CONF" <<EOF
CEC_DEVICE=${CEC_DEVICE}
CEC_PHYSICAL_ADDRESS=${phys}
BT_VENDOR=${vendor}
BT_PRODUCT=${product}
EOF
  cat >"${PREFIX}/state.conf" <<EOF
CEC_DEVICE=${CEC_DEVICE}
CEC_PHYSICAL_ADDRESS=${phys}
BT_VENDOR=${vendor}
BT_PRODUCT=${product}
EOF
}

write_keep() {
  mkdir -p /etc/atomic-update.conf.d
  cat >"$KEEP" <<EOF
${ETC_CONF}
${HOOK}
${UDEV_BT}
${UDEV_MTK}
${BT_SERVICE}
${KEEP}
EOF
}

disable_old_cec_dbus() {
  local unit
  for unit in cec-wake.service cec-sleep.service; do
    if systemctl list-unit-files "$unit" &>/dev/null; then
      systemctl disable --now "$unit" 2>/dev/null || true
      log "disabled old $unit (cecd D-Bus path)"
    fi
  done
}

cmd_install() {
  need_root
  command -v cec-ctl >/dev/null || die "cec-ctl not found"
  mkdir -p "$PREFIX" /etc/systemd/system-sleep /etc/udev/rules.d /etc/atomic-update.conf.d

  if [[ -z "$CEC_PHYS" ]]; then
    CEC_PHYS="$(detect_phys || true)"
  fi
  [[ -n "$CEC_PHYS" ]] || die "could not read CEC physical address. Set CEC_PHYSICAL_ADDRESS=4.0.0.0"

  if [[ -z "$BT_VENDOR" || -z "$BT_PRODUCT" ]]; then
    read -r BT_VENDOR BT_PRODUCT <<<"$(detect_bt_usb || true)"
  fi
  [[ -n "$BT_VENDOR" && -n "$BT_PRODUCT" ]] || die "could not detect Bluetooth USB id. Set BT_VENDOR=xxxx BT_PRODUCT=yyyy from lsusb"

  write_hook "$CEC_PHYS"
  write_bt_helper
  write_udev_bt "$BT_VENDOR" "$BT_PRODUCT"
  write_udev_mtk "$BT_VENDOR" "$BT_PRODUCT"
  write_bt_service "$BT_VENDOR" "$BT_PRODUCT"
  write_conf "$CEC_PHYS" "$BT_VENDOR" "$BT_PRODUCT"
  write_keep

  disable_old_cec_dbus

  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb || true
  systemctl daemon-reload
  systemctl enable --now "$(basename "$BT_SERVICE")"

  log "installed"
  log "  CEC device     $CEC_DEVICE"
  log "  CEC phys addr  $CEC_PHYS"
  log "  hook           $HOOK"
  log "  BT USB         ${BT_VENDOR}:${BT_PRODUCT}"
  log "old steamos-cec-bt-wake CEC units disabled; BT udev from that project can stay until you --uninstall it"
}

cmd_uninstall() {
  need_root
  systemctl disable --now "$(basename "$BT_SERVICE")" 2>/dev/null || true
  rm -f "$HOOK" "$UDEV_BT" "$UDEV_MTK" "$BT_SERVICE" "$ETC_CONF" "$KEEP"
  rm -rf "$PREFIX"
  udevadm control --reload-rules || true
  systemctl daemon-reload
  log "removed ${NAME} files. Re-enable steamos-cec-bt-wake CEC units if you still want them:"
  log "  sudo systemctl enable cec-wake.service cec-sleep.service"
}

cmd_verify() {
  echo "hook:        $([[ -x $HOOK ]] && echo OK "$HOOK" || echo MISSING)"
  echo "cec device:  $(ls -l "$CEC_DEVICE" 2>&1)"
  if [[ -f $ETC_CONF ]]; then
    echo "--- $ETC_CONF ---"
    cat "$ETC_CONF"
  fi
  if [[ -e $CEC_DEVICE ]] && command -v cec-ctl >/dev/null; then
    echo "--- cec-ctl phys ---"
    cec-ctl -d "$CEC_DEVICE" 2>/dev/null | awk '/Physical Address|Logical Address *:|OSD Name|Adapter Name/'
  fi
  echo "bt service:  $(systemctl is-enabled "$(basename "$BT_SERVICE")" 2>/dev/null || echo absent) / $(systemctl is-active "$(basename "$BT_SERVICE")" 2>/dev/null || echo absent)"
  echo "old cec-wake: $(systemctl is-enabled cec-wake.service 2>/dev/null || echo absent)"
  echo "old cec-sleep: $(systemctl is-enabled cec-sleep.service 2>/dev/null || echo absent)"
  echo "--- USB wakeup (bluetooth-ish) ---"
  for dev in /sys/bus/usb/devices/*; do
    [[ -f $dev/idVendor && -f $dev/power/wakeup ]] || continue
    printf '%s %s:%s wakeup=%s\n' "$(basename "$dev")" "$(tr -d '[:space:]' <"$dev/idVendor")" "$(tr -d '[:space:]' <"$dev/idProduct")" "$(cat "$dev/power/wakeup")"
  done
}

usage() {
  cat <<EOF
$NAME
  --install     install cec-ctl resume hook + Bluetooth USB wakeup
  --uninstall   remove this project's files
  --verify      show current state (no changes)

Env overrides:
  CEC_DEVICE=/dev/cec0
  CEC_PHYSICAL_ADDRESS=4.0.0.0
  BT_VENDOR=0e8d
  BT_PRODUCT=0616
EOF
}

case "${1:-}" in
  --install) cmd_install ;;
  --uninstall) cmd_uninstall ;;
  --verify) cmd_verify ;;
  -h|--help|"") usage ;;
  *) die "unknown arg $1" ;;
esac

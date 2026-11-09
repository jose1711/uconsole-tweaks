# uconsole-tweaks

Small fixes and helpers for a ClockworkPi **uConsole (CM4)** running Debian 13 / XFCE with the
SIM7600G-H LTE module. Tested on one device only; read before you apply anything as root.

## Contents

| Path | What it does |
|---|---|
| `bin/vnstat_ppp0.sh` | xfce4-genmon script showing LTE data usage from `vnstat`: usage in the current plan period, % of the limit (coloured), 7-day sparkline, tooltip with forecast, today/yesterday, peak day, 24 h graph. Click opens `vnstat` daily/hourly tables. Set `LIMIT_GB` and `CYCLE_DAY` (day the plan renews) at the top. |
| `bin/display-auto` | Daemon (listens to RandR events): with HDMI connected uses only the external display and enables xfce4-power-manager presentation mode; otherwise keeps the internal DSI-1 panel rotated `right`. |
| `autostart/display-auto.desktop` | Autostart entry for the above. |
| `bin/lte.sh` | Powers the modem on (`uconsole-4g-cm4.sh enable`). |
| `patches/modemmanager-retry-supported-ip-families.patch` | ModemManager 1.24.0 (Debian) patch: retries loading supported IP families while the SIM7600 firmware is still booting. Without it NetworkManager fails with "IPv4 is unsupported by the modem". |
| `patches/uconsole-4g-cm4-modem-workarounds.patch` | Patch for `/usr/local/bin/uconsole-4g-cm4.sh`: restarts ModemManager if the modem is `failed`/has empty IP families, falls back to `nmcli con up radost`, desktop notifications. |
| `patches/uconsole-sleep-ignore-powerkey-with-external-display.patch` | Patch for `/usr/local/lib/uconsole-sleep/sleep_remap_powerkey.py`: short power-key press is ignored while an external display is connected (blanking the panel is a DRM hotplug that makes X re-enable it unrotated). |

## Install

```sh
./install.sh                      # user scripts + autostart
```

Panel: add an *xfce4-genmon* plugin with command `~/.local/bin/vnstat_ppp0.sh`, period 15 s.
Needs `vnstat` (interface `ppp0`), `jq`, `xterm`.

System patches (as root, review first):

```sh
patch /usr/local/bin/uconsole-4g-cm4.sh < patches/uconsole-4g-cm4-modem-workarounds.patch
# power key: divert the packaged file so upgrades don't overwrite it
dpkg-divert --local --rename --add /usr/local/lib/uconsole-sleep/sleep_remap_powerkey.py
cp /usr/local/lib/uconsole-sleep/sleep_remap_powerkey.py.distrib /usr/local/lib/uconsole-sleep/sleep_remap_powerkey.py
patch /usr/local/lib/uconsole-sleep/sleep_remap_powerkey.py < patches/uconsole-sleep-ignore-powerkey-with-external-display.patch
```

The paths in the sleep patch header may need adjusting. ModemManager has to be rebuilt:

```sh
apt source modemmanager && cd modemmanager-*/
cp ../modemmanager-retry-supported-ip-families.patch debian/patches/
echo modemmanager-retry-supported-ip-families.patch >> debian/patches/series
dch --local +local "retry supported IP families" && dpkg-buildpackage -us -uc -b
sudo dpkg -i ../modemmanager_*.deb ../libmm-glib0_*.deb
sudo apt-mark hold modemmanager libmm-glib0   # security updates then need re-patching by hand
```

The script expects a NetworkManager GSM connection named `radost` (APN `o2internet`, `ipv6.method disabled`); edit to match your carrier.

## License

MIT for the scripts. The patches are derived from ModemManager (GPL-2.0+) and the uConsole packages and stay under their licenses.

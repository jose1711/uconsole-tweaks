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

## Testing the ModemManager fix without rebooting

```sh
test/test-lte-cycle.sh -n 10 -m patched   # 10 power cycles of the modem with the installed (patched) MM
test/test-lte-cycle.sh -n 20 -m ab        # stock vs. patched, 20 cycles each, ends with the patched build installed
```

Uses the original `uconsole-4g-cm4.sh.orig` for power sequencing (so the workarounds do not mask failures), writes
`results.csv` (result, ModemManager time-to-ready, connect time, MM retries per cycle) and prints a summary. Each cycle takes 2-3 minutes,
drops the LTE link, and should be run on a charger. `stock`/`ab` install the Debian ModemManager `.deb` temporarily.

### Results

`-m ab -n 20` on a uConsole CM4 with a SIM7600G-H, 2026-11-11:

| Build | MM initialized | Connected | Retry used |
|---|---|---|---|
| stock 1.24.0-1+deb13u1 | 4/20 | 4/20 | – |
| 1.24.0 + retry patch | 20/20 | 19/20 | 11/20 |

- Stock failed in 16 of 20 cycles: 15 × empty supported IP families, 1 × modem in `failed` state.
- With the patch, 11 cycles needed one retry of `AT+CGDCONT=?`, and each of them would have failed otherwise. Time from
  power-on to an initialized modem was 27–31 s for both builds, so the retry adds no measurable delay.
- The single patched connection failure came from the test itself: `nmcli con up` interrupted an activation
  NetworkManager had just started on its own (`primary AT port is already connected`), not from ModemManager.

## Other reasons the modem can fail

The ModemManager patch only fixes the early-probe race. Some failures have nothing to do with software, and the
workarounds cannot fix them:

- **Low battery / weak power supply.** The SIM7600 draws short current peaks of up to about 2 A when its radio
  transmits. On battery the voltage can then sag so far that the internal USB hub resets. The kernel logs
  `usb usb1-port1: disabled by hub (EMI?), re-enabling...`, and the modem *and the keyboard* drop off USB together.
  In my tests this happened on battery at about 3.57 V, usually right after ModemManager (re)started and the modem
  began registering. Sometimes the hub did not come back at all, and only a reboot recovered it. Test and use LTE on a
  charger or a well-charged battery if possible.
  Check with: `journalctl -k | grep -E 'usb1-port1|USB disconnect'` and
  `cat /sys/class/power_supply/axp20x-battery/voltage_now`.
- **Weak signal (small or badly placed antenna).** The modem transmits at higher power when the signal is weak, which
  makes the current peaks above worse. Registration or the PDP context can also time out
  (`failed to connect modem: Network timeout`), and the modem may reset and re-enumerate on USB again and again.
  A larger external antenna, a better position (near a window, not covered by a hand or a case) or another band or
  operator helps.
  Check with: `mmcli -m any | grep -E 'signal|access tech'`. With the SIM7600 on the AT/PPP setup, ModemManager only
  reports the signal as a percentage; `--signal-get` returns no RSRP/RSRQ/SINR values.
- **SIM not ready / not detected.** `SIM not inserted` (state `failed`, reason `sim-missing`) right after power-on is
  usually the same early-probe race, and `uconsole-4g-cm4.sh enable` recovers from it by restarting ModemManager. If it
  persists, reseat the SIM.
- **Operator-side disconnects.** `LCP terminated by peer` in the pppd log means the network closed the session.
  NetworkManager reconnects on its own within a few seconds.

## Related discussions

I found no ready-made fix for these uConsole problems. These threads are related:

- The same intermittent error on a uConsole ("connection requested both IPv4 and IPv6 dual stack addressing which is
  unsupported by the modem", which later went away by itself):
  [ClockworkPi forum, Apr 2026](https://forum.clockworkpi.com/t/4g-problem-with-trixie-6-12-and-telekom/22234)

- "IPv4 is unsupported by the modem" / empty supported IP families on other modems:
  [modemmanager-devel, Mar 2024](https://lists.freedesktop.org/archives/modemmanager-devel/2024-March/009845.html),
  [modemmanager-devel, Feb 2024](https://lists.freedesktop.org/archives/modemmanager-devel/2024-February/009836.html),
  [ModemManager issue 705](https://gitlab.freedesktop.org/mobile-broadband/ModemManager/-/issues/705) (u-blox R412m, IP capabilities not detected over serial)
- uConsole 4G module setup: [ClockworkPi forum](https://forum.clockworkpi.com/t/how-do-i-configure-use-the-4g-module/10431).
  The log in post #3 also shows `couldn't load supported IP families: Unknown error` on a SIM7600G-H, but the cause
  there was a PIN-locked SIM, not the probing race described here.
- Making an external monitor the main screen (manual ARandR layout, no automation):
  [ClockworkPi forum](https://forum.clockworkpi.com/t/uconsole-with-hdmi-portable-monitor/13893)

## License

MIT for the scripts. The patches are derived from ModemManager (GPL-2.0+) and the uConsole packages and stay under their licenses.

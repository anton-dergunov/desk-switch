# desk-switch

A software KVM switch for two Macs sharing one desk. One key moves the monitor,
the mouse and the keyboard from one Mac to the other.

## Why

The desk has one monitor (Philips 49B2U5900), one Logitech MX Master 4 and one
ZMK split keyboard (Eyelash Sofle), shared by a personal and a work MacBook.
Without help, a switch means three separate actions, and the monitor's own
input menu is the slowest of them.

## How it works

- **Who starts the switch:** only the Mac that currently has the peripherals
  can talk to them, so the keyboard tells that Mac first. A macro key on the
  Sofle taps a hotkey (F18 means "to personal", F19 means "to work"), waits
  about 100 ms, and then switches its own Bluetooth profile
  (`&bt BT_SEL n`). The macros live in the keyboard config fork,
  [anton-dergunov/sofle-j-keyboard-zmk](https://github.com/anton-dergunov/sofle-j-keyboard-zmk).
- **What the Mac does:** the menu-bar agent catches the hotkey and switches:
  - **Mouse:** sends a Logitech HID++ 2.0 `CHANGE_HOST` request over Bluetooth.
    The feature index is looked up on the device, not hard-coded.
  - **Monitor:** writes the DDC/CI input-source code (VCP `0x60`).
- **Destinations, not toggles:** every command names where to go. Asking for
  the Mac you are already on just re-applies its settings, which also brings
  back a monitor or mouse that ended up on the wrong Mac. So the config file
  is identical on both Macs.
- **Only Apple frameworks:** no third-party tools, no `sudo`, no kernel
  extension and no network access. DDC uses the same private `IOAVService`
  calls as m1ddc and MonitorControl; HID++ uses `IOHIDManager`; hotkeys use
  Carbon `RegisterEventHotKey`, which needs no Accessibility permission.

## Install (on each Mac)

```
git clone <this repo> ~/projects/tools/desk-switch
cd ~/projects/tools/desk-switch
./build.sh
```

`build.sh` compiles `Sources/*.swift` and packages
`~/Applications/DeskSwitch.app` (ad-hoc signed, no Dock icon). It links the CLI
as `~/.local/bin/desk-switch` and installs the LaunchAgent
`com.anton.deskswitch`, which starts the agent at login. The build needs only
the Xcode Command Line Tools.

**Input Monitoring:** macOS opens the mouse's control channel only for apps
with this permission. The agent asks for it at first launch, but macOS often
leaves an agent like this off the list. In that case, use **Grant Input
Monitoring…** in its menu. It opens the settings pane and shows
`~/Applications/DeskSwitch.app` in Finder. Drag the app into the list (or
add it with **+**) and turn it on. The monitor switch works without it.

macOS ties the permission to the exact binary. So `build.sh` rebuilds only
when the sources changed, and then clears the old entry so macOS asks again.

## Config

`~/.config/desk-switch/config.json` is written on first run. Keep it the same
on both Macs:

```json
{
  "hosts": [
    { "name": "personal", "hotkey": "F18" },
    { "name": "work", "hotkey": "F19" }
  ],
  "displays": [
    { "name": "PHL 49B2U5900", "inputs": { "personal": 21, "work": 15 } }
  ],
  "logitech": [
    { "name": "MX Master 4", "productId": "0xB042", "channels": { "personal": 2, "work": 3 } }
  ]
}
```

- **`hosts`:** order sets the menu order. `hotkey` takes `F1`–`F20`, a letter
  or a digit, optionally with `cmd`, `ctrl`, `opt` and `shift`
  (`"ctrl+opt+cmd+2"`).
- **`displays[].name`:** a substring of the monitor's EDID name, as shown by
  `desk-switch status`. Omit it to match every external display.
- **`displays[].inputs`:** the DDC input code per host. On this Philips,
  21 = USB-C, 15 = DisplayPort 1, 17 = HDMI 1.
- **`logitech[].channels`:** the Easy-Switch channel per host, 1–3 as printed
  on the device. A Logitech keyboard works too: add another entry with its
  product ID.

Pick **Reload Config** in the menu after editing.

## CLI

```
desk-switch status              # displays with their input, Logitech devices with their channel
desk-switch to work             # what the hotkey does
desk-switch ddc get 0x60        # read a VCP code
desk-switch ddc set 0x60 15     # write one, e.g. to find a monitor's input codes
```

From a terminal, the CLI uses the terminal's own Input Monitoring permission.

## Troubleshooting

- **The log:** `~/Library/Logs/desk-switch.log` has one line per device for
  every switch.
- **`cannot open (0xe00002e2)`:** Input Monitoring is missing for the app, or
  for the terminal if you ran the CLI.
- **`not connected to this Mac`:** the mouse is already on another channel.
  Use its Easy-Switch button to bring it back.
- **Monitor input unreadable on one Mac:** some USB-C→DisplayPort adapters
  don't pass DDC through. Try another adapter or cable.
- **Hotkey does nothing:** check the log for `cannot register hotkey`, which
  means another app has claimed that key.

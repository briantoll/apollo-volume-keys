# Apollo Volume Keys

Makes the Mac's volume and mute keys control the **MONITOR** level of a
Universal Audio Apollo interface.

The Apollo exposes no volume control to macOS, so the volume keys normally do
nothing when it is the system output. This small menu-bar app catches those
keys and sets the monitor level through the UA Mixer Engine instead.

> Unofficial. Not made, supported, or endorsed by Universal Audio.

## What it does

| Key | Action |
|---|---|
| Volume up / down | Monitor level ±1 dB per press, ±2 dB per repeat while held |
| Mute | Toggles the monitor mute |

- The keys are taken over **only while the Apollo is the default output** and
  the mixer engine is reachable. Otherwise they pass through to macOS as usual.
- The menu-bar item shows the current level (`-32 dB`) or `Muted`, and follows
  the hardware knob and UAD Console live. It is there **only while the Apollo
  is connected**; unplug or power off the Apollo and it disappears.
- Until Accessibility is granted the item reads `⚠︎ Vol`; click it to open the
  setting.
- The item has no menu. Start at login and quitting are done from the
  [command line](#command-line).
- **There is no volume ceiling.** A held volume-up key will run all the way to
  0 dB, the Apollo's maximum. Mind your monitors.

## Requirements

- macOS 13 or later
- An Apollo with UA's software installed (UA Connect / UAD Console), so the
  UA Mixer Engine is running
- Xcode Command Line Tools to build (`xcode-select --install`)

Developed and tested on an Apollo Twin X Gen 2 over Thunderbolt, macOS 27.
Other Apollo models should work (the app finds the output UA marks as
`Monitor`) but are untested.

## Install

```sh
./build.sh install
```

This compiles `main.swift`, wraps it in `Apollo Volume Keys.app`, copies it to
`~/Applications`, launches it, and puts the `apollo-volume-keys` command in
`~/.local/bin` (which must be on your `PATH`). `./build.sh` on its own only
builds into `./build`.

Then grant **Accessibility** when prompted (System Settings ▸ Privacy &
Security ▸ Accessibility). macOS requires it for an app to swallow the volume
keys.

The app is ad-hoc signed, and macOS ties the Accessibility grant to that
signature. After a rebuild, remove the app from the Accessibility list and add
it again.

## Command line

| Command | Does |
|---|---|
| `apollo-volume-keys status` | Shows whether the app is running, whether it starts at login, and the Apollo's state |
| `apollo-volume-keys start` | Launches the menu-bar app |
| `apollo-volume-keys quit` | Quits it |
| `apollo-volume-keys login on` / `off` | Starts the app at login, or stops doing so |

Since the menu-bar item is hidden while the Apollo is disconnected, `status` is
how to tell that the app is running:

```
App:            running
Start at login: on
Apollo:         connected, -32 dB
```

The command is the app's own binary run with an argument.

## Resource use

Measured on an Apple M1 Max, macOS 27.0.1, release build, with the app idle in
the menu bar and connected to the mixer engine:

| Metric | Value |
|---|---|
| Memory (physical footprint) | 20 MB |
| Memory (resident size, includes shared system frameworks) | 69 MB |
| CPU while idle | 0.0% (0.02 s of CPU time over 60 s) |
| Idle wake-ups reported by `top` | 0 |
| Binary size | 123 KB |

Method: `footprint -p`, `ps -o rss,time`, and
`top -l 7 -s 10 -stats cpu,mem,idlew,power` over a 60-second idle window.

The only recurring work is one small keepalive write to the local socket every
3 seconds. Level changes are pushed by the engine, so nothing is polled.

## How it works

The UA Mixer Engine listens on TCP `127.0.0.1:4710` and speaks an undocumented
text protocol that UAD Console also uses: `get`, `set` and `subscribe` commands
terminated by a NUL byte, with NUL-terminated JSON replies.

The app:

1. walks `/devices` → `outputs` to find the output whose `IOType` is `Monitor`;
2. subscribes to its `CRMonitorLevel` (dB, -96 to 0) and `Mute` values;
3. subscribes to the device's `DeviceOnline` value, because the engine keeps
   reporting the last level for an Apollo that has been unplugged;
4. installs an event tap for system-defined (media key) events and, on a
   volume or mute key, writes the new value back with `set`.

Because the API is undocumented, **a UA software update could break this.**

## Privacy

- The event tap is registered for media-key events only, so ordinary
  keystrokes are never delivered to the app.
- The only network connection is to `127.0.0.1:4710`. Nothing leaves the Mac.
- It writes no files of its own (macOS records the menu-bar item's visibility
  in the app's preferences) and has no dependencies beyond system frameworks.

## Uninstall

```sh
apollo-volume-keys login off
apollo-volume-keys quit
rm -r ~/Applications/"Apollo Volume Keys.app" ~/.local/bin/apollo-volume-keys
```

## Credits

The mixer engine protocol details were learned from
[apollo-monitor-menubar](https://github.com/nicholaspsmith/apollo-monitor-menubar),
a fuller-featured app that does the same job with a slider, overlay and
engine recovery. This is an independent, minimal reimplementation.

## License

MIT. See [LICENSE](LICENSE).

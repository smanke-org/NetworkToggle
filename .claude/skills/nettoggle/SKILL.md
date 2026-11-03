---
name: nettoggle
description: Drive NetworkToggle, the menu bar network switcher on this Mac, from the shell with the `nettoggle` command: see the active connection, the service order, the VPN and Wi-Fi, switch between Wi-Fi and wired connections (docks, Ethernet), reorder services, turn Wi-Fi on or off, move connections left on Wi-Fi, and change the automatic switching settings. Use when the user asks which network the Mac is on, wants to switch or reorder connections, or names NetworkToggle.
---

# NetworkToggle

`nettoggle` runs commands in the NetworkToggle app, through the same code as its menu. If the
app is closed, the command opens it in the background. If `nettoggle` isn't on PATH, use
`/Applications/NetworkToggle.app/Contents/MacOS/NetworkToggle` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Every command that changes the network (`services switch`, `services reorder`, `services undo`,
  `wifi on`, `wifi off`, `connections move`) only reports what it would do. Show the user that
  report and ask before you run it again with `--yes`. A switch or Wi-Fi off can drop open
  connections, your own included.
- With `--yes` the change runs in the background. Run `nettoggle status --json` until `busy` is
  null; then `lastAction` or `lastError` says how it went.
- Changes need the helper (`helper` in status is `ready`). If it isn't, ask the person to open
  the NetworkToggle menu and finish setup; never try to get around it.
- A service is named by its name (`Wi-Fi`), interface (`en0`) or id (8 characters; any unique start).
- To try something without the real app, run a Debug build with `APP_STORE=/tmp/nettoggle-test`
  in front. A test copy reads the network but refuses `--yes`.

## Main commands

| Command | Does |
| --- | --- |
| `nettoggle status --json` | Active connection, VPN, Wi-Fi, idle wired links, helper, busy, last result |
| `nettoggle services list --json` | Every service in macOS's order, with address, router, speed, active |
| `nettoggle services switch [<service>] [--reconnect] [--yes] --json` | Make one active; no service = fastest wired |
| `nettoggle services reorder --order "Ethernet,Wi-Fi" [--yes] --json` | Put services on top in that order |
| `nettoggle wifi off [--yes] --json` / `nettoggle connections move [--yes] --json` | Wi-Fi off / move connections off Wi-Fi |
| `nettoggle settings set --wired-arrival ask\|automatically\|ignore --json` | What happens when a wired link appears |

Everything else: `nettoggle help`, and `nettoggle help <command>` for its options.

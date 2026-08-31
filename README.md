# Homebridge

Control the HomeKit accessories your [Homebridge](https://homebridge.io/) bridges, from the Omarchy bar. A live count of what is on, one click to toggle any light, switch or outlet, and a slider to dim a light — without opening the Home app or a phone.

## What it shows

One row per **controllable** accessory — anything Homebridge bridges that exposes a writable `On` characteristic (lights, switches, outlets, fans):

* Its name and type.
* Whether it is on — a filled dot and the state on the right (`On`, `Off`, or the brightness for a dimmable light).
* For a dimmable light, a brightness rail you can drag.

The bar carries the number of accessories that are **on**, and says nothing at all when your home is at rest. It turns urgent only when the server cannot be reached.

## Controlling things

* **Click a row** to toggle it on or off. It is your home, so this is immediate and unconfirmed — the press shows on screen at once and is reconciled against the server a moment later.
* **Drag the rail** on a dimmable light to set its brightness. A drag sends one request, on release.
* **Keyboard:** `↑`/`↓` select, `space` toggles, `←`/`→` (or `-`/`+`) nudge brightness by 10%, `r` refresh, `l` sign in, `e` edit config.

## Sign in

Press `l` in the panel, or run:

```bash
bash ~/.config/omarchy/plugins/ianswope.homebridge/bin/omarchy-homebridge-login
```

It asks for your Homebridge URL, a username and a password (hidden), verifies them against the server, and writes the config itself. It must run in a terminal.

### Use a dedicated, non-admin Homebridge user

Homebridge's UI (config-ui-x) issues no long-lived API key — only short session tokens — so unlike a token-based plugin, this one has to **store a username and password** to refresh them. To make that credential the least it can be, create a **dedicated non-admin user** for the plugin:

> Homebridge UI → **Users** → add a user → turn **admin off**.

A non-admin user can view and control accessories but cannot change Homebridge's settings, restart the server, or read its config. That is exactly the authority this plugin needs and no more, so a leaked credential can only toggle your lights — not own your bridge.

**What it writes** — `~/.config/omarchy-homebridge/config.json`, mode `600`:

```json
{
  "url": "http://homebridge.local:8581",
  "username": "omarchy-bar",
  "password": "…",
  "token": "…",
  "token_expires": 1730000000
}
```

`token`/`token_expires` are a cached session token the poller refreshes on its own; you only ever fill in the first three, and the sign-in does even that for you.

## How it talks to Homebridge

Three small helpers in `bin/`, each emitting or acting on JSON:

* `omarchy-homebridge-status` — `GET /api/accessories`, reduced to the controllable subset. Read-only; runs on the refresh timer.
* `omarchy-homebridge-set` — `PUT /api/accessories/{uniqueId}` with `{characteristicType, value}`. The only thing that changes a device. `characteristicType` is allow-listed to `On` and `Brightness`.
* `omarchy-homebridge-login` — `POST /api/auth/login`, writes the config.

They share `homebridge-config.sh`, which owns the one safe reader of the config file and the token-refresh path.

## What it is careful about

The credential is real and the writes are real, so the helpers treat the config file and the server as things that can change or misbehave underneath them:

* The config is read **once**, through a single `O_NOFOLLOW`/`O_NONBLOCK`, size-bounded reader — never reopened by path — so a symlink swapped in between a check and a use is refused at the kernel, and a poll that runs every few seconds cannot be turned into an unbounded read.
* The **password never touches a command line or a `curl --config` document.** It travels only as a JSON body in a `0600` `mktemp` file; the token, which does reach an `Authorization` header, is validated to a JWT shape first.
* Every **value sent to a device is proven before it is built** — `On` is exactly `true`/`false`, `Brightness` is an integer `0–100` — because a value reaching Bash arithmetic or a request is code, not data.
* Replies are **bounded twice** (declared size and size-on-disk), because a chunked reply can overrun a `Content-Length` limit.
* The config is written through an `mktemp`/`O_EXCL` file and `mv`'d into place, so an interrupted write cannot leave a half-written credential and no predictable name can be pre-planted as a symlink.

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `refreshIntervalSec` | `15` | How often to poll, in seconds (5–300). |
| `showCount` | `true` | Show the number of accessories that are on next to the icon. |
| `configPath` | `""` | Override the config location (absolute path). |

## Requirements

`curl` and `jq` on `PATH`, and a reachable Homebridge running [homebridge-config-ui-x](https://github.com/homebridge/homebridge-config-ui-x).

# Homebridge

Your home in the Omarchy bar. Arm and disarm the security system [Homebridge](https://homebridge.io/) bridges, toggle and dim the lights, and read the sensors — without opening the Home app or reaching for a phone.

## What it shows

One row per accessory this plugin has something to say about, in three kinds:

| Kind | What it is | What you can do |
|---|---|---|
| **Security system** | anything with a writable `SecuritySystemTargetState` | set Home / Away / Night / Off — it asks first |
| **Switch** | a writable `On`: lights, switches, outlets, fans | click to toggle; drag the rail to dim |
| **Sensor** | contact, motion, smoke, CO, leak, occupancy, temperature, humidity | read it |

Everything else Homebridge bridges is left out on purpose. That is an allow-list, not a deny-list: a bridge with four cameras carries eight camera stream-management services and four microphones, and letting those through would bury the four rows you actually opened the panel for.

Each row carries its name, what it is, and its state on the right. A sensor whose battery is going says so under its name, because a flat battery is the reason a door looks permanently shut.

## The bar

The bar says as little as it can get away with:

* **Nothing** when the alarm is off and no lights are on. That is a house with someone in it, and a widget that announces it is noise.
* **`Away`** (or `Home`, `Night`) while the system is armed — because leaving with it disarmed is the mistake this can actually prevent.
* **`Away 2`** if you also left two lights on.
* **`Alarm`**, in the urgent colour, if the system is going off — or **`Smoke`**, **`CO`**, **`Leak`** if a sensor is reporting one. These show whatever your bar settings say, because that is not a preference.

A low battery never reaches the bar. It is true for weeks at a time, and an icon that has been amber since March is an icon nobody reads — so it goes in the panel, where opening it finds it.

## Controlling things

* **Click a light** to toggle it. It is your lamp, so this is immediate and unconfirmed — the press shows on screen at once and is reconciled against the server a moment later.
* **Drag the rail** on a dimmable light to set its brightness. A drag sends one request, on release.
* **Press a mode** on the security system to arm or disarm it. This one **asks first**, and the confirmation says where the system is now and where it is going. Unlike a lamp, the worst case here is a house left unlocked.
* **Keyboard:** `↑`/`↓` select, `space` toggles or sets, `←`/`→` walk the security modes or nudge brightness by 10%, `r` refresh, `l` sign in, `e` edit config.

The cursor only ever lands on a row that does something. Sensors are skipped, because pressing space on a motion sensor would do nothing.

### Arming is not instant

An away mode gives you a minute to leave the house, and the row says `Arming…` for the whole of it. That gap is the server's own — target and current state disagree until the house is actually secured — so the panel reports it rather than claiming the house is safe the moment you pressed the button.

### Only the modes your system has

A security system declares which modes it accepts. A SimpliSafe bridge, for instance, declares Home, Away and Off and has **no Night mode at all**. The panel offers exactly what the accessory declares, so there is never a button whose only possible outcome is the server refusing it.

## Install

Requires Omarchy 4 ("Quattro", the Quickshell bar), plus `curl` and `jq`.

```bash
omarchy plugin add https://github.com/ianswope/omarchy-homebridge.git
omarchy plugin enable ianswope.homebridge
```

To put it somewhere else in the bar:

```bash
omarchy bar move ianswope.homebridge --section right
```

Then sign in, below. Until you do, the panel says so and the bar stays quiet.

## Remove

```bash
omarchy plugin remove ianswope.homebridge
```

That takes the plugin and its bar entry with it. Your Homebridge credential
lives **outside** the plugin directory, so removing the plugin deliberately
leaves it alone — delete it yourself if you are done with it:

```bash
rm -rf ~/.config/omarchy-homebridge
```

Nothing else on your system is touched: the plugin writes only that one file,
installs no packages, and changes no Homebridge settings — the non-admin user
it asks for cannot change them even if it tried.

## Sign in

Press `l` in the panel, or run:

```bash
bash ~/.config/omarchy/plugins/ianswope.homebridge/bin/omarchy-homebridge-login
```

It asks for your Homebridge URL, a username and a password (hidden), verifies them against the server, and writes the config itself. It must run in a terminal.

**Accessory control has to be on.** Homebridge only exposes accessories over its API when it is running with HomeKit accessory control enabled (Homebridge UI → Settings → *Homebridge Settings* → **Enable HomeKit Accessory Control**). Without it, `/api/accessories` comes back empty and the panel will say there is nothing to show.

### Use a dedicated, non-admin Homebridge user

Homebridge's UI (config-ui-x) issues no long-lived API key — only short session tokens — so unlike a token-based plugin, this one has to **store a username and password** to refresh them. To make that credential the least it can be, create a **dedicated non-admin user** for the plugin:

> Homebridge UI → **Users** → add a user → turn **admin off**.

A non-admin user can view and control accessories but cannot change Homebridge's settings, restart the server, or read its config. That is exactly the authority this plugin needs and no more.

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

* `omarchy-homebridge-status` — `GET /api/accessories`, reduced to the three kinds above. Read-only; runs on the refresh timer.
* `omarchy-homebridge-set` — `PUT /api/accessories/{uniqueId}` with `{characteristicType, value}`. The only thing that changes a device. `characteristicType` is allow-listed to `On`, `Brightness` and `SecuritySystemTargetState`.
* `omarchy-homebridge-login` — `POST /api/auth/login`, writes the config.

They share `homebridge-config.sh`, which owns the one safe reader of the config file and the token-refresh path.

## What it is careful about

The credential is real and the writes are real — and one of them is a burglar alarm — so the helpers treat the config file and the server as things that can change or misbehave underneath them:

* The config is read **once**, through a single `O_NOFOLLOW`/`O_NONBLOCK`, size-bounded reader — never reopened by path — so a symlink swapped in between a check and a use is refused at the kernel, and a poll that runs every few seconds cannot be turned into an unbounded read.
* The **password never touches a command line or a `curl --config` document.** It travels only as a JSON body in a `0600` `mktemp` file; the token, which does reach an `Authorization` header, is validated to a JWT shape first.
* Every **value sent to a device is proven before it is built** — `On` is exactly `true`/`false`, `Brightness` is an integer `0–100`, and a security mode is matched literally against the four HomeKit defines rather than range-checked, because that value's neighbours are not merely wrong but a different instruction to an alarm.
* **Arming is never done on a script's say-so.** The IPC handler can report the security state but cannot set it: the only path to a write goes through the confirmation in the panel.
* A **confirmation is bound to the accessory it was asked about**, by id. The list behind the dialog is replaced every few seconds, and resolving by position instead would arm or disarm whatever had moved into the old row.
* Replies are **bounded twice** (declared size and size-on-disk), because a chunked reply can overrun a `Content-Length` limit.
* The config is written through an `mktemp`/`O_EXCL` file and `mv`'d into place, so an interrupted write cannot leave a half-written credential and no predictable name can be pre-planted as a symlink.
* Accessory names come off the server and reach a QML `Text`, which defaults to `AutoText` — so they are stripped of markup at the one parse boundary they cross.

## Tests

```bash
node test/model-test.js     # what the panel decides, on plain data
bash test/helpers-test.sh   # the helpers, against a stand-in Homebridge
```

`model-test.js` runs `Model.js` under `node` with no shell, no bar and no server. `helpers-test.sh` starts `test/fake-homebridge.py` — a small stand-in for config-ui-x that speaks the three routes this plugin uses and keeps accessory state in memory — on a loopback port, signs in against it for real, and then checks both what the helpers printed and what the server saw: that a cached token is reused rather than re-fetched, that a token rejected before its expiry triggers one re-login and retry, that a `PUT` is visible in the next poll, that a house mid-arming reports itself mid-arming, and that a refused value never reaches the server at all. Every config it writes lives in a `mktemp` directory; nothing touches `~/.config/omarchy-homebridge`. `python3` is needed for the second one.

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `refreshIntervalSec` | `15` | How often to poll, in seconds (5–300). |
| `showCount` | `true` | Show the number of lights and switches that are on. |
| `showSecurity` | `true` | Show the security system's mode in the bar while it is armed. |
| `temperatureUnit` | `Celsius` | How temperatures are read out. HomeKit always reports Celsius. |
| `configPath` | `""` | Override the config location (absolute path). |

## Requirements

`curl` and `jq` on `PATH`, and a reachable Homebridge running [homebridge-config-ui-x](https://github.com/homebridge/homebridge-config-ui-x) with HomeKit accessory control enabled.

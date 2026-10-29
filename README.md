# Head Sync

**See where other drivers are looking.** A small app for Assetto Corsa that shares your head movement with other players online, so when you turn to check your mirror or glance across at the car alongside, they actually see your driver do it.

Without it, everyone else sees your driver staring straight ahead like a mannequin, however much you're looking around in VR.

## What it does

- **Turning and nodding:** look left, right, up or down and your driver does the same on other people's screens
- **Head tilt:** cock your head and it tilts
- **Leaning:** lean in, out or sideways and the head follows (capped, so nobody turns into a giraffe)
- **Recentres with VR:** when you recentre your headset, it resets too
- **Light on the network:** about 15 tiny updates a second, smoothed out at the other end

Works with VR, and should work with anything else that moves your cockpit head (TrackIR and the like).

## Before you start

| You need | Notes |
|---|---|
| Assetto Corsa + Content Manager | |
| Custom Shaders Patch **0.2.0** or newer | Check under CM → Settings → Custom Shaders Patch |
| The app installed | **Everyone** who wants to see heads move needs it. Anyone without it just sees normal static heads. |
| A suitable server | AssettoServer with client messages switched on (see [Hosting a server](#hosting-a-server)) |

## Install

### Easy way (Content Manager)

1. Download the latest `HeadSync-vX.X.zip` from the [Releases](https://github.com/benvince/ac-headsync/releases) page. Don't unzip it.
2. Drag the zip onto the Content Manager window.
3. Click **Install** when CM asks.

### Manual way

Unzip it and copy the `HeadSync` folder into `assettocorsa/apps/lua/`, so you end up with:

```
assettocorsa/apps/lua/HeadSync/
├── manifest.ini
└── HeadSync.lua
```

That's it. The app starts on its own when you join a server.

## Check it's working

1. Join a server that supports it, with a friend who also has the app.
2. In-game, open the apps sidebar on the right-hand edge of the screen and click **Head Sync**.
3. Look for **Players sending heads**. If it shows a number, you're connected. If it says 0 while others are on, see [Troubleshooting](#troubleshooting).

No VR to hand? Tick **Test mode** and drag the sliders, or tick **Auto sweep**, then look at your car from an outside camera (F1 or F5). Your own driver's head will move, and so will it on everyone else's screens.

## The app window

| Option | What it does |
|---|---|
| **Enabled** | Turns the whole thing on or off |
| **Show head tilt / Show leaning** | Turn these off if they look odd on your end |
| **Test mode** | Fake head movement from sliders, for testing without VR |
| **Recentre** | Sit normally, look ahead, press it. Sets your "neutral" for tilt and lean. |
| **Auto-recentre with VR recentre** | Does the above automatically whenever you recentre your headset |
| **Players sending heads** | How many other players you're receiving from |
| **Re-find head bones** | Use it if someone's head ends up facing somewhere strange |
| **Scan / Dump node tree** | Debug tools for unusual driver models (see [Troubleshooting](#troubleshooting)) |

## Hosting a server

Head Sync sends its data through the server, so the server has to allow it. The stock Kunos server doesn't seem to, so you'll need **[AssettoServer](https://github.com/compujuckel/AssettoServer)** (free) with two settings switched on.

Add these to your server's `extra_cfg.yml`. There's a copy in [`server/extra_cfg.yml`](server/extra_cfg.yml).

```yaml
EnableClientMessages: true
MinimumCSPVersion: 2651
```

The minimum CSP version isn't optional: AssettoServer won't start with client messages on unless it's at least 2651.

### Setting up AssettoServer with Content Manager

1. Download `assetto-server-win-x64.zip` from the [AssettoServer releases](https://github.com/compujuckel/AssettoServer/releases).
2. Go to `assettocorsa/server`, **back it up**, then delete everything in it except the `presets` folder.
3. Extract AssettoServer there and rename `AssettoServer.exe` to `acServer.exe`. CM will now launch it without knowing the difference.
4. In CM's **Server** tab, make a preset: one track, your cars, **Practice session only** (AssettoServer doesn't do race or qualifying yet).
5. Put `extra_cfg.yml` (with the settings above) in the preset's folder, next to `server_cfg.ini`.
6. Hit **Run**. The console should mention AssettoServer at the top.
7. Allow **TCP + UDP 9600** and **TCP 8081** through your firewall.
8. Players join through CM → **Online** → **+** → `your-ip:8081`.

**Playing with mates without port forwarding?** [Tailscale](https://tailscale.com) works well. Install it on both PCs, share your machine with your friends from the Tailscale admin page, and have them join using your `100.x.x.x` address. If Windows treats the Tailscale network as "Public", allow the ports there too.

## Troubleshooting

| Problem | Fix |
|---|---|
| **Players sending heads: 0** | The server isn't passing messages along. Check it's AssettoServer with `EnableClientMessages: true`, and that the other player has the app (and the same version). |
| **Server won't start: "minimum required CSP version of 0.2.0 (2651)"** | Set `MinimumCSPVersion: 2651` in `extra_cfg.yml` |
| **Can't find `extra_cfg.yml`** | Just create it in the preset folder. Anything you leave out uses AssettoServer's defaults. |
| **Your yaw/pitch numbers don't move** | Check **Head bones on your car** isn't 0. If it is, your driver model uses unusual bone names, so see below. |
| **Heads turn the wrong way, or tilt instead of turning** | Flip the `_SIGN` or swap the `_AXIS` settings at the top of `HeadSync.lua` |
| **A head faces somewhere odd** | Press **Re-find head bones** |
| **Tilt or lean is off after recentring** | Press **Recentre** while sitting normally and looking ahead |
| **Necks look stretchy when leaning** | Lower `LEAN_SCALE`, or untick **Show leaning** |
| **Unusual driver model** | Press **Dump node tree**. It writes `nodes.txt` to the app folder. Find the head bone in it and put its name in `HEAD_FILTER`. |

## Settings

These live at the top of `HeadSync/HeadSync.lua`. You shouldn't need them, but just in case:

| Setting | Default | What it's for |
|---|---|---|
| `HEAD_FILTER` / `NECK_FILTER` | `DRIVER:RIG_Head` / `DRIVER:RIG_Nek` | Bone names on the standard Kunos driver |
| `SEND_HZ` | `15` | Updates per second |
| `SMOOTHING` | `10` | Higher is snappier, lower is smoother |
| `MAX_YAW` / `MAX_PITCH` / `MAX_ROLL` | 80° / 40° / 35° | Limits, so nobody goes full owl |
| `MAX_LEAN` / `LEAN_SCALE` | 20 cm / 1.0 | Lean limit and strength |
| `*_SIGN` | `1` | Flip to `-1` if a movement goes the wrong way |
| `*_AXIS` | Y / X / Z | Bone rotation axes, for oddly built driver models |
| `AUTO_RECENTRE`, `SNAP_*` | on | How a VR recentre is detected |
| `RECENTRE_KEY` | none | Optional key to recentre, e.g. `ui.KeyIndex.Home` |

## How it works

1. CSP already turns your own driver's head to follow your headset. Head Sync reads that head bone and works out your turn, nod, tilt and lean relative to the car.
2. It sends those numbers through the server about 15 times a second, using CSP's online messaging (`ac.OnlineEvent`).
3. When numbers arrive from another player, it smooths them and moves that car's driver head from its resting pose. It does this for every copy of the driver model, since cars carry more than one level of detail.

## Limitations

- Only works on servers that pass CSP client messages along (AssettoServer with the settings above).
- Everyone involved needs the app, and the same version of it.
- Built around the standard Kunos driver rig. Most cars use it, but custom driver models might not.
- Leaning moves just the head, not the shoulders, so very big leans can look a bit odd.

## Making a release (for maintainers)

- **Automatically:** push a tag like `v1.0` and the GitHub Action builds the zip and attaches it to a release.
- **Locally:** run `build.ps1` in PowerShell. It creates `HeadSync-v<version>.zip`, ready to drag onto Content Manager.

The version comes from `VERSION` in `HeadSync/manifest.ini`.

## Licence

[MIT](LICENSE). Use it, change it, pinch bits of it. Just keep the licence notice if you reuse the code.

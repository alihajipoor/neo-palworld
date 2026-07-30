# Neo Palworld Dedicated Server

This project is Ubuntu-first for running a public Palworld 1.0 dedicated server.

Main script:

- `palworld-manager.sh`

Optional local helper/reference:

- `PalworldServerManager.ps1`

The Ubuntu manager opens an interactive menu by default. From that menu it can install SteamCMD, install/update Palworld Dedicated Server, create a `systemd` service, edit `PalWorldSettings.ini`, manage backups/restores, add UFW firewall rules, configure mods, schedule automatic backups, schedule auto-announcements, and call the local Palworld REST API.

## Recommended Server

Official requirements are 4+ CPU cores and 16 GB RAM, with 32 GB+ recommended for larger public servers. Use SSD storage. Low-performance storage can risk save corruption.

For a public server, also check your host provider firewall/security group. The script can configure Ubuntu UFW, but it cannot change your cloud provider or router rules.

## Quick Start On Ubuntu

Copy this repo/folder to your Ubuntu server, then run one command:

```bash
cd /path/to/Neo-Palworld
sudo bash palworld-manager.sh
```

You will get a menu:

```text
Main Menu

1) Install / initial setup
2) Start / stop / status / logs
3) Update server
4) Backups and restore
5) Settings and presets
6) Network / firewall / ports
7) REST API tools
8) Server extras / fun tools
9) Web panel
10) Mods
11) Doctor / health check
h) Help
q) Quit
```

For first setup, use the menu in this order:

1. `Install / initial setup`
2. `Network / firewall / ports`
3. `Start / stop / status / logs`

The install creates:

- Server files: `/opt/palworld/server`
- Manager state: `/opt/palworld/manager.env`
- Backups: `/var/backups/palworld`
- Service: `palworld.service`

For public play, open/forward:

```text
UDP 8211 -> this Ubuntu server
```

Do not expose REST API or RCON to the public Internet.

## Daily Use

Run the same menu whenever you need to manage the server:

```bash
sudo bash palworld-manager.sh
```

Use it for starting/stopping, updates, backups, restores, settings, REST API tools, mods, logs, and health checks.

For a restart that warns players in the center of the game screen, use:

```text
Start / stop / status / logs -> Restart with 60-second in-game warning
```

## Settings

Open the menu and choose `Settings and presets`.

The menu can:

- Show all current settings.
- Edit common settings like server name, description, passwords, max players, EXP rate, capture rate, drop rate, and hatch time.
- Set custom `Key=Value` pairs.
- Apply presets.
- Use guided advanced settings for gameplay rates, survival/combat, bases/guilds/world travel, PvP switches, and server identity.

Available presets:

- `launch-public`
- `balanced`
- `casual`
- `pve`
- `boosted`
- `builder`
- `breeding`
- `event-weekend`
- `performance`
- `pvp`
- `raid`
- `no-raids`
- `hardcore`

The `pvp` preset enables player-vs-player combat and applies a PvP-oriented baseline:

- Enables `bIsPvP`, player damage, and defense against other guild players.
- Uses full death drops and allows other guilds to pick up death penalty drops.
- Disables health/attack stat enhancement for fairer PvP balance.
- Limits guild/base scale with `GuildPlayerMaxNum=4`, `BaseCampMaxNumInGuild=2`, and `MaxBuildingLimitNum=1000`.
- Enables fast travel but restricts it to bases.
- Keeps player characters present after logout.
- Adds respawn/block penalty tuning.

Other useful presets:

- `boosted`: faster XP, capture, gathering, drops, and eggs.
- `builder`: easier building with reduced deterioration and higher base/build limits.
- `breeding`: very fast eggs and lower Pal upkeep.
- `event-weekend`: short-term high XP/drop/capture event mode.
- `raid`: enables invader/raid-style pressure.
- `no-raids`: disables raids/non-login penalty and reduces base deterioration.

If fast travel statues show `Disabled due to World Settings`, open:

```text
Settings and presets -> Enable fast travel safely
```

That creates a backup, stops Palworld if it is running, writes the fast-travel keys while the game is not holding the config in memory, disables any `WorldOption.sav` override if present, and starts Palworld again. The script writes:

```ini
bEnableFastTravel=True
bIsFastTravelDisabled=False
bEnableFastTravelOnlyBaseCamp=False
```

Restart Palworld after saving.

To let friends bring Pals through the Global Palbox, open the same guided world menu and allow both Global Palbox options:

```ini
bAllowGlobalPalboxImport=True
bAllowGlobalPalboxExport=True
```

`Import` lets players bring Global Palbox Pals into your server. `Export` lets them save Pals from your server to the Global Palbox. Restart Palworld after saving.

The safest menu path is:

```text
Settings and presets -> Enable Global Palbox safely
```

That creates a backup, stops Palworld if it is running, writes both Global Palbox keys while the game is not holding the config in memory, disables any `WorldOption.sav` override if present, and starts Palworld again.

If Global Palbox still says the world settings forbid reconstruction after a restart, check for a `WorldOption.sav` override:

```text
Settings and presets -> Check WorldOption.sav setting overrides
```

If an override is found, use:

```text
Settings and presets -> Disable WorldOption.sav overrides
```

That action creates a backup, stops Palworld, renames the active `WorldOption.sav` file instead of deleting it, and starts Palworld again. This makes `PalWorldSettings.ini` the source of truth for settings like Global Palbox import/export.

## Backups

Open the menu and choose `Backups and restore`.

The menu can:

- Create a backup now.
- List backups.
- Restore the newest backup.
- Restore a specific backup path.
- Schedule automatic backups.
- Remove the automatic backup schedule.

## REST API Helpers

Open the menu and choose `REST API tools`.

The script enables REST API for local management. Keep it local/LAN-only.

## Server Extras / Fun Tools

Open the menu and choose `Server extras / fun tools`.

The menu can:

- Send a one-time server announcement.
- Schedule repeating announcements with a `systemd` timer.
- Stop repeating announcements.
- Show announcement timer status.
- Explain what vanilla Linux servers can and cannot customize in-game.

Good vanilla uses:

- Welcome messages.
- Discord links.
- Raid rules.
- Weekend event reminders.
- Restart/wipe notices.

Vanilla Ubuntu dedicated servers cannot inject a persistent custom logo, HUD, clickable UI, scoreboard overlay, or top-left brand panel into every player's client. That requires client-side modding/plugin support, and official Palworld server mod support is currently not the same as a general Linux server-side UI scripting API.

## Connected Web Panel

The project now includes a connected web panel in `web-panel/`.

Install it from the Ubuntu menu:

```text
Web panel -> Install / update web panel
```

The web panel runs as `palworld-web.service` and talks to Palworld REST from the server side only. Browsers never receive the Palworld admin password.

Included pages/features:

- Public server status, direct connect IP, uptime, FPS, player count, and sanitized online player list.
- Homepage auto-slider with public Palworld media/official Steam assets.
- Discord widget overview when you set `DISCORD_GUILD_ID` and enable the Discord server widget.
- Steam sign-in with Valve Steam OpenID.
- Optional Xbox/Microsoft sign-in with Microsoft OpenID Connect after you add Microsoft OAuth credentials.
- Shop catalog and order/request ledger for future purchases or admin-reviewed perks.
- Separate `/admin` owner login and admin dashboard for save, backup, start, stop, restart, update, announcements, presets, common settings, kick, ban, orders, and audit history.
- Organized admin command center with monitoring tiles, section tabs, current settings editor, grouped toggles, announcement history, restart countdown alerts, shop catalog editing, player tools, and audit history.

Owner/admin login:

```text
https://your-domain/admin
```

The normal public Account page does not show the owner password login. If the admin password is wrong or forgotten, use:

```text
Web panel -> Reset admin password
```

Recommended public setup:

```text
Internet HTTPS 443 -> Caddy -> 127.0.0.1:8080 web panel
```

Use the menu:

```text
Web panel -> Change web panel settings
```

Set:

```text
HTTPS domain: panel.yourdomain.com
Palworld direct-connect host/domain: panel.yourdomain.com
TLS email: your email, optional
```

Then run:

```text
Web panel -> Configure HTTPS 443 with Caddy
```

Before running the Caddy setup:

- Point your domain DNS A record to the Ubuntu server public IPv4.
- Open TCP `80` and TCP `443` in your provider firewall/router.
- Do not expose TCP `8212`; that is the Palworld REST API and should stay private.

The web panel still listens internally on `127.0.0.1:8080`. Caddy owns the public `443` HTTPS endpoint.

If you want the homepage copy button to show a domain instead of IPv4, set:

```text
Palworld direct-connect host/domain: pal.neoxify.com
```

Then the homepage will show:

```text
pal.neoxify.com:8211
```

If you choose not to use HTTPS yet, you can temporarily expose the direct panel port:

```text
TCP 8080 -> this Ubuntu server
```

Important security notes:

- Keep Palworld REST on `127.0.0.1` or private LAN. The official docs warn against exposing the Palworld REST API directly to the Internet.
- The web panel has its own login and backend proxy. Put it behind HTTPS with Caddy before advertising it widely.
- The shop is a real request/order/admin ledger. Automatic item or cosmetic delivery still depends on safe Palworld API/mod support. Vanilla Palworld REST does not expose a general "give item/cosmetic" endpoint.
- Steam login is fully supported without extra secrets. Xbox/Microsoft login requires a Microsoft Entra app registration with redirect URI `https://your-domain/api/auth/microsoft/callback`. PlayStation login requires Sony-approved OAuth/API access; the panel will not show a fake PlayStation button without real provider credentials.

For Discord overview, Discord requires the server widget to be public:

```text
Discord Server Settings -> Widget -> Enable Server Widget
```

Also choose an invite channel there. The panel can show the Discord invite link without the widget, but live online members require the public widget endpoint to work.

For Xbox/Microsoft login, configure:

```text
Web panel -> Change web panel settings
```

Set:

```text
Microsoft/Xbox OAuth client ID
Microsoft/Xbox OAuth client secret
Microsoft tenant: consumers
```

Then restart/install the web panel. Steam login needs no setup beyond the public web URL being correct.

## Mods

Open the menu and choose `Mods`.

Only server-compatible mods work on the dedicated server. Mods can corrupt saves or crash servers, so back up first.

## Optional Command-Style Use

The menu is the main interface, but the script still supports commands for automation, cron/systemd timers, or advanced use:

```bash
sudo bash palworld-manager.sh status
sudo bash palworld-manager.sh backup
sudo bash palworld-manager.sh update
sudo bash palworld-manager.sh set ServerName="Neo Palworld" ExpRate=1.5
sudo bash palworld-manager.sh preset casual
sudo bash palworld-manager.sh schedule-announcement --announce-message "Join our Discord: example.gg" --announce-every-minutes 30
sudo bash palworld-manager.sh unschedule-announcement
sudo bash palworld-manager.sh web-install
sudo bash palworld-manager.sh web-https --web-panel-domain panel.example.com --web-panel-tls-email admin@example.com
sudo bash palworld-manager.sh web-reset-admin
sudo bash palworld-manager.sh mods PackageOne PackageTwo
```

Custom install location:

```bash
sudo bash palworld-manager.sh install --install-dir /srv/palworld --backup-dir /srv/palworld-backups --server-name "Neo Palworld" --public-lobby
```

Manual/rootless mode for testing:

```bash
bash palworld-manager.sh --rootless --install-dir "$HOME/palworld"
```

## Important Notes

- Official dedicated server Steam app id: `2394010`.
- Default game port: UDP `8211`.
- Ubuntu/Linux config path: `Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`.
- Community listing uses the `-publiclobby` launch option.
- REST API uses `RESTAPIEnabled=True` and defaults here to TCP `8212`.
- RCON is deprecated by Pocketpair, so this project keeps it disabled by default.
- Palworld 1.0 docs say leaving older multithread launch args unset may improve performance; this script keeps them off unless you choose that option.

## Troubleshooting

If the game says `Connection timed out` and the manager status shows:

```text
Active: inactive (dead)
```

The Palworld server is not running yet. Open the menu:

```bash
sudo bash palworld-manager.sh
```

Choose:

```text
Start / stop / status / logs -> Start server
```

If it fails to stay running, the updated script will print the recent `palworld.service` journal logs immediately.

If Ubuntu says the Steam license was declined or you see:

```text
/opt/palworld/steamcmd/steamcmd.sh: line 37: /opt/palworld/steamcmd/linux32/steamcmd: Permission denied
```

Use the updated script and open the menu again:

```bash
sudo bash palworld-manager.sh
```

Choose `Install / initial setup` again. The installer now pre-accepts the apt Steam license, removes a broken half-installed `steamcmd` package if needed, repairs manual SteamCMD ownership/execute permissions, and then resumes the Palworld server install.

If SteamCMD starts but fails with:

```text
Error! App '2394010' state is 0x2 after update job.
```

Open the menu again and choose `Install / initial setup`. The updater now retries SteamCMD up to three times, forces Linux platform selection, repairs `/opt/palworld` ownership before each attempt, clears only the partial Steam download state for app `2394010`, and prints the Steam content log tail if it still fails.

If the Steam content log mentions an IPv6 Steam CDN address and `No connection`, for example:

```text
cache2-den-iwst.steamcontent.com ([2607:dc0::5]:443) ... failed to send manifest request
Failed downloading ... manifests (No connection)
```

That usually means the server has a broken IPv6 route to Steam content. The installer now checks this automatically. In `auto` mode, if IPv4 works but IPv6 fails, it temporarily disables IPv6 only while SteamCMD downloads, then restores IPv6 afterward.

If auto mode refuses because your SSH session appears to be using IPv6, open:

```text
Network / firewall / ports -> Change SteamCMD IPv4/IPv6 download mode
```

Set the mode to `true` only if you have another way back into the server, such as a provider console or IPv4 SSH.

If Caddy/web-panel install says:

```text
Could not get lock /var/lib/dpkg/lock-frontend
```

Ubuntu is already running `apt` or `unattended-upgrades`. Do not delete the lock file. Wait a few minutes, then rerun the same menu option. The manager now waits for apt/dpkg locks automatically before package installs.

# Movie Vault

Watches your **Downloads** folder and moves every movie and TV episode into one locked folder,
`Downloads\Movies & TV`, so a Ctrl+A → Delete in Downloads can't wipe them.

## Install
1. Unzip anywhere, double-click **Install.bat**. If Windows says "Windows protected your PC",
   click **More info → Run anyway**.
2. It starts in the tray (purple play icon) and is in the Start menu as **Movie Vault**.

## How it sorts
- `Show.Name.S02E05.1080p.mkv` → `Movies & TV\TV Shows\Show Name\Season 02\`
- `Movie.Title.2023.1080p.WEB-DL.mkv` → `Movies & TV\Movies\Movie Title (2023)\`
- Also recognises `Show_S01E02`, `S1.E1`, `S03 E04`, `1x02`, `Season 2`, `Episode 5` and `1of6`.
- TV episodes that ended up in Movies are moved to TV Shows automatically.
- Matching subtitles (.srt etc.) move with the video.
- The vault folder gets its own icon (purple play button with a padlock).
- It waits until a download is finished (not changing, not open in your browser/torrent app).
- Small clips are ignored: episodes under 40 MB and movies under 300 MB stay put (change in Settings).
  A video also needs a movie/TV-style name (year, SxxEyy, 1080p, WEB-DL…), so your own clips stay in Downloads.

## The lock
- `Movies & TV`, and the `Movies` and `TV Shows` folders inside it, **can't be deleted, renamed
  or moved** from outside. Ctrl+A → Delete in Downloads deletes everything else and Windows
  says it needs permission for the vault: click **Skip**.
- **Inside** the vault, delete files and folders normally.
- Avoid **Shift+Delete** (permanent delete) on the vault: Windows still stops at the folder, but it can
  remove what's inside first.
- Turn the lock off in Settings, or run **Uninstall.bat** (in `%LOCALAPPDATA%\MovieVault`).
  Uninstalling keeps your movies and removes the lock.

## Telegram alerts (optional)
Settings → paste a bot token from @BotFather → press Start on your bot in Telegram →
**Find my chat ID** → **Send test message** → Save.

Settings and history: `%APPDATA%\MovieVault`. Problems are logged to `error.log` there.

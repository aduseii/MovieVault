#Requires -Version 5.1
<#
    Movie Vault
    Watches your Downloads folder, finds movies and TV episodes, and moves them into
    one vault folder:  Movies & TV\Movies\<Title (Year)>  and  Movies & TV\TV Shows\<Show>\Season 01

    The vault folder (and its Movies / TV Shows folders) is locked so it can't be deleted,
    moved or renamed from outside. Inside it, you can delete files normally.

    Runs in the system tray.  Settings: %APPDATA%\MovieVault\settings.json
    Run with -Unprotect to remove the lock (the uninstaller does this).
#>
param(
    [switch]$Unprotect,
    [switch]$Background
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$App          = 'Movie Vault'
$DataDir      = Join-Path $env:APPDATA 'MovieVault'
if (-not (Test-Path -LiteralPath $DataDir)) { [void][IO.Directory]::CreateDirectory($DataDir) }
$SettingsFile = Join-Path $DataDir 'settings.json'
$HistoryFile  = Join-Path $DataDir 'history.json'
$LogFile      = Join-Path $DataDir 'error.log'
$RunKey       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

$VideoExt   = @('.mkv','.mp4','.avi','.mov','.m4v','.wmv','.webm','.ts','.m2ts','.mpg','.mpeg','.flv','.divx')
$SubExt     = @('.srt','.ass','.ssa','.sub','.idx','.vtt','.smi')
$PartialExt = @('.crdownload','.part','.partial','.!qb','.!ut','.download','.opdownload','.tmp')

# Names are matched with underscores turned into spaces, and "not after a letter/digit"
# is used instead of \b so Show_S01E02 and Show.S01E02 both count.
$TvRx = @(
    '(?i)^(?<t>.*?)(?<![a-z0-9])s(?<s>\d{1,2})[\s.\-]*e(?<e>\d{1,3})(?!\d)',          # S01E02, S1.E1, S03 E04
    '(?i)^(?<t>.*?)(?<![a-z0-9])(?<s>\d{1,2})x(?<e>\d{2,3})(?!\d)',                   # 1x02
    '(?i)^(?<t>.*?)(?<![a-z0-9])season[\s.\-]*(?<s>\d{1,2})',                          # Season 2
    '(?i)^(?<t>.*?)(?<![a-z0-9])(?:ep|episode)[\s.\-]*(?<e>\d{1,3})(?!\d)',            # Episode 5 / Ep05
    '(?i)^(?<t>.*?)(?<![a-z0-9])(?<s>\d{1,2})[\s.\-]*of[\s.\-]*(?<e>\d{1,2})(?!\d)',   # 1of6 (mini-series)
    '(?i)^(?<t>.*?)(?<![a-z0-9])s(?<s>\d{1,2})(?=[\s.\-\]\)]|$)'                      # season-pack folder, e.g. Show.S02.1080p
)
$YearRx = '(?i)^(?<t>.+?)[\s._\-\[\(]+(?<y>19[2-9]\d|20[0-4]\d)(?=[\s._\-\]\)]|$)'
$TagRx  = '(?i)[\s._\-\[\(](480p|576p|720p|1080p|1080i|2160p|4k|bluray|blu-ray|bdrip|brrip|web-?dl|webrip|hdtv|hdrip|dvdrip|dvdscr|x264|x265|h\.?264|h\.?265|hevc|10bit|yify|yts|rarbg|proper|repack|extended|remastered|imax)(?=[\s._\-\]\)]|$)'

$Everyone   = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
$DelRight   = [System.Security.AccessControl.FileSystemRights]::Delete
$DelChild   = [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles

function Write-Log([string]$msg) {
    try { Add-Content -LiteralPath $LogFile -Value ('{0}  {1}' -f (Get-Date -Format s), $msg) } catch {}
}

# ---------------------------------------------------------------- settings
function Get-DownloadsPath {
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    } catch {}
    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Load-Settings {
    $dl = Get-DownloadsPath
    $s = [ordered]@{
        DownloadsPath    = $dl
        LibraryPath      = (Join-Path $dl 'Movies & TV')
        MinEpisodeMB     = 40
        MinMovieMB       = 300
        Protect          = $true
        StartWithWindows = $false
        TelegramToken    = ''
        TelegramChatId   = ''
        ProtectedParent  = ''
    }
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($s.Keys)) {
                if ($j.PSObject.Properties.Name -contains $k) { $s[$k] = $j.$k }
            }
        } catch { Write-Log "settings: $_" }
    }
    return $s
}

function Save-Settings {
    try { $script:S | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 } catch { Write-Log "save settings: $_" }
}

# ---------------------------------------------------------------- folder lock
function Set-DenyRule([string]$path, [System.Security.AccessControl.FileSystemRights]$rights, [bool]$on) {
    if (-not $path -or -not [IO.Directory]::Exists($path)) { return }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Everyone, $rights,
        [System.Security.AccessControl.InheritanceFlags]::None,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Deny)
    $acl = [IO.Directory]::GetAccessControl($path, [System.Security.AccessControl.AccessControlSections]::Access)
    if ($on) { $acl.AddAccessRule($rule) } else { [void]$acl.RemoveAccessRuleSpecific($rule) }
    [IO.Directory]::SetAccessControl($path, $acl)
}

# Locks: the vault folder, its Movies and TV Shows folders (can't be deleted/renamed/moved),
# and stops the folder above it from deleting the vault on its behalf.
# Only those folders are locked, so files and show folders INSIDE stay deletable.
function Set-Protection([bool]$on, [string]$lib) {
    if (-not $lib) { $lib = $script:S.LibraryPath }
    $lib = $lib.TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($lib)
    try {
        Set-DenyRule $lib $DelRight $on
        Set-DenyRule $lib $DelChild $on
        Set-DenyRule (Join-Path $lib 'Movies')   $DelRight $on
        Set-DenyRule (Join-Path $lib 'TV Shows') $DelRight $on
        if ($on) {
            Set-DenyRule $parent $DelChild $true
            $script:S.ProtectedParent = $parent
        } elseif ($script:S.ProtectedParent) {
            Set-DenyRule $script:S.ProtectedParent $DelChild $false
            $script:S.ProtectedParent = ''
        }
        Save-Settings
    } catch {
        Write-Log "protection ($on): $_"
    }
}

function Ensure-Library {
    $lib = $script:S.LibraryPath
    $isNew = -not [IO.Directory]::Exists($lib) -or
             -not [IO.Directory]::Exists((Join-Path $lib 'Movies')) -or
             -not [IO.Directory]::Exists((Join-Path $lib 'TV Shows'))
    [void][IO.Directory]::CreateDirectory((Join-Path $lib 'Movies'))
    [void][IO.Directory]::CreateDirectory((Join-Path $lib 'TV Shows'))
    if ($isNew -and $script:S.Protect) { Set-Protection $true }
    Ensure-VaultIcon
}

# ---------------------------------------------------------------- icon (tray + vault folder)
function New-IconBitmap([int]$n) {
    $k = $n / 32.0
    $bmp = New-Object System.Drawing.Bitmap $n, $n
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $purple = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 124, 58, 237))
    $g.FillEllipse($purple, [single](1 * $k), [single](1 * $k), [single](30 * $k), [single](30 * $k))
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF ([single](12 * $k)), ([single](8 * $k))),
        (New-Object System.Drawing.PointF ([single](12 * $k)), ([single](24 * $k))),
        (New-Object System.Drawing.PointF ([single](25 * $k)), ([single](16 * $k))))
    $g.FillPolygon([System.Drawing.Brushes]::White, $pts)
    if ($n -ge 64) {
        # small gold padlock, bottom-right
        $gold = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 245, 180, 40))
        $pen  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 245, 180, 40)), ([single](2 * $k))
        $g.DrawArc($pen, [single](21.5 * $k), [single](17 * $k), [single](7 * $k), [single](8 * $k), [single]180, [single]180)
        $g.FillRectangle($gold, [single](20 * $k), [single](21 * $k), [single](10 * $k), [single](9 * $k))
        $pen.Dispose(); $gold.Dispose()
    }
    $g.Dispose(); $purple.Dispose()
    return $bmp
}

# Writes a 256px .ico (PNG inside), which Explorer shows sharply at every size.
function Write-IcoFile([string]$path) {
    $bmp = New-IconBitmap 256
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $png = $ms.ToArray()
    $fs = [IO.File]::Create($path)
    $w = New-Object IO.BinaryWriter $fs
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)          # header: 1 image
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0)   # 256x256, no palette
    $w.Write([uint16]1); $w.Write([uint16]32)                                # planes, bits
    $w.Write([uint32]$png.Length); $w.Write([uint32]22)                      # size, offset
    $w.Write($png)
    $w.Close()
}

try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MovieVaultShell {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern void SHChangeNotify(int eventId, uint flags, string item1, IntPtr item2);
    public static void Refresh(string path) {
        SHChangeNotify(0x00002000, 0x0005, path, IntPtr.Zero);   // SHCNE_UPDATEITEM, SHCNF_PATHW
        SHChangeNotify(0x08000000, 0, null, IntPtr.Zero);        // SHCNE_ASSOCCHANGED
    }
}
'@
} catch {}

# Gives the vault folder its own icon (purple play button with a padlock) via desktop.ini.
function Ensure-VaultIcon {
    $lib = $script:S.LibraryPath
    $ico = Join-Path $DataDir 'vault.ico'
    $ini = Join-Path $lib 'desktop.ini'
    if ((Test-Path -LiteralPath $ini) -and (Test-Path -LiteralPath $ico)) { return }
    try {
        if (-not (Test-Path -LiteralPath $ico)) { Write-IcoFile $ico }
        if (Test-Path -LiteralPath $ini) { (Get-Item -LiteralPath $ini -Force).Attributes = [IO.FileAttributes]::Normal }
        Set-Content -LiteralPath $ini -Encoding Unicode -Value @(
            '[.ShellClassInfo]',
            "IconResource=$ico,0",
            '[ViewState]',
            'FolderType=Videos')
        (Get-Item -LiteralPath $ini -Force).Attributes = [IO.FileAttributes]'Hidden, System'
        $d = Get-Item -LiteralPath $lib -Force
        $d.Attributes = $d.Attributes -bor [IO.FileAttributes]::ReadOnly
        try { [MovieVaultShell]::Refresh($lib) } catch {}
    } catch {
        Write-Log "vault icon: $_"
    }
}

# ---------------------------------------------------------------- unprotect mode (used by uninstaller)
if ($Unprotect) {
    $script:S = Load-Settings
    Set-Protection $false
    exit 0
}

# ---------------------------------------------------------------- detection
function Clean-Title([string]$t) {
    if (-not $t) { return '' }
    $t = $t -replace '(?i)^\s*www\.\S+?\s*-\s*', ''
    $t = $t -replace '^\s*(\[[^\]]*\]\s*)+', ''
    $t = $t -replace '[._]+', ' '
    $t = $t -replace '[\(\[\{]\s*$', ''
    $t = ($t -replace '\s{2,}', ' ').Trim(' ', '-', '(', '[', '+')
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $t = $t.Replace([string]$c, '') }
    $t = $t.TrimEnd('.', ' ')
    if ($t -and ($t -ceq $t.ToLower())) { $t = (Get-Culture).TextInfo.ToTitleCase($t) }
    return $t
}

function Match-TV([string]$name, [bool]$allowPack) {
    $name = $name -replace '_', ' '
    $n = $TvRx.Count - 1; if ($allowPack) { $n = $TvRx.Count }
    for ($i = 0; $i -lt $n; $i++) {
        $m = [regex]::Match($name, $TvRx[$i])
        if ($m.Success) { return $m }
    }
    return $null
}

function Get-Season($m) {
    if ($m.Groups['s'].Success -and $m.Groups['s'].Value) { return [int]$m.Groups['s'].Value }
    return 1
}

function Get-MediaInfo([IO.FileInfo]$f) {
    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $mb   = $f.Length / 1MB
    $inSub = -not ($f.DirectoryName.TrimEnd('\') -ieq $script:S.DownloadsPath.TrimEnd('\'))
    $parentName = ''
    if ($inSub) { $parentName = $f.Directory.Name }

    if (($base -match '(?i)(?<![a-z0-9])(sample|trailer)(?![a-z0-9])') -and $mb -lt 300) { return $null }

    # ---- TV episode?
    $title = ''; $season = 0
    $m = Match-TV $base $false
    if ($m) {
        $title = Clean-Title $m.Groups['t'].Value
        $season = Get-Season $m
    } elseif ($parentName) {
        $m = Match-TV $parentName $true
        if ($m) {
            $title = Clean-Title $m.Groups['t'].Value
            $season = Get-Season $m
        }
    }
    if ($m) {
        if (-not $title -and $parentName) {
            $pm = Match-TV $parentName $true
            if ($pm) { $title = Clean-Title $pm.Groups['t'].Value } else { $title = Clean-Title $parentName }
        }
        if (-not $title) { $title = 'Unknown Show' }
        if ($mb -lt $script:S.MinEpisodeMB) { return $null }
        return [pscustomobject]@{ Kind = 'TV'; Title = $title; Season = $season }
    }

    # ---- Movie?
    if ($mb -lt $script:S.MinMovieMB) { return $null }
    foreach ($cand in @($base, $parentName)) {
        if (-not $cand) { continue }
        $ym = [regex]::Match($cand, $YearRx)
        if ($ym.Success) {
            $t = Clean-Title $ym.Groups['t'].Value
            if ($t) { return [pscustomobject]@{ Kind = 'Movie'; Title = ('{0} ({1})' -f $t, $ym.Groups['y'].Value); Season = 0 } }
        }
    }
    foreach ($cand in @($base, $parentName)) {
        if (-not $cand) { continue }
        $tm = [regex]::Match($cand, $TagRx)
        if ($tm.Success -and $tm.Index -gt 0) {
            $t = Clean-Title $cand.Substring(0, $tm.Index)
            if ($t) { return [pscustomobject]@{ Kind = 'Movie'; Title = $t; Season = 0 } }
        }
    }
    return $null
}

# Finished downloading? (not touched for 45s, no partial file next to it, not open in another app)
function Test-Ready([IO.FileInfo]$f) {
    if (((Get-Date) - $f.LastWriteTime).TotalSeconds -lt 45) { return $false }
    foreach ($e in $PartialExt) { if (Test-Path -LiteralPath ($f.FullName + $e)) { return $false } }
    try {
        $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $fs.Close()
        return $true
    } catch { return $false }
}

function Get-FreePath([string]$dir, [string]$name) {
    $p = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $p)) { return $p }
    $b = [IO.Path]::GetFileNameWithoutExtension($name); $x = [IO.Path]::GetExtension($name); $i = 2
    while (Test-Path -LiteralPath (Join-Path $dir ('{0} ({1}){2}' -f $b, $i, $x))) { $i++ }
    return (Join-Path $dir ('{0} ({1}){2}' -f $b, $i, $x))
}

# ---------------------------------------------------------------- history + alerts
function Get-History {
    $out = @()
    if (Test-Path -LiteralPath $HistoryFile) {
        try {
            $j = Get-Content -LiteralPath $HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($i in $j) { $out += $i }
        } catch { Write-Log "history: $_" }
    }
    return $out
}

function Add-History($items) {
    $h = @($items) + @(Get-History)
    $h = @($h | Select-Object -First 300)
    try { ConvertTo-Json -InputObject $h -Depth 3 | Set-Content -LiteralPath $HistoryFile -Encoding UTF8 } catch { Write-Log "save history: $_" }
    Refresh-List
}

function Send-Telegram([string]$text, [bool]$throwErrors = $false) {
    if (-not $script:S.TelegramToken -or -not $script:S.TelegramChatId) {
        if ($throwErrors) { throw 'Add your bot token and chat ID first.' }
        return
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $json = @{ chat_id = [string]$script:S.TelegramChatId; text = $text } | ConvertTo-Json
        Invoke-RestMethod -Uri ('https://api.telegram.org/bot{0}/sendMessage' -f $script:S.TelegramToken) -Method Post `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
    } catch {
        Write-Log "telegram: $_"
        if ($throwErrors) { throw }
    }
}

function Notify($moved) {
    if ($moved.Count -eq 1) { $text = 'Added: ' + $moved[0].Title }
    else { $text = 'Added {0} items: {1}' -f $moved.Count, ((@($moved) | Select-Object -First 3 | ForEach-Object { $_.Title }) -join ', ') }
    try { $script:tray.ShowBalloonTip(5000, $App, $text, [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    $film = [char]::ConvertFromUtf32(0x1F3AC)
    $lines = @($moved) | ForEach-Object {
        $where = 'Movies'; if ($_.Kind -eq 'TV') { $where = 'TV Shows' }
        '- {0}  ({1})' -f $_.Title, $where
    }
    Send-Telegram ("$film Movie Vault`n" + ($lines -join "`n"))
}

# ---------------------------------------------------------------- scan + move
function Move-Media([IO.FileInfo]$f, $info, [System.Collections.ArrayList]$moved) {
    if ($info.Kind -eq 'TV') {
        $dest = Join-Path (Join-Path (Join-Path $script:S.LibraryPath 'TV Shows') $info.Title) ('Season {0:D2}' -f [int]$info.Season)
        $label = '{0} - Season {1}' -f $info.Title, $info.Season
    } else {
        $dest = Join-Path (Join-Path $script:S.LibraryPath 'Movies') $info.Title
        $label = $info.Title
    }
    [void][IO.Directory]::CreateDirectory($dest)

    $srcDir = $f.DirectoryName
    $base   = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $target = Get-FreePath $dest $f.Name
    [IO.File]::Move($f.FullName, $target)

    # bring matching subtitles along
    $subs = @(Get-ChildItem -LiteralPath $srcDir -File -ErrorAction SilentlyContinue | Where-Object {
        ($SubExt -contains $_.Extension.ToLower()) -and $_.Name.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($sub in $subs) {
        try { [IO.File]::Move($sub.FullName, (Get-FreePath $dest $sub.Name)) } catch { Write-Log "subtitle $($sub.FullName): $_" }
    }

    [void]$moved.Add([pscustomobject]@{
        Time  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Kind  = $info.Kind
        Title = $label
        File  = $f.Name
        Path  = $target
    })
}

# TV episodes that ended up in Movies (older versions missed some names) get moved to TV Shows.
function Invoke-Resort([System.Collections.ArrayList]$moved) {
    $moviesDir = Join-Path $script:S.LibraryPath 'Movies'
    if (-not [IO.Directory]::Exists($moviesDir)) { return }
    $vids = @(Get-ChildItem -LiteralPath $moviesDir -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object {
        $VideoExt -contains $_.Extension.ToLower()
    })
    foreach ($f in $vids) {
        try {
            $info = Get-MediaInfo $f
            if (-not $info -or $info.Kind -ne 'TV') { continue }
            $srcDir = $f.DirectoryName
            Move-Media $f $info $moved
            # remove the now-empty movie folder (never the Movies folder itself)
            if (-not ($srcDir.TrimEnd('\') -ieq $moviesDir.TrimEnd('\')) -and
                @(Get-ChildItem -LiteralPath $srcDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                [IO.Directory]::Delete($srcDir)
            }
        } catch {
            Write-Log "resort $($f.FullName): $_"
        }
    }
}

$script:Busy = $false
function Invoke-Scan([bool]$manual = $false) {
    if ($script:Busy) { return }
    $script:Busy = $true
    $moved = New-Object System.Collections.ArrayList
    try {
        $dl = $script:S.DownloadsPath
        if (-not (Test-Path -LiteralPath $dl)) { return }
        Ensure-Library
        $libPrefix = [IO.Path]::GetFullPath($script:S.LibraryPath).TrimEnd('\') + '\'

        $files = @(Get-ChildItem -LiteralPath $dl -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Where-Object {
            ($VideoExt -contains $_.Extension.ToLower()) -and
            -not $_.FullName.StartsWith($libPrefix, [StringComparison]::OrdinalIgnoreCase)
        })

        foreach ($f in $files) {
            try {
                $info = Get-MediaInfo $f
                if (-not $info) { continue }
                if (-not (Test-Ready $f)) { continue }
                Move-Media $f $info $moved
            } catch {
                Write-Log "move $($f.FullName): $_"
            }
        }

        Invoke-Resort $moved
    } catch {
        Write-Log "scan: $_"
    } finally {
        $script:Busy = $false
    }

    if ($moved.Count -gt 0) {
        Add-History $moved
        Notify $moved
    } elseif ($manual) {
        try { $script:tray.ShowBalloonTip(3000, $App, 'Nothing new in Downloads.', [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }
}

# ---------------------------------------------------------------- single instance
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\MovieVaultApp', [ref]$created)
if (-not $created) {
    [void][System.Windows.Forms.MessageBox]::Show('Movie Vault is already running. Look for it in the tray (bottom-right).', $App)
    exit 0
}

$script:S = Load-Settings
try { Ensure-Library; if ($script:S.Protect) { Set-Protection $true } } catch { Write-Log "startup: $_" }

# ---------------------------------------------------------------- icon
function New-AppIcon {
    $bmp = New-IconBitmap 32
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icon = New-AppIcon

# ---------------------------------------------------------------- main window
$form = New-Object System.Windows.Forms.Form
$form.Text = $App
$form.Icon = $icon
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(820, 500)
$form.MinimumSize = New-Object System.Drawing.Size(600, 340)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock = 'Top'; $top.AutoSize = $true; $top.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 4)
$top.ColumnCount = 1

$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $true
$status.MaximumSize = New-Object System.Drawing.Size(2000, 0)
$top.Controls.Add($status)

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.AutoSize = $true; $buttons.WrapContents = $true
$buttons.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
function New-Button([string]$text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.AutoSize = $true; $b.Padding = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
    $buttons.Controls.Add($b)
    return $b
}
$btnOpen     = New-Button 'Open vault folder'
$btnScan     = New-Button 'Scan Downloads now'
$btnSettings = New-Button 'Settings'
$top.Controls.Add($buttons)

$script:list = New-Object System.Windows.Forms.ListView
$list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.GridLines = $false
[void]$list.Columns.Add('Added', 120)
[void]$list.Columns.Add('Type', 60)
[void]$list.Columns.Add('Title', 260)
[void]$list.Columns.Add('File', 340)

$hint = New-Object System.Windows.Forms.Label
$hint.Dock = 'Bottom'; $hint.AutoSize = $false; $hint.Height = 26
$hint.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
$hint.ForeColor = [System.Drawing.Color]::DimGray
$hint.Text = 'Double-click a row to show the file. To delete something, open the vault folder and delete it inside.'

$form.Controls.Add($list)
$form.Controls.Add($hint)
$form.Controls.Add($top)

function Update-Status {
    $lock = 'OFF'; if ($script:S.Protect) { $lock = 'ON (can''t be deleted from outside)' }
    $status.Text = "Watching:  $($script:S.DownloadsPath)`nVault:  $($script:S.LibraryPath)`nLock:  $lock"
}

function Refresh-List {
    if (-not $script:list) { return }
    $script:list.BeginUpdate()
    $script:list.Items.Clear()
    foreach ($h in (Get-History)) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$h.Time)
        [void]$it.SubItems.Add([string]$h.Kind)
        [void]$it.SubItems.Add([string]$h.Title)
        [void]$it.SubItems.Add([string]$h.File)
        $it.Tag = [string]$h.Path
        [void]$script:list.Items.Add($it)
    }
    $script:list.EndUpdate()
}

function Open-Vault {
    Ensure-Library
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:S.LibraryPath)
}

$list.Add_DoubleClick({
    if ($script:list.SelectedItems.Count -eq 0) { return }
    $p = [string]$script:list.SelectedItems[0].Tag
    if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $p) }
    else { [void][System.Windows.Forms.MessageBox]::Show('That file is no longer in the vault (it was deleted or moved).', $App) }
})
$btnOpen.Add_Click({ Open-Vault })
$btnScan.Add_Click({ Invoke-Scan $true })

# ---------------------------------------------------------------- settings window
function Show-Settings {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "$App - Settings"; $f.Icon = $icon
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'; $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.AutoSize = $true; $t.ColumnCount = 3; $t.Padding = New-Object System.Windows.Forms.Padding(12)
    $f.Controls.Add($t)

    function Add-Label([string]$text) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.AutoSize = $true; $l.Anchor = 'Left'; $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 6)
        $t.Controls.Add($l)
    }
    function Add-PathRow([string]$label, [string]$value) {
        Add-Label $label
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Text = $value; $tb.Width = 380
        $t.Controls.Add($tb)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = 'Browse...'; $b.AutoSize = $true
        $b.Tag = $tb
        $b.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.SelectedPath = $this.Tag.Text
            if ($d.ShowDialog() -eq 'OK') { $this.Tag.Text = $d.SelectedPath }
        })
        $t.Controls.Add($b)
        return $tb
    }
    function Add-Number([string]$label, [int]$value) {
        Add-Label $label
        $n = New-Object System.Windows.Forms.NumericUpDown
        $n.Minimum = 0; $n.Maximum = 100000; $n.Value = $value; $n.Width = 100
        $t.Controls.Add($n)
        $t.Controls.Add((New-Object System.Windows.Forms.Label))
        return $n
    }
    function Add-Check([string]$text, [bool]$value) {
        $t.Controls.Add((New-Object System.Windows.Forms.Label))
        $c = New-Object System.Windows.Forms.CheckBox
        $c.Text = $text; $c.Checked = $value; $c.AutoSize = $true
        $t.Controls.Add($c); $t.SetColumnSpan($c, 2)
        return $c
    }
    function Add-Text([string]$label, [string]$value) {
        Add-Label $label
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Text = $value; $tb.Width = 380
        $t.Controls.Add($tb)
        $t.Controls.Add((New-Object System.Windows.Forms.Label))
        return $tb
    }

    $tbDl   = Add-PathRow 'Downloads folder' $script:S.DownloadsPath
    $tbLib  = Add-PathRow 'Vault folder' $script:S.LibraryPath
    $nEp    = Add-Number 'Smallest TV episode (MB)' ([int]$script:S.MinEpisodeMB)
    $nMov   = Add-Number 'Smallest movie (MB)' ([int]$script:S.MinMovieMB)
    $cbLock = Add-Check 'Lock the vault folder so it can''t be deleted from outside' ([bool]$script:S.Protect)
    $cbRun  = Add-Check 'Start Movie Vault when Windows starts' ([bool]$script:S.StartWithWindows)
    $tbTok  = Add-Text 'Telegram bot token (optional)' ([string]$script:S.TelegramToken)
    $tbChat = Add-Text 'Telegram chat ID' ([string]$script:S.TelegramChatId)

    $tg = New-Object System.Windows.Forms.FlowLayoutPanel
    $tg.AutoSize = $true
    $btnFind = New-Object System.Windows.Forms.Button; $btnFind.Text = 'Find my chat ID'; $btnFind.AutoSize = $true
    $btnTest = New-Object System.Windows.Forms.Button; $btnTest.Text = 'Send test message'; $btnTest.AutoSize = $true
    $tg.Controls.Add($btnFind); $tg.Controls.Add($btnTest)
    $t.Controls.Add((New-Object System.Windows.Forms.Label)); $t.Controls.Add($tg); $t.SetColumnSpan($tg, 2)

    $btnFind.Add_Click({
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $r = Invoke-RestMethod -Uri ('https://api.telegram.org/bot{0}/getUpdates' -f $tbTok.Text.Trim())
            $last = @($r.result | Where-Object { $_.message }) | Select-Object -Last 1
            if ($last) { $tbChat.Text = [string]$last.message.chat.id }
            else { [void][System.Windows.Forms.MessageBox]::Show('No messages yet. Open your bot in Telegram, press Start (or send it any message), then try again.', $App) }
        } catch { [void][System.Windows.Forms.MessageBox]::Show("Couldn't reach Telegram. Check the token.`n`n$_", $App) }
    })
    $btnTest.Add_Click({
        $oldT = $script:S.TelegramToken; $oldC = $script:S.TelegramChatId
        $script:S.TelegramToken = $tbTok.Text.Trim(); $script:S.TelegramChatId = $tbChat.Text.Trim()
        try { Send-Telegram 'Movie Vault test message - alerts are working.' $true; [void][System.Windows.Forms.MessageBox]::Show('Sent! Check Telegram.', $App) }
        catch { [void][System.Windows.Forms.MessageBox]::Show("Couldn't send.`n`n$_", $App) }
        finally { $script:S.TelegramToken = $oldT; $script:S.TelegramChatId = $oldC }
    })

    $ok = New-Object System.Windows.Forms.FlowLayoutPanel
    $ok.AutoSize = $true; $ok.FlowDirection = 'RightToLeft'; $ok.Dock = 'Fill'
    $ok.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = 'Cancel'; $btnCancel.DialogResult = 'Cancel'
    $btnSave   = New-Object System.Windows.Forms.Button; $btnSave.Text = 'Save'; $btnSave.DialogResult = 'OK'
    $ok.Controls.Add($btnCancel); $ok.Controls.Add($btnSave)
    $t.Controls.Add($ok); $t.SetColumnSpan($ok, 3)
    $f.AcceptButton = $btnSave; $f.CancelButton = $btnCancel

    if ($f.ShowDialog($form) -ne 'OK') { return }

    $newDl  = $tbDl.Text.Trim().TrimEnd('\')
    $newLib = $tbLib.Text.Trim().TrimEnd('\')
    if (-not $newDl -or -not (Test-Path -LiteralPath $newDl)) {
        [void][System.Windows.Forms.MessageBox]::Show('That Downloads folder doesn''t exist.', $App); return
    }
    if (-not $newLib) { [void][System.Windows.Forms.MessageBox]::Show('Pick a vault folder.', $App); return }
    try { $newLib = [IO.Path]::GetFullPath($newLib) } catch { [void][System.Windows.Forms.MessageBox]::Show('That vault path isn''t valid.', $App); return }

    $libChanged = -not ($newLib -ieq $script:S.LibraryPath.TrimEnd('\'))
    # unlock the old setup first, then lock the new one
    if ($script:S.Protect) { Set-Protection $false }

    $script:S.DownloadsPath    = $newDl
    $script:S.LibraryPath      = $newLib
    $script:S.MinEpisodeMB     = [int]$nEp.Value
    $script:S.MinMovieMB       = [int]$nMov.Value
    $script:S.Protect          = $cbLock.Checked
    $script:S.StartWithWindows = $cbRun.Checked
    $script:S.TelegramToken    = $tbTok.Text.Trim()
    $script:S.TelegramChatId   = $tbChat.Text.Trim()
    Save-Settings

    try { Ensure-Library; if ($script:S.Protect) { Set-Protection $true } } catch { Write-Log "apply settings: $_" }
    Set-Startup $script:S.StartWithWindows
    Update-Status
    if ($libChanged) {
        [void][System.Windows.Forms.MessageBox]::Show('New vault folder set. Things already in the old vault stay there (it''s unlocked now), so move them over if you want them together.', $App)
    }
}
$btnSettings.Add_Click({ Show-Settings })

function Set-Startup([bool]$on) {
    try {
        if ($on) {
            $cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Background' -f $PSCommandPath
            Set-ItemProperty -Path $RunKey -Name 'MovieVault' -Value $cmd
        } else {
            Remove-ItemProperty -Path $RunKey -Name 'MovieVault' -ErrorAction SilentlyContinue
        }
    } catch { Write-Log "startup: $_" }
}

# ---------------------------------------------------------------- tray
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icon
$tray.Text = $App
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Open Movie Vault', $null, { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$menu.Items.Add('Open vault folder', $null, { Open-Vault })
[void]$menu.Items.Add('Scan Downloads now', $null, { Invoke-Scan $true })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Exit', $null, {
    $script:Exiting = $true
    $script:tray.Visible = $false
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
})
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$tray.Add_BalloonTipClicked({ Open-Vault })

$script:Exiting = $false
$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:Exiting) {
        $e.Cancel = $true
        $form.Hide()
        $script:tray.ShowBalloonTip(2500, $App, 'Still watching your Downloads from the tray.', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# ---------------------------------------------------------------- timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000      # first scan shortly after start, then every 30s
$timer.Add_Tick({
    $timer.Interval = 30000
    Invoke-Scan $false
})
$timer.Start()

Update-Status
Refresh-List
if (-not $Background) { $form.Show() }

try {
    [System.Windows.Forms.Application]::Run()
} catch {
    Write-Log "fatal: $_"
} finally {
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    try { $mutex.ReleaseMutex() } catch {}
}

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
$Version      = '1.4.0'      # bump this on every change pushed to GitHub - installed copies update themselves
$UpdateUrl    = 'https://raw.githubusercontent.com/aduseii/MovieVault/main/MovieVault.ps1'
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
        Translate        = $true
        ScanWholePC      = $true
        WeeklyReminder   = $true
        NextReminder     = ''
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
            if ($pm) { $title = Clean-Title $pm.Groups['t'].Value }
            elseif ($parentName -notmatch '(?i)^(season|series|s)\s*\d+$') { $title = Clean-Title $parentName }
        }
        if (-not $title) {
            # e.g. D:\Shows\The Office\Season 2\03.mkv -> use the folder above "Season 2"
            $gp = $f.Directory.Parent
            if ($gp -and $gp.Parent -and -not ($gp.FullName.TrimEnd('\') -ieq $script:S.DownloadsPath.TrimEnd('\'))) {
                $title = Clean-Title $gp.Name
            }
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
    $lines = @(@($moved) | Select-Object -First 15 | ForEach-Object {
        $where = 'Movies'; if ($_.Kind -eq 'TV') { $where = 'TV Shows' }
        '- {0}  ({1})' -f $_.Title, $where
    })
    if ($moved.Count -gt 15) { $lines += ('...and {0} more' -f ($moved.Count - 15)) }
    Send-Telegram ("$film Movie Vault`n" + ($lines -join "`n"))
}

# ---------------------------------------------------------------- scan + move
# ---------------------------------------------------------------- English titles (Wikidata, no account needed)
$WdUA      = "MovieVault/$Version (https://github.com/aduseii/MovieVault)"
$TvTypes   = 'P31=Q5398426|P31=Q581714|P31=Q117467246|P31=Q1259759|P31=Q15416|P31=Q526877'
$FilmTypes = 'P31=Q11424|P31=Q202866|P31=Q24862|P31=Q506240|P31=Q29168811'
$TitleFile = Join-Path $DataDir 'titles.json'
$script:TitleCache = @{}
if (Test-Path -LiteralPath $TitleFile) {
    try {
        $j = Get-Content -LiteralPath $TitleFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $script:TitleCache[$p.Name] = [string]$p.Value }
    } catch { Write-Log "titles: $_" }
}

function Normalize-Name([string]$s) {
    if (-not $s) { return '' }
    $d = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    $t = $sb.ToString().ToLowerInvariant() -replace '&', ' and ' -replace '[^\p{L}\p{N}]+', ' '
    return ($t -replace '\s+', ' ').Trim()
}

function Invoke-Wikidata([hashtable]$q) {
    $qs = ($q.GetEnumerator() | ForEach-Object { [Uri]::EscapeDataString([string]$_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value) }) -join '&'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create("https://www.wikidata.org/w/api.php?$qs")
    $req.UserAgent = $WdUA
    $req.Timeout = 10000
    $res = $req.GetResponse()
    try {
        $sr = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
        return ($sr.ReadToEnd() | ConvertFrom-Json)
    } finally { $res.Close() }
}

# Returns the English title for a show/movie name in another language, or the name unchanged.
# Only translates when the name exactly matches one of the show's/movie's names on Wikidata.
function Get-EnglishTitle([string]$title, [string]$kind) {
    if (-not $script:S.Translate -or -not $title -or $title -eq 'Unknown Show') { return $title }
    $key = "$kind|$title"
    if ($script:TitleCache.ContainsKey($key)) { return $script:TitleCache[$key] }
    $result = $title
    try {
        $query = $title; $year = ''
        $ym = [regex]::Match($title, '^(?<t>.+?)\s*\(?(?<y>(19|20)\d{2})\)?$')
        if ($ym.Success) { $query = $ym.Groups['t'].Value.Trim(' ', '-'); $year = $ym.Groups['y'].Value }
        $types = $FilmTypes; if ($kind -eq 'TV') { $types = $TvTypes }

        $r = Invoke-Wikidata @{ action = 'query'; list = 'search'; format = 'json'; srlimit = '6'; srsearch = "$query haswbstatement:$types" }
        $ids = @($r.query.search | ForEach-Object { $_.title })
        if ($ids.Count -gt 0) {
            $e = Invoke-Wikidata @{ action = 'wbgetentities'; format = 'json'; ids = ($ids -join '|'); props = 'labels|aliases|descriptions' }
            $nq = Normalize-Name $query
            $already = $false; $pick = $null
            foreach ($id in $ids) {
                $ent = $e.entities.$id
                if (-not $ent) { continue }
                $en = ''; if ($ent.labels.en) { $en = [string]$ent.labels.en.value }
                if (-not $en) { continue }
                $enNames = @($en)
                if ($ent.aliases.en) { foreach ($a in $ent.aliases.en) { $enNames += [string]$a.value } }
                if (@($enNames | Where-Object { (Normalize-Name $_) -eq $nq }).Count -gt 0) { $already = $true; break }

                $names = @()
                foreach ($p in $ent.labels.PSObject.Properties) { $names += [string]$p.Value.value }
                foreach ($p in $ent.aliases.PSObject.Properties) { foreach ($a in $p.Value) { $names += [string]$a.value } }
                if (@($names | Where-Object { (Normalize-Name $_) -eq $nq }).Count -eq 0) { continue }

                $desc = ''; if ($ent.descriptions.en) { $desc = [string]$ent.descriptions.en.value }
                if (-not $pick) { $pick = $en }
                if ($year -and $desc -match $year) { $pick = $en; break }
            }
            if ($pick -and -not $already) {
                $clean = Clean-Title ($pick -replace '\s*:\s*', ' - ')
                if ($clean -and (Normalize-Name $clean) -ne $nq) {
                    $result = $clean
                    if ($year) { $result = '{0} ({1})' -f $clean, $year }
                }
            }
        }
        $script:TitleCache[$key] = $result
        try { $script:TitleCache | ConvertTo-Json | Set-Content -LiteralPath $TitleFile -Encoding UTF8 } catch {}
        if ($result -ne $title) { Write-Log "translated '$title' -> '$result'" }
    } catch {
        Write-Log "translate '$title': $_"    # not cached, tried again next time
    }
    return $result
}

function Get-DestFolder($info) {
    $title = Get-EnglishTitle $info.Title $info.Kind
    if ($info.Kind -eq 'TV') {
        return [pscustomobject]@{
            Dir   = Join-Path (Join-Path (Join-Path $script:S.LibraryPath 'TV Shows') $title) ('Season {0:D2}' -f [int]$info.Season)
            Label = '{0} - Season {1}' -f $title, $info.Season }
    }
    return [pscustomobject]@{ Dir = Join-Path (Join-Path $script:S.LibraryPath 'Movies') $title; Label = $title }
}

# Moves everything from one folder into another (used when a folder gets its English name).
function Merge-Dir([string]$src, [string]$dst) {
    if ($src.TrimEnd('\') -ieq $dst.TrimEnd('\')) {
        if ($src -cne $dst) { [IO.Directory]::Move($src, "$src.tmp~"); [IO.Directory]::Move("$src.tmp~", $dst) }   # case-only rename
        return
    }
    if (-not [IO.Directory]::Exists($dst)) { [IO.Directory]::Move($src, $dst); return }
    foreach ($d in @(Get-ChildItem -LiteralPath $src -Directory -Force)) { Merge-Dir $d.FullName (Join-Path $dst $d.Name) }
    foreach ($fl in @(Get-ChildItem -LiteralPath $src -File -Force)) { [IO.File]::Move($fl.FullName, (Get-FreePath $dst $fl.Name)) }
    if (@(Get-ChildItem -LiteralPath $src -Force).Count -eq 0) { [IO.Directory]::Delete($src) }
}

# Renames show/movie folders already in the vault to their English names (once per start).
$script:TranslatedExisting = $false
function Invoke-TranslateExisting {
    if ($script:TranslatedExisting -or -not $script:S.Translate) { return }
    $script:TranslatedExisting = $true
    foreach ($cat in @(@{ Dir = 'TV Shows'; Kind = 'TV' }, @{ Dir = 'Movies'; Kind = 'Movie' })) {
        $root = Join-Path $script:S.LibraryPath $cat.Dir
        if (-not [IO.Directory]::Exists($root)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            try {
                $en = Get-EnglishTitle $d.Name $cat.Kind
                if ($en -and $en -ne $d.Name) { Merge-Dir $d.FullName (Join-Path $root $en) }
            } catch { Write-Log "rename $($d.FullName): $_" }
        }
    }
}

function Move-Media([IO.FileInfo]$f, $info, [System.Collections.ArrayList]$moved) {
    $df = Get-DestFolder $info
    $dest = $df.Dir; $label = $df.Label
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

# ---------------------------------------------------------------- whole-PC scan -> shortcuts in the vault
# Movies/shows found anywhere else on the PC stay where they are; a shortcut to each is put in the vault.
$PcScanScript = {
    param($roots, $skipPaths, $minBytes, $exts)
    $skipNames = @('windows', 'program files', 'program files (x86)', 'programdata', 'appdata', '$recycle.bin',
        'system volume information', 'recovery', 'perflogs', 'node_modules', 'steamapps', 'steamlibrary',
        'epic games', 'xboxgames', 'riot games', 'windowsapps', '.git', 'msocache', 'config.msi',
        '$windows.~bt', '$windows.~ws', '$sysreset', '$winreagent', 'onedrivetemp')
    $stack = New-Object System.Collections.Generic.Stack[string]
    foreach ($r in $roots) { $stack.Push([string]$r) }
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($d)) {
                if ($exts -contains [IO.Path]::GetExtension($f).ToLowerInvariant()) {
                    try { if ((New-Object IO.FileInfo $f).Length -ge $minBytes) { $f } } catch {}
                }
            }
            foreach ($sub in [IO.Directory]::EnumerateDirectories($d)) {
                try {
                    $di = New-Object IO.DirectoryInfo $sub
                    if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($skipNames -contains $di.Name.ToLowerInvariant()) { continue }
                    $full = $di.FullName.TrimEnd('\') + '\'
                    $skip = $false
                    foreach ($sp in $skipPaths) { if ($full.StartsWith([string]$sp, [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break } }
                    if (-not $skip) { $stack.Push($sub) }
                } catch {}
            }
        } catch {}
    }
}

$script:PcJob = $null
$script:NextPcScan = (Get-Date).AddSeconds(60)
try { $script:Wsh = New-Object -ComObject WScript.Shell } catch { Write-Log "wscript: $_" }

function Start-PcScan([bool]$manual = $false) {
    if ($script:PcJob) {
        if ($manual) { $script:tray.ShowBalloonTip(3000, $App, 'A PC scan is already running.', [System.Windows.Forms.ToolTipIcon]::Info) }
        return
    }
    if (-not $script:S.ScanWholePC -and -not $manual) { return }
    $roots = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [IO.DriveType]::Fixed -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })
    $skip = @(
        ([IO.Path]::GetFullPath($script:S.LibraryPath).TrimEnd('\') + '\'),
        ($script:S.DownloadsPath.TrimEnd('\') + '\'))
    $min = [long][Math]::Min([int]$script:S.MinEpisodeMB, [int]$script:S.MinMovieMB) * 1MB
    $ps = [powershell]::Create()
    [void]$ps.AddScript($PcScanScript.ToString())
    [void]$ps.AddArgument($roots).AddArgument($skip).AddArgument($min).AddArgument($VideoExt)
    $script:PcJob = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Manual = $manual }
    if ($manual) { $script:tray.ShowBalloonTip(3000, $App, 'Scanning the whole PC in the background...', [System.Windows.Forms.ToolTipIcon]::Info) }
}

function Remove-EmptyUpTo([string]$dir) {
    $stops = @((Join-Path $script:S.LibraryPath 'Movies').TrimEnd('\'), (Join-Path $script:S.LibraryPath 'TV Shows').TrimEnd('\'), $script:S.LibraryPath.TrimEnd('\'))
    while ($dir -and [IO.Directory]::Exists($dir) -and -not ($stops -icontains $dir.TrimEnd('\'))) {
        if (@(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -gt 0) { break }
        try { [IO.Directory]::Delete($dir) } catch { break }
        $dir = [IO.Path]::GetDirectoryName($dir)
    }
}

# Shortcuts whose movie was deleted (and whose drive is still plugged in) are removed.
function Remove-StaleShortcuts {
    if (-not $script:Wsh) { return }
    foreach ($l in @(Get-ChildItem -LiteralPath $script:S.LibraryPath -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $t = [string]$script:Wsh.CreateShortcut($l.FullName).TargetPath
            if (-not $t -or ($VideoExt -notcontains [IO.Path]::GetExtension($t).ToLower())) { continue }
            $root = [IO.Path]::GetPathRoot($t)
            if ($root -and (Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $t)) {
                Remove-Item -LiteralPath $l.FullName -Force
                Remove-EmptyUpTo $l.DirectoryName
            }
        } catch {}
    }
}

function Complete-PcScan {
    $job = $script:PcJob
    $script:PcJob = $null
    $added = New-Object System.Collections.ArrayList
    try {
        $paths = @($job.PS.EndInvoke($job.Handle) | ForEach-Object { [string]$_ })
        Remove-StaleShortcuts
        foreach ($p in $paths) {
            try {
                $f = New-Object IO.FileInfo $p
                if (-not $f.Exists) { continue }
                $info = Get-MediaInfo $f
                if (-not $info) { continue }
                $df = Get-DestFolder $info
                $lnk = Join-Path $df.Dir ([IO.Path]::GetFileNameWithoutExtension($f.Name) + '.lnk')
                if (Test-Path -LiteralPath $lnk) { continue }    # already linked
                [void][IO.Directory]::CreateDirectory($df.Dir)
                $sc = $script:Wsh.CreateShortcut($lnk)
                $sc.TargetPath = $f.FullName
                $sc.WorkingDirectory = $f.DirectoryName
                $sc.Save()
                [void]$added.Add([pscustomobject]@{
                    Time  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                    Kind  = $info.Kind
                    Title = $df.Label + ' (shortcut)'
                    File  = $f.FullName
                    Path  = $f.FullName
                })
            } catch { Write-Log "shortcut $p : $_" }
        }
    } catch {
        Write-Log "pc scan: $_"
    } finally {
        try { $job.PS.Dispose() } catch {}
    }
    if ($added.Count -gt 0) { Add-History $added; Notify $added }
    elseif ($job.Manual) { $script:tray.ShowBalloonTip(3000, $App, 'PC scan done. No new movies or shows found.', [System.Windows.Forms.ToolTipIcon]::Info) }
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
        Invoke-TranslateExisting
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
$mutex = New-Object System.Threading.Mutex($false, 'Local\MovieVaultApp')
$gotLock = $false
try { $gotLock = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $gotLock = $true }
if (-not $gotLock) {
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
$form.Text = "$App  v$Version"
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
$btnPc       = New-Button 'Scan whole PC'
$btnUpdate   = New-Button 'Check for updates'
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
$btnPc.Add_Click({ Start-PcScan $true })

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
    $cbTr   = Add-Check 'Use English names for shows and movies in other languages' ([bool]$script:S.Translate)
    $cbPc   = Add-Check 'Find movies and shows on the rest of the PC (adds shortcuts to the vault)' ([bool]$script:S.ScanWholePC)
    $cbRem  = Add-Check 'Remind me to clean up the vault every week' ([bool]$script:S.WeeklyReminder)
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
    $script:S.Translate        = $cbTr.Checked
    $script:S.ScanWholePC      = $cbPc.Checked
    $script:S.WeeklyReminder   = $cbRem.Checked
    if ($cbTr.Checked) { $script:TranslatedExisting = $false }
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
[void]$menu.Items.Add('Scan whole PC now', $null, { Start-PcScan $true })
[void]$menu.Items.Add('Show clean-up reminder now', $null, { try { Show-CleanupReminder } catch { Write-Log "reminder: $_" } })
[void]$menu.Items.Add('Check for updates', $null, { Invoke-UpdateCheck $true })
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

# ---------------------------------------------------------------- self-update from GitHub
function Restart-App {
    $script:Exiting = $true
    try { $timer.Stop(); $updTimer.Stop(); $pcTimer.Stop(); $remTimer.Stop() } catch {}
    try { if ($script:PcJob) { $script:PcJob.PS.Stop(); $script:PcJob.PS.Dispose() } } catch {}
    $script:tray.Visible = $false
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {}
    Start-Process powershell.exe -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Background' -f $PSCommandPath)
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
}

function Invoke-UpdateCheck([bool]$manual = $false) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-WebRequest -Uri ('{0}?t={1}' -f $UpdateUrl, [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 20
        $code = [string]$r.Content
        $m = [regex]::Match($code, "(?m)^\`$Version\s*=\s*'(?<v>[\d.]+)'")
        if (-not $m.Success) { throw 'No version found in the GitHub copy.' }
        $remote = [version]$m.Groups['v'].Value
        if ($remote -le [version]$Version) {
            if ($manual) { $script:tray.ShowBalloonTip(3000, $App, "You have the latest version (v$Version).", [System.Windows.Forms.ToolTipIcon]::Info) }
            return
        }
        # only install a copy that is really Movie Vault and parses cleanly
        $errs = $null
        [void][System.Management.Automation.PSParser]::Tokenize($code, [ref]$errs)
        if ($errs.Count -gt 0 -or $code -notmatch "\`$App\s*=\s*'Movie Vault'") { throw 'The GitHub copy looks broken, skipped it.' }

        $tmp = "$PSCommandPath.new"
        [IO.File]::WriteAllText($tmp, $code, (New-Object Text.UTF8Encoding $true))
        Copy-Item -LiteralPath $PSCommandPath -Destination "$PSCommandPath.old" -Force
        Move-Item -LiteralPath $tmp -Destination $PSCommandPath -Force
        Write-Log "updated $Version -> $remote"
        $script:tray.ShowBalloonTip(3000, $App, "Updated to v$remote. Restarting...", [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 2
        Restart-App
    } catch {
        Write-Log "update: $_"
        if ($manual) { [void][System.Windows.Forms.MessageBox]::Show("Couldn't check for updates.`n`n$_", $App) }
    }
}
$btnUpdate.Add_Click({ Invoke-UpdateCheck $true })

$updTimer = New-Object System.Windows.Forms.Timer
$updTimer.Interval = 15000          # first check 15s after start, then every 3 hours
$updTimer.Add_Tick({
    $updTimer.Interval = 3 * 60 * 60 * 1000
    Invoke-UpdateCheck $false
})
$updTimer.Start()

# ---------------------------------------------------------------- weekly clean-up reminder
# Fires 7 days after the last one. If the PC was off at that moment, it fires the next time the app runs.
function Get-ReminderDue {
    $due = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$script:S.NextReminder, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$due)) {
        $due = (Get-Date).AddDays(7)
        $script:S.NextReminder = $due.ToString('o')
        Save-Settings
    }
    return $due
}

function Set-NextReminder([double]$days) {
    $script:S.NextReminder = (Get-Date).AddDays($days).ToString('o')
    Save-Settings
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes / 1GB) }
    return '{0:N0} MB' -f ($bytes / 1MB)
}

function Show-CleanupReminder {
    Set-NextReminder 7
    $lib = $script:S.LibraryPath
    $vids = @(Get-ChildItem -LiteralPath $lib -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $VideoExt -contains $_.Extension.ToLower() })
    $links = @(Get-ChildItem -LiteralPath $lib -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)
    $total = ($vids | Measure-Object -Property Length -Sum).Sum
    if (-not $total) { $total = 0 }
    $eps = @($vids | Where-Object { $_.FullName -like '*\TV Shows\*' }).Count
    $movies = $vids.Count - $eps
    $biggest = @($vids | Sort-Object Length -Descending | Select-Object -First 5)

    $summary = "Your vault has $movies movie(s) and $eps episode(s), using $(Format-Size $total)."
    if ($links.Count) { $summary += " Plus $($links.Count) shortcut(s) to files elsewhere on your PC." }
    $big = @($biggest | ForEach-Object { '- {0}  ({1})' -f [IO.Path]::GetFileNameWithoutExtension($_.Name), (Format-Size $_.Length) })

    $broom = [char]::ConvertFromUtf32(0x1F9F9)
    $tg = "$broom Movie Vault weekly clean-up`n$summary"
    if ($big.Count) { $tg += "`n`nBiggest files:`n" + ($big -join "`n") }
    $tg += "`n`nDelete what you've watched from inside the Movies & TV folder."
    Send-Telegram $tg

    # pop-up window on the PC (stays until you pick something)
    $w = New-Object System.Windows.Forms.Form
    $w.Text = "$App - weekly clean-up"; $w.Icon = $icon; $w.TopMost = $true
    $w.FormBorderStyle = 'FixedDialog'; $w.MaximizeBox = $false; $w.MinimizeBox = $false
    $w.StartPosition = 'CenterScreen'; $w.AutoSize = $true; $w.AutoSizeMode = 'GrowAndShrink'
    $w.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $w.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.FlowDirection = 'TopDown'; $p.AutoSize = $true; $p.Padding = New-Object System.Windows.Forms.Padding(14)
    $w.Controls.Add($p)
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true; $l.MaximumSize = New-Object System.Drawing.Size(460, 0)
    $l.Text = "Time to clean up!`n`n$summary"
    if ($big.Count) { $l.Text += "`n`nBiggest files:`n" + ($big -join "`n") }
    $p.Controls.Add($l)
    $row = New-Object System.Windows.Forms.FlowLayoutPanel
    $row.AutoSize = $true; $row.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
    $bOpen = New-Object System.Windows.Forms.Button; $bOpen.Text = 'Open vault'; $bOpen.AutoSize = $true
    $bLater = New-Object System.Windows.Forms.Button; $bLater.Text = 'Remind me tomorrow'; $bLater.AutoSize = $true
    $bDone = New-Object System.Windows.Forms.Button; $bDone.Text = 'Done for this week'; $bDone.AutoSize = $true
    $row.Controls.Add($bOpen); $row.Controls.Add($bLater); $row.Controls.Add($bDone)
    $p.Controls.Add($row)
    $bOpen.Add_Click({ Open-Vault; $this.FindForm().Close() })
    $bLater.Add_Click({ Set-NextReminder 1; $this.FindForm().Close() })
    $bDone.Add_Click({ $this.FindForm().Close() })
    $w.Show()
    $w.Activate()
}

$remTimer = New-Object System.Windows.Forms.Timer
$remTimer.Interval = 60000          # checks once a minute
$remTimer.Add_Tick({
    if ($script:S.WeeklyReminder -and (Get-Date) -ge (Get-ReminderDue)) {
        try { Show-CleanupReminder } catch { Write-Log "reminder: $_" }
    }
})
[void](Get-ReminderDue)             # first reminder 7 days after installing
$remTimer.Start()

# whole-PC scan: first one a minute after start, then every 6 hours; checks for results every 3s
$pcTimer = New-Object System.Windows.Forms.Timer
$pcTimer.Interval = 3000
$pcTimer.Add_Tick({
    if ($script:PcJob) {
        if ($script:PcJob.Handle.IsCompleted) { Complete-PcScan }
    } elseif ((Get-Date) -ge $script:NextPcScan) {
        $script:NextPcScan = (Get-Date).AddHours(6)
        Start-PcScan $false
    }
})
$pcTimer.Start()

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
    try { $pcTimer.Stop(); if ($script:PcJob) { $script:PcJob.PS.Stop(); $script:PcJob.PS.Dispose() } } catch {}
    $tray.Visible = $false
    $tray.Dispose()
    try { $mutex.ReleaseMutex() } catch {}
}

#Requires -Version 5.1
<#
  WinBoost: makes a Windows 11 PC lighter with a fixed list of safe, reversible tweaks.
    (no switch)  scan, restore point, apply the tweaks that fit this PC, reboot, report after logon
    -DryRun      show the scan and the plan, change nothing
    -After       (run by a one-time logon task) measure again and write the before/after report
    -Undo        put back everything the journal recorded
    -Gaming      force the gaming extras (otherwise added automatically when a game launcher or a dedicated GPU is found): also Game Mode, no background capture, raw mouse, GPU scheduling; keeps game launchers at startup
  Never touches: Defender, Windows Update, UAC, drivers, user files, activation.
#>
param([switch]$DryRun, [switch]$After, [switch]$Undo, [switch]$Gaming)

$Dir     = "$env:ProgramFiles\WinBoost"   # admin-only write: the elevated logon task runs this copy
$Self    = "$Dir\WinBoost.ps1"
$Journal = "$Dir\journal.json"
$Desktop = [Environment]::GetFolderPath('Desktop')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" + ($PSBoundParameters.Keys | ForEach-Object { " -$_" })
    Start-Process powershell.exe $argList -Verb RunAs
    exit
}
New-Item -ItemType Directory -Force $Dir | Out-Null
if ($PSCommandPath -and $PSCommandPath -ne $Self) { Copy-Item $PSCommandPath $Self -Force }
Start-Transcript -Append "$Dir\log.txt" | Out-Null

# ---------- lists (edit here, nowhere else) ----------
$JunkApps = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.ZuneVideo', 'Microsoft.MixedReality.Portal',
    'Microsoft.Microsoft3DViewer', 'Microsoft.3DBuilder', 'Microsoft.SkypeApp', 'Microsoft.Messaging', 'Microsoft.OneConnect',
    'Microsoft.549981C3F5F10', 'MicrosoftTeams', 'Clipchamp.Clipchamp', 'king.com.CandyCrushSaga', 'king.com.CandyCrushSodaSaga',
    'king.com.BubbleWitch3Saga', 'Microsoft.Windows.DevHome', 'Microsoft.MSPaint', 'Microsoft.Office.OneNote', 'Microsoft.Print3D',
    'Microsoft.Wallet', 'Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.BingTravel', 'Microsoft.BingFoodAndDrink', 'Microsoft.BingHealthAndFitness'
)
# Preinstalled promo apps and (on non-gaming PCs) the Xbox apps: removed only if never used, see Test-AppUnused
$PromoApps = 'Disney|TikTok|Facebook\.Instagram|Facebook\.Facebook|AmazonVideo\.PrimeVideo|Booking\.com|ExpressVPN|RoyalMatch|DreamGames|king\.com\.|HiddenCity|MarchofEmpires|WildTangent|Netflix'
$XboxApps  = 'Microsoft.GamingApp', 'Microsoft.XboxApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxSpeechToTextOverlay'

# Startup entries matching these are switched off (same as Task Manager > Startup > Disable). Apps stay installed.
$StartupOff = 'Teams|Spotify|Discord|Steam|EpicGames|Skype|EdgeAutoLaunch|ChromeAutoLaunch|Opera|Brave|CCleaner|AdobeGC|AdobeAAM|Acrobat|iTunesHelper|Zoom|EADM|Origin|Battle\.net|Ubisoft|uTorrent|BitTorrent|Cortana|SunJavaUpdateSched|AdobeARM|LenovoVantage|Lenovo\.Vantage|DellSupportAssist|SupportAssist|HPJumpStart|HPSmartAssistant|HP Support|AsusUpdate|MyASUS'
# Gamers want these running; the gaming tier leaves them at startup
$GameLaunchers = 'Discord|Steam|EpicGames|Battle\.net|Ubisoft|EADM|Origin'

# ---------- journal: every change records the old value so -Undo can put it back ----------
$script:changes = New-Object System.Collections.ArrayList
$script:done    = New-Object System.Collections.ArrayList   # human-readable list for the report

function Save-Journal($extra) {
    $o = [ordered]@{ changes = $script:changes; done = $script:done }
    if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
    $o | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $Journal
}

function Set-Reg($path, $name, $value, $kind = 'DWord') {
    if (-not (Test-Path $path)) { New-Item -Force $path | Out-Null }
    $key = Get-Item $path
    $old = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
    $oldKind = if ($null -ne $old) { "$($key.GetValueKind($name))" } else { $null }
    if ($null -ne $old -and "$old" -eq "$value" -and $oldKind -eq $kind) { return }
    if ($old -is [byte[]]) { $old = [int[]]$old }
    [void]$script:changes.Add(@{ type = 'reg'; path = $path; name = $name; old = $old; kind = $oldKind })
    New-ItemProperty -Force -Path $path -Name $name -Value $value -PropertyType $kind | Out-Null
}

function Set-Svc($name, $startType) {
    $s = Get-CimInstance Win32_Service -Filter "Name='$name'"
    if (-not $s -or $s.StartMode -eq $startType) { return }
    $old = if ($s.StartMode -eq 'Auto') { 'Automatic' } else { $s.StartMode }
    [void]$script:changes.Add(@{ type = 'svc'; name = $name; old = $old })
    Stop-Service $name -Force -ErrorAction SilentlyContinue
    Set-Service $name -StartupType $startType
}

# ---------- scan ----------
function Get-BootMs {
    $e = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction SilentlyContinue
    if (-not $e) { return $null }
    $x = [xml]$e.ToXml()
    $ms = ($x.Event.EventData.Data | Where-Object Name -eq 'BootTime').'#text'
    @{ ms = [int]$ms; at = $e.TimeCreated.ToString('s') }
}

function Get-StartupItems {
    $sa = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $sources = @(
        @{ run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; approved = "HKCU:\$sa\Run" },
        @{ run = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; approved = "HKLM:\$sa\Run" },
        @{ run = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; approved = "HKLM:\$sa\Run32" }
    )
    foreach ($s in $sources) {
        $k = Get-Item $s.run -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        $ap = Get-Item $s.approved -ErrorAction SilentlyContinue
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            $flag = if ($ap) { $ap.GetValue($n) } else { $null }
            [pscustomobject]@{ name = $n; approved = $s.approved; enabled = (-not $flag -or ($flag[0] % 2 -eq 0)); kind = 'run' }
        }
    }
    $folders = @(
        @{ dir = [Environment]::GetFolderPath('Startup'); approved = "HKCU:\$sa\StartupFolder" },
        @{ dir = [Environment]::GetFolderPath('CommonStartup'); approved = "HKLM:\$sa\StartupFolder" }
    )
    foreach ($f in $folders) {
        $ap = Get-Item $f.approved -ErrorAction SilentlyContinue
        foreach ($file in Get-ChildItem $f.dir -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'desktop.ini') {
            $flag = if ($ap) { $ap.GetValue($file.Name) } else { $null }
            [pscustomobject]@{ name = $file.Name; approved = $f.approved; enabled = (-not $flag -or ($flag[0] % 2 -eq 0)); kind = 'run' }
        }
    }
    # Store apps (new Teams, Spotify from the Store...) keep their startup switch here; State 2 = on
    $uwp = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    foreach ($task in Get-ChildItem $uwp -ErrorAction SilentlyContinue | Get-ChildItem -ErrorAction SilentlyContinue) {
        $state = $task.GetValue('State')
        if ($null -eq $state) { continue }
        [pscustomobject]@{ name = $task.PSParentPath.Split('\')[-1]; approved = $task.PSPath; enabled = ($state -eq 2); kind = 'uwp' }
    }
}

# why this looks like a gaming PC (empty = not one): an installed launcher or a dedicated graphics card
function Get-GamerSign {
    $apps = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^(Steam|Epic Games Launcher|Battle\.net|Riot Client|Riot Vanguard|VALORANT|League of Legends|Ubisoft Connect|EA app|GOG GALAXY.*)$' } | Select-Object -ExpandProperty DisplayName
    if (-not $apps -and (Test-Path 'HKCU:\Software\Valve\Steam')) { $apps = 'Steam' }
    $gpu = Get-CimInstance Win32_VideoController | Where-Object Name -match 'GeForce|RTX|GTX|Radeon RX|Radeon Pro|Arc A' | Select-Object -ExpandProperty Name
    @($apps) + @($gpu) | Where-Object { $_ } | Select-Object -Unique
}

# ponytail: "never used" = the app's data folder has no LocalState files and under 64 KB (an opened app writes more);
# a signed-in TikTok or Xbox app is far above that. Upgrade path: read the app's last-launch time if Windows ever exposes it.
function Test-AppUnused($pkg) {
    $d = "$env:LOCALAPPDATA\Packages\$($pkg.PackageFamilyName)"
    if (-not (Test-Path $d)) { return $true }
    $kb = (Get-ChildItem $d -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB
    $ls = @(Get-ChildItem "$d\LocalState" -Recurse -Force -File -ErrorAction SilentlyContinue).Count
    $ls -eq 0 -and $kb -lt 64
}

function Get-JunkApps($isGamer) {
    $all = Get-AppxPackage -AllUsers
    $fixed = $all | Where-Object Name -in $JunkApps
    $maybe = $all | Where-Object { $_.Name -match $PromoApps -or (-not $isGamer -and $_.Name -in $XboxApps) } |
        Where-Object { Get-AppxPackage -Name $_.Name | Where-Object { Test-AppUnused $_ } }
    @($fixed) + @($maybe) | Select-Object -ExpandProperty Name -Unique
}

function Get-Scan {
    $os = Get-CimInstance Win32_OperatingSystem
    $c  = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $sys = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object DeviceId -eq ((Get-Partition -DriveLetter C).DiskNumber)
    [ordered]@{
        at         = (Get-Date).ToString('s')
        os         = "$($os.Caption) $($os.Version)"
        ramGB      = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        cores      = (Get-CimInstance Win32_Processor | Measure-Object NumberOfLogicalProcessors -Sum).Sum
        laptop     = [bool](Get-CimInstance Win32_Battery)
        disk       = if ($sys) { "$($sys.MediaType)" } else { 'Unknown' }
        freeGB     = [math]::Round($c.FreeSpace / 1GB, 2)
        boot       = Get-BootMs
        startupOn  = @(Get-StartupItems | Where-Object enabled).Count
        junkApps   = @(Get-JunkApps ($Gaming -or @(Get-GamerSign).Count))
        processes  = @(Get-Process).Count
        gamer      = @(Get-GamerSign)
        av         = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Where-Object displayName -notmatch 'Defender' | Select-Object -ExpandProperty displayName -Unique)
    }
}

# ---------- tweaks ----------
function Remove-Junk($scan) {
    foreach ($n in $scan.junkApps) {
        # one stubborn app (e.g. 0x80070002 on Windows 10) must not stop the rest
        $ok = $true
        foreach ($pkg in Get-AppxPackage -AllUsers -Name $n) {
            try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop }
            catch {
                try { Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop }
                catch { $ok = $false; Write-Host "  could not remove $n : $($_.Exception.Message.Split([Environment]::NewLine)[0])" }
            }
        }
        if ($ok) {
            [void]$script:done.Add("حذف تطبيق: $n")
            [void]$script:changes.Add(@{ type = 'appx'; name = $n })
        }
    }
    foreach ($pp in Get-AppxProvisionedPackage -Online | Where-Object DisplayName -in @($scan.junkApps)) {
        try { Remove-AppxProvisionedPackage -Online -AllUsers -PackageName $pp.PackageName -ErrorAction Stop | Out-Null } catch { }
    }
}

function Disable-StartupJunk {
    $oneDriveIdle = -not (Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue | Where-Object { $_.GetValue('UserEmail') })
    foreach ($i in Get-StartupItems | Where-Object { $_.enabled -and (($_.name -match $StartupOff -and -not ($Gaming -and $_.name -match $GameLaunchers)) -or ($oneDriveIdle -and $_.name -eq 'OneDrive')) }) {
        if ($i.kind -eq 'uwp') { Set-Reg $i.approved 'State' 1 }
        else { Set-Reg $i.approved $i.name ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary' }
        [void]$script:done.Add("إيقاف التشغيل التلقائي: $($i.name -replace '_[0-9A-Fa-f]{32}$', '')")
    }
}

function Disable-Ads {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($v in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'SubscribedContent-338388Enabled',
        'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
        'SubscribedContent-310093Enabled') { Set-Reg $cdm $v 0 }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    [void]$script:done.Add('إيقاف الإعلانات والاقتراحات وتثبيت التطبيقات الدعائية تلقائياً')
}

function Reduce-Telemetry {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1
    Set-Svc 'DiagTrack' 'Disabled'
    [void]$script:done.Add('تقليل بيانات القياس المرسلة لمايكروسوفت (خدمة DiagTrack)')
}

function Lighten-Visuals {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    [void]$script:done.Add('تخفيف المؤثرات البصرية (الحركة والشفافية) لجهاز بذاكرة محدودة')
}

function Set-FastPower {
    $guid = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    $old = [regex]::Match("$(powercfg /getactivescheme)", $guid).Value
    $ours = 'b0057000-0000-4000-8000-000000000001'   # our copy of Ultimate Performance; fixed so re-runs don't pile up copies
    powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $ours 2>$null | Out-Null
    powercfg /setactive $ours 2>$null
    $label = 'أداء فائق (Ultimate Performance)'
    if ($LASTEXITCODE -ne 0) {   # some PCs only allow High performance
        $ours = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        powercfg /setactive $ours 2>$null
        if ($LASTEXITCODE -ne 0) {
            $ours = [regex]::Match("$(powercfg /duplicatescheme $ours)", $guid).Value
            powercfg /setactive $ours
        }
        $label = 'أداء عالٍ'
    }
    if ($old -ne $ours) { [void]$script:changes.Add(@{ type = 'power'; old = $old }) }
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
    [void]$script:done.Add("خطة طاقة `"$label`" وإيقاف تقييد الطاقة للبرامج (جهاز مكتبي)")
}

function Clear-Junk {
    $before = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace
    $cut = (Get-Date).AddDays(-1)
    foreach ($p in "$env:TEMP", "$env:windir\Temp") {
        Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cut } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:windir\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv, bits -ErrorAction SilentlyContinue
    Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
    Write-Host 'Cleaning old Windows components (5-15 min)...'
    Dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null
    $gb = [math]::Round(((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace - $before) / 1GB, 2)
    [void]$script:done.Add("تنظيف الملفات المؤقتة وبقايا التحديثات ($gb GB)")
}

function Tune-Gaming {
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    foreach ($v in 'MouseSpeed', 'MouseThreshold1', 'MouseThreshold2') { Set-Reg 'HKCU:\Control Panel\Mouse' $v '0' 'String' }
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    $games = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    Set-Reg $games 'GPU Priority' 8
    Set-Reg $games 'Priority' 6
    Set-Reg $games 'Scheduling Category' 'High' 'String'
    Set-Reg $games 'SFIO Priority' 'High' 'String'
    foreach ($if in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue) {
        $ip = "$($if.GetValue('DhcpIPAddress'))$($if.GetValue('IPAddress'))"
        if ($ip -and $ip -notmatch '^(0\.0\.0\.0)*$') { Set-Reg $if.PSPath 'TcpAckFrequency' 1; Set-Reg $if.PSPath 'TCPNoDelay' 1 }
    }
    [void]$script:done.Add('تفعيل وضع الألعاب وإيقاف تسجيل الألعاب في الخلفية')
    [void]$script:done.Add('إلغاء تسريع الماوس (تصويب أدق)')
    [void]$script:done.Add('تفعيل جدولة كرت الشاشة بالعتاد (إن كان الكرت يدعمها)')
    [void]$script:done.Add('أولوية أعلى للألعاب في المعالج وكرت الشاشة، وتقليل تأخير الشبكة (Nagle)')
}

# installed programs using the most RAM/CPU right now; Windows itself and Defender are left out so nobody "closes" them
function Get-TopApps {
    $user = { Get-Process | Where-Object { $_.Id -ne $PID -and $_.Path -and $_.Path -notlike "$env:windir\*" -and $_.Path -notlike '*\Windows Defender\*' } }
    $cores = (Get-CimInstance Win32_Processor | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    $t0 = @{}; foreach ($p in & $user) { $t0[$p.Id] = $p.CPU }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep 3
    $now = @(& $user); $secs = $clock.Elapsed.TotalSeconds
    $now | Group-Object ProcessName | ForEach-Object {
        $cpu = ($_.Group | ForEach-Object { if ($t0.ContainsKey($_.Id)) { $_.CPU - $t0[$_.Id] } } | Measure-Object -Sum).Sum
        [pscustomobject]@{
            name  = $_.Name
            ramMB = [int](($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
            cpu   = [math]::Round(100 * $cpu / $secs / $cores, 1)
        }
    } | Sort-Object ramMB -Descending | Select-Object -First 8
}

function Stop-BrowserBackground {
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $edge 'StartupBoostEnabled' 0
    Set-Reg $edge 'BackgroundModeEnabled' 0
    $chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    if ($chrome | Where-Object { Test-Path $_ }) { Set-Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 0 }
    [void]$script:done.Add('منع المتصفح من العمل في الخلفية بعد إغلاقه ومع بدء التشغيل (Edge وChrome)')
}

function Disable-Widgets {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0                    # Windows 11 Widgets
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0            # Windows 10 news and interests
    [void]$script:done.Add('إيقاف لوحة الأخبار والطقس (Widgets) التي تعمل في الخلفية')
}

function Disable-Hibernation {
    if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled -ne 1) { return }
    $f = Get-Item "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    powercfg /hibernate off
    [void]$script:changes.Add(@{ type = 'hib' })
    $gb = if ($f) { [math]::Round($f.Length / 1GB, 1) } else { 0 }
    [void]$script:done.Add("إيقاف ملف السبات وتحرير $gb GB (جهاز مكتبي)")
}

# popular tweaks: small or no measurable gain, but harmless and reversible
function Tune-Responsiveness($scan) {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
    $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-Reg $sp 'SystemResponsiveness' 10
    Set-Reg $sp 'NetworkThrottlingIndex' -1
    foreach ($t in @(
            @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
            @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
            @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
            @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
            @('\Microsoft\Windows\Autochk\', 'Proxy'))) {
        $task = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
        if ($task -and $task.State -ne 'Disabled') {
            try { Disable-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction Stop | Out-Null; [void]$script:changes.Add(@{ type = 'task'; path = $t[0]; name = $t[1] }) } catch { }
        }
    }
    [void]$script:done.Add('أولوية أعلى للبرنامج المفتوح أمامك، وقوائم أسرع، وإيقاف مهام القياس المجدولة')
}

function Tune-Disk($scan) {
    if ($scan.disk -eq 'SSD') {
        Set-Svc 'SysMain' 'Disabled'
        try { Optimize-Volume -DriveLetter C -ReTrim -ErrorAction Stop } catch { }
        [void]$script:done.Add('صيانة قرص SSD (TRIM) وإيقاف خدمة SysMain غير اللازمة معه')
    }
    elseif ($scan.disk -eq 'HDD') {
        Set-Svc 'WSearch' 'Manual'
        Write-Host 'Defragmenting the hard drive (can take a while)...'
        try { Optimize-Volume -DriveLetter C -Defrag -ErrorAction Stop } catch { }
        [void]$script:done.Add('إلغاء تجزئة القرص الصلب وتخفيف فهرسة البحث عليه')
    }
}

function Remove-Clutter {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    foreach ($v in 'HubsSidebarEnabled', 'EdgeShoppingAssistantEnabled', 'ShowRecommendationsEnabled', 'NewTabPageContentEnabled', 'PersonalizationReportingEnabled') { Set-Reg $edge $v 0 }
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    foreach ($v in 'ShowCopilotButton', 'ShowTaskViewButton', 'TaskbarMn') { Set-Reg $adv $v 0 }
    [void]$script:done.Add('إزالة نتائج الإنترنت والإعلانات من بحث قائمة ابدأ (بحث أسرع)')
    [void]$script:done.Add('تنظيف Edge من الشريط الجانبي ونوافذ التسوق والأخبار في الصفحة الجديدة')
    [void]$script:done.Add('إخفاء أزرار Copilot وعرض المهام والدردشة من شريط المهام')
}

function Get-Plan($scan) {
    $plan = @('Remove-Junk', 'Disable-StartupJunk', 'Disable-Ads', 'Reduce-Telemetry', 'Stop-BrowserBackground', 'Disable-Widgets', 'Remove-Clutter', 'Tune-Responsiveness', 'Clear-Junk', 'Tune-Disk')
    if ($scan.ramGB -le 8 -or $scan.cores -le 4) { $plan += 'Lighten-Visuals' }
    if (-not $scan.laptop) { $plan += 'Set-FastPower'; $plan += 'Disable-Hibernation' }
    if ($Gaming -or $scan.gamer) { $plan += 'Tune-Gaming' }
    $plan
}

# ---------- report ----------
function Write-Report($j, $afterScan) {
    $b = $j.before
    function Row($label, $x, $y) { "<tr><td>$label</td><td><bdi>$x</bdi></td><td><bdi>$y</bdi></td></tr>" }
    $rows = (Row 'برامج تعمل مع بدء التشغيل' $b.startupOn $afterScan.startupOn) +
            (Row 'تطبيقات غير ضرورية مثبتة' $b.junkApps.Count $afterScan.junkApps.Count) +
            (Row 'المساحة الفارغة في C:' "$($b.freeGB) GB" "$($afterScan.freeGB) GB")
    $top = ($afterScan.topApps | ForEach-Object { "<tr><td><bdi>$([Net.WebUtility]::HtmlEncode($_.name))</bdi></td><td><bdi>$($_.ramMB) MB</bdi></td><td><bdi>$($_.cpu)%</bdi></td></tr>" }) -join ''
    $tier = if ($j.gaming) { ' · وضع الألعاب' } else { '' }
    if ([int]$j.run -gt 1) { $tier += " · إعادة التسريع رقم $($j.run)" }
    $notes = @()
    $trial = @($b.av) -match 'McAfee|Norton'
    if ($trial) { $notes += "وجدنا برنامج الحماية <b>$([Net.WebUtility]::HtmlEncode($trial[0]))</b>. هذه البرامج تأتي غالباً كنسخة تجريبية مع الأجهزة الجديدة وتبطئها كثيراً. إن لم تكن مشتركاً فيه، احذفه من الإعدادات ثم التطبيقات، ومكافح فيروسات ويندوز يعمل تلقائياً بعده." }
    if (@($j.plan) -contains 'Stop-BrowserBackground') { $notes += 'قد يظهر في إعدادات Edge أو Chrome سطر «يُدار بواسطة مؤسستك». هذا طبيعي وسببه فقط إعداد منع المتصفح من العمل في الخلفية، ويختفي عند التراجع.' }
    $notesHtml = if ($notes) { '<h2>ملاحظات</h2><ul>' + (($notes | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>' } else { '' }
    $items = ($j.done | ForEach-Object { "<li>$([Net.WebUtility]::HtmlEncode($_))</li>" }) -join ''
    $html = @"
<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><title>تقرير تسريع الجهاز</title>
<style>body{font-family:'Segoe UI',Tahoma,sans-serif;max-width:720px;margin:40px auto;padding:0 16px;color:#1a1a1a;line-height:1.7}
table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px 12px;text-align:start}th{background:#f4f4f4}
.n{color:#666;font-size:14px}</style>
<h1>تقرير تسريع الجهاز$tier</h1>
<p class="n" dir="ltr">$($b.os) · RAM $($b.ramGB) GB · $($env:COMPUTERNAME) · $((Get-Date).ToString('yyyy-MM-dd HH:mm'))</p>
<h2>قبل وبعد</h2>
<table><tr><th>المقياس</th><th>قبل</th><th>بعد</th></tr>$rows</table>
<h2>أكثر البرامج استهلاكاً بعد التشغيل</h2>
<p class="n">برامجك المثبتة فقط (بدون ملفات ويندوز ومكافح الفيروسات). إن كان برنامج لا تستخدمه في أعلى القائمة، فإغلاقه أو حذفه يعطي أكبر فرق.</p>
<table><tr><th>البرنامج</th><th>الذاكرة</th><th>المعالج</th></tr>$top</table>
$notesHtml
<h2>ما تم عمله</h2><ul>$items</ul>
<h2>للتراجع</h2>
<p>شغّل اختصار <b>WinBoost Undo</b> على سطح المكتب لإرجاع كل الإعدادات. التطبيقات المحذوفة يمكن تثبيتها مجدداً من متجر مايكروسوفت.
تم أيضاً إنشاء نقطة استعادة للنظام باسم <b>WinBoost</b> قبل أي تغيير.</p>
<p class="n">لم يتم المساس بمكافح الفيروسات، تحديثات ويندوز، التعريفات أو ملفاتك الشخصية.</p></html>
"@
    $path = Join-Path $Desktop 'WinBoost-Report.html'
    [IO.File]::WriteAllText($path, $html, (New-Object Text.UTF8Encoding $true))
    $path
}

# ---------- modes ----------
if ($Undo) {
    Unregister-ScheduledTask -TaskName WinBoostAfter -Confirm:$false -ErrorAction SilentlyContinue   # undo before the restart
    if (-not (Test-Path $Journal)) {
        Write-Host 'Nothing to undo: WinBoost has no active changes on this PC. / لا توجد تغييرات للتراجع عنها.'
        Remove-Item (Join-Path $Desktop 'WinBoost Undo.lnk') -ErrorAction SilentlyContinue
        Stop-Transcript | Out-Null; Read-Host 'Press Enter to close / اضغط Enter للإغلاق'; exit
    }
    $j = Get-Content $Journal -Raw | ConvertFrom-Json
    $list = @($j.changes); [array]::Reverse($list)
    foreach ($c in $list) {
        switch ($c.type) {
            'reg' {
                if ($null -eq $c.old) { Remove-ItemProperty -Path $c.path -Name $c.name -ErrorAction SilentlyContinue }
                else {
                    $v = if ($c.kind -eq 'Binary') { [byte[]]$c.old } else { $c.old }
                    New-ItemProperty -Force -Path $c.path -Name $c.name -Value $v -PropertyType $c.kind | Out-Null
                }
            }
            'svc'   { Set-Service $c.name -StartupType $c.old; if ($c.old -eq 'Automatic') { Start-Service $c.name -ErrorAction SilentlyContinue } }
            'power' { powercfg /setactive $c.old }
            'hib'   { powercfg /hibernate on }
            'task'  { Enable-ScheduledTask -TaskPath $c.path -TaskName $c.name -ErrorAction SilentlyContinue | Out-Null }
            'appx'  { Write-Host "Removed app (reinstall from Microsoft Store if needed): $($c.name)" }
        }
    }
    Rename-Item $Journal "$Journal.undone-$(Get-Date -Format yyyyMMddHHmm)"
    Remove-Item (Join-Path $Desktop 'WinBoost Undo.lnk') -ErrorAction SilentlyContinue
    $n = @($list | Where-Object type -ne 'appx').Count
    Write-Host ''
    Write-Host "Done: $n settings restored to how they were before WinBoost. Removed apps can be reinstalled from the Microsoft Store."
    Write-Host "تم: إرجاع $n إعداد كما كان قبل التسريع. التطبيقات المحذوفة يمكن تثبيتها من متجر مايكروسوفت."
    Stop-Transcript | Out-Null
    $r = Read-Host 'Restart now to finish? (Y/N) / إعادة التشغيل الآن؟'
    if ($r -match '^(y|yes|ن|نعم)$') { Restart-Computer -Force }
    exit
}

if ($After) {
    Unregister-ScheduledTask -TaskName WinBoostAfter -Confirm:$false -ErrorAction SilentlyContinue
    $j = Get-Content $Journal -Raw | ConvertFrom-Json
    Start-Sleep 60   # let startup programs load before measuring what uses RAM/CPU
    $a = Get-Scan
    $a['topApps'] = @(Get-TopApps)
    $j | Add-Member -Force after $a
    $j | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $Journal
    Start-Process (Write-Report $j $a)
    Stop-Transcript | Out-Null
    exit
}

$scan = Get-Scan
$plan = Get-Plan $scan
$Gaming = [bool]($Gaming -or $scan.gamer)   # the startup filter and the journal read this
Write-Host ($scan | ConvertTo-Json -Depth 4)
Write-Host "Plan: $($plan -join ', ')"
if ($DryRun) { Stop-Transcript | Out-Null; exit }

# Re-run (e.g. after a big Windows update): keep the earlier changes in the journal so -Undo,
# which walks it newest-first, still ends at the PC's original values; this run only adds what Windows put back
$run = 1
if (Test-Path $Journal) {
    $prev = Get-Content $Journal -Raw | ConvertFrom-Json
    foreach ($c in $prev.changes) { [void]$script:changes.Add($c) }
    $run = 1 + [math]::Max(1, [int]$prev.run)   # journals from before re-runs existed have no run number
    Write-Host "Re-run #$($run): re-applying what Windows changed back."
}

# restore point first, or stop: no change without a way back
Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
$freq = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
New-ItemProperty -Force $freq SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord | Out-Null
try { Checkpoint-Computer -Description 'WinBoost' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
catch {
    Write-Host "Could not create a restore point, nothing was changed: $_ / تعذر إنشاء نقطة استعادة، لم يتم تغيير أي شيء."
    Stop-Transcript | Out-Null; Read-Host 'Press Enter to close / اضغط Enter للإغلاق'; exit 1
}
finally { Remove-ItemProperty $freq SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }

foreach ($step in $plan) {
    Write-Host "== $step"
    try { & $step $scan } catch { Write-Host "  skipped: $_" }
    Save-Journal @{ before = $scan; plan = $plan; gaming = [bool]$Gaming; run = $run; appliedAt = (Get-Date).ToString('s') }
}

$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $Desktop 'WinBoost Undo.lnk'))
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Self`" -Undo"
$lnk.Save()

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action  = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Self`" -After"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
$trigger.Delay = 'PT1M'
Register-ScheduledTask -TaskName WinBoostAfter -Action $action -Trigger $trigger -RunLevel Highest -User $me -Force | Out-Null

Stop-Transcript | Out-Null
Write-Host ''
Write-Host 'Done. The PC restarts in 60 seconds; the report opens after you sign in. / تم. سيعاد تشغيل الجهاز خلال 60 ثانية وسيظهر التقرير بعد الدخول.'
shutdown.exe /r /t 60 /c "WinBoost: restarting to finish"

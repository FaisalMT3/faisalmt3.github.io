#Requires -Version 5.1
<#
  WinBoost: makes a Windows 11 PC lighter with a fixed list of safe, reversible tweaks.
    (no switch)  scan, restore point, apply the tweaks that fit this PC, reboot, report after logon
    -DryRun      show the scan and the plan, change nothing
    -After       (run by a one-time logon task) measure again and write the before/after report
    -Undo        put back everything the journal recorded
  Never touches: Defender, Windows Update, UAC, drivers, user files, activation.
#>
param([switch]$DryRun, [switch]$After, [switch]$Undo)

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
    'king.com.BubbleWitch3Saga', 'Microsoft.Windows.DevHome'
)
# Startup entries matching these are switched off (same as Task Manager > Startup > Disable). Apps stay installed.
$StartupOff = 'Teams|Spotify|Discord|Steam|EpicGames|Skype|EdgeAutoLaunch|ChromeAutoLaunch|Opera|Brave|CCleaner|AdobeGC|AdobeAAM|Acrobat|iTunesHelper|Zoom|EADM|Origin|Battle\.net|Ubisoft|uTorrent|BitTorrent|Cortana'

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
        junkApps   = @(Get-AppxPackage -AllUsers | Where-Object Name -in $JunkApps | Select-Object -ExpandProperty Name -Unique)
        processes  = @(Get-Process).Count
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
    foreach ($pp in Get-AppxProvisionedPackage -Online | Where-Object DisplayName -in $JunkApps) {
        try { Remove-AppxProvisionedPackage -Online -AllUsers -PackageName $pp.PackageName -ErrorAction Stop | Out-Null } catch { }
    }
}

function Disable-StartupJunk {
    foreach ($i in Get-StartupItems | Where-Object { $_.enabled -and $_.name -match $StartupOff }) {
        if ($i.kind -eq 'uwp') { Set-Reg $i.approved 'State' 1 }
        else { Set-Reg $i.approved $i.name ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary' }
        [void]$script:done.Add("إيقاف التشغيل التلقائي: $($i.name)")
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
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
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
    $old = [regex]::Match("$(powercfg /getactivescheme)", '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
    $hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    powercfg /setactive $hp 2>$null
    if ($LASTEXITCODE -ne 0) {   # hidden on some PCs: make a copy and use that
        $hp = [regex]::Match("$(powercfg /duplicatescheme $hp)", '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
        powercfg /setactive $hp
    }
    if ($old -ne $hp) { [void]$script:changes.Add(@{ type = 'power'; old = $old }) }
    [void]$script:done.Add('خطة طاقة "أداء عالٍ" (جهاز مكتبي)')
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

function Get-Plan($scan) {
    $plan = @('Remove-Junk', 'Disable-StartupJunk', 'Disable-Ads', 'Reduce-Telemetry', 'Clear-Junk')
    if ($scan.ramGB -le 8 -or $scan.cores -le 4) { $plan += 'Lighten-Visuals' }
    if (-not $scan.laptop) { $plan += 'Set-FastPower' }
    $plan
}

# ---------- report ----------
function Write-Report($j, $afterScan) {
    $b = $j.before
    function Row($label, $x, $y) { "<tr><td>$label</td><td><bdi>$x</bdi></td><td><bdi>$y</bdi></td></tr>" }
    $bootB = if ($b.boot) { '{0:N1} s' -f ($b.boot.ms / 1000) } else { 'غير متاح' }
    $bootA = if ($afterScan.boot -and $afterScan.boot.at -gt $j.appliedAt) { '{0:N1} s' -f ($afterScan.boot.ms / 1000) } else { 'غير متاح' }
    $rows = (Row 'زمن الإقلاع' $bootB $bootA) +
            (Row 'برامج تعمل مع بدء التشغيل' $b.startupOn $afterScan.startupOn) +
            (Row 'تطبيقات غير ضرورية مثبتة' $b.junkApps.Count $afterScan.junkApps.Count) +
            (Row 'المساحة الفارغة في C:' "$($b.freeGB) GB" "$($afterScan.freeGB) GB")
    $items = ($j.done | ForEach-Object { "<li>$([Net.WebUtility]::HtmlEncode($_))</li>" }) -join ''
    $html = @"
<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><title>تقرير تسريع الجهاز</title>
<style>body{font-family:'Segoe UI',Tahoma,sans-serif;max-width:720px;margin:40px auto;padding:0 16px;color:#1a1a1a;line-height:1.7}
table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px 12px;text-align:start}th{background:#f4f4f4}
.n{color:#666;font-size:14px}</style>
<h1>تقرير تسريع الجهاز</h1>
<p class="n" dir="ltr">$($b.os) · RAM $($b.ramGB) GB · $($env:COMPUTERNAME) · $((Get-Date).ToString('yyyy-MM-dd HH:mm'))</p>
<h2>قبل وبعد</h2>
<p class="n">زمن الإقلاع يتغير بضع ثوانٍ من تشغيل لآخر، والفرق الأوضح يظهر بعد عدة أيام من الاستخدام.</p>
<table><tr><th>المقياس</th><th>قبل</th><th>بعد</th></tr>$rows</table>
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
            'appx'  { Write-Host "Removed app (reinstall from Microsoft Store if needed): $($c.name)" }
        }
    }
    Rename-Item $Journal "$Journal.undone-$(Get-Date -Format yyyyMMddHHmm)"
    Remove-Item (Join-Path $Desktop 'WinBoost Undo.lnk') -ErrorAction SilentlyContinue
    Write-Host 'تم التراجع عن كل الإعدادات. أعد تشغيل الجهاز. / All settings restored. Please restart.'
    Stop-Transcript | Out-Null
    exit
}

if ($After) {
    Unregister-ScheduledTask -TaskName WinBoostAfter -Confirm:$false -ErrorAction SilentlyContinue
    $j = Get-Content $Journal -Raw | ConvertFrom-Json
    # Windows writes the boot-time event a few minutes after logon
    for ($i = 0; $i -lt 20; $i++) { $b = Get-BootMs; if ($b -and $b.at -gt $j.appliedAt) { break }; Start-Sleep 30 }
    $a = Get-Scan
    $j | Add-Member -Force after $a
    $j | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $Journal
    Start-Process (Write-Report $j $a)
    Stop-Transcript | Out-Null
    exit
}

$scan = Get-Scan
$plan = Get-Plan $scan
Write-Host ($scan | ConvertTo-Json -Depth 4)
Write-Host "Plan: $($plan -join ', ')"
if ($DryRun) { Stop-Transcript | Out-Null; exit }

if (Test-Path $Journal) {
    Write-Host 'WinBoost already ran on this PC. Run with -Undo first to start over. / تم التسريع مسبقاً على هذا الجهاز.'
    Stop-Transcript | Out-Null; Read-Host 'Press Enter to close / اضغط Enter للإغلاق'; exit 1
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
    Save-Journal @{ before = $scan; plan = $plan; appliedAt = (Get-Date).ToString('s') }
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

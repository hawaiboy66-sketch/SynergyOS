param (
    [switch]$Chrome,
    [switch]$Brave,
    [switch]$Firefox,
    [switch]$SynToolkit,
    [switch]$MacLook,
    [switch]$SecureUxTheme
)

# ----------------------------------------------------------------------------------------------------------- #
# Direct downloads with hidden installers — fast, reliable, and fully silent during playbook execution.       #
# ----------------------------------------------------------------------------------------------------------- #

# --fail is required: without it curl exits 0 on an HTTP 404/500 and happily writes
# the error page to the output path, which then gets Start-Process'd as if it were
# the installer. --proto =https keeps a hijacked redirect from downgrading to http.
$timeouts = @("--fail", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10", "--retry", "5", "--retry-delay", "0", "--retry-all-errors")
$msiArgs = "/qn /quiet /norestart ALLUSERS=1 REBOOT=ReallySuppress"
$arm = ((Get-CimInstance -Class Win32_ComputerSystem).SystemType -match 'ARM64') -or ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64')

function Remove-TempDirectory {
    Pop-Location
    Remove-Item -Path $tempDir -Force -Recurse -EA 0
}

# Download to $Path and refuse to return unless we got a real file. $Sha256 is
# optional; when supplied the file is rejected on mismatch. `if (!$?)` was not a
# reliable check after curl.exe - $LASTEXITCODE is.
function Get-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Sha256
    )

    & curl.exe -LSs $Url -o $Path $timeouts

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Downloading $Name failed (curl exit $LASTEXITCODE)."
        return $false
    }

    if (!(Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        Write-Error "Downloading $Name produced no file."
        return $false
    }

    if ($Sha256) {
        $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) {
            Write-Error "$Name failed checksum verification. Expected $Sha256, got $actual."
            Remove-Item -Path $Path -Force -EA 0
            return $false
        }
        # Write-Host, not Write-Output: anything written to the output pipeline inside
        # this function would be returned alongside the boolean and break the callers.
        Write-Host "$Name checksum verified."
    }

    return $true
}

$tempDir = Join-Path -Path $env:TEMP -ChildPath ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Push-Location $tempDir

# SynToolkit
# The release URL is version-pinned, so the checksum can be pinned alongside it.
# Update both together when bumping the SynToolkit version.
$synToolkitSha256 = '110928B39A7B62356A9893A3C7116D68DCD2691A66B59E7FCE1856E195275843'
if ($SynToolkit) {
    Write-Output "Downloading SynToolkit..."
    if (!(Get-RemoteFile -Url "https://github.com/Synergy-Tweaks/SynToolkit/releases/download/1.5/SynToolkit-Setup.exe" `
                         -Path "$tempDir\SynToolkit-Setup.exe" -Name "SynToolkit" -Sha256 $synToolkitSha256)) {
        Remove-TempDirectory
        exit 1
    }

    Write-Output "Installing SynToolkit..."
    Start-Process -FilePath "$tempDir\SynToolkit-Setup.exe" -WindowStyle Hidden -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait

    Remove-TempDirectory
    exit
}

# SecureUxTheme
# Lifts the signature check that stops Windows loading third-party .msstyles, so
# custom visual styles can be picked from Personalization. No theme is bundled -
# the ones worth having are not redistributable - this only unlocks the loader.
# Version-pinned, so the checksums are pinned alongside it; update all three together.
$secureUxThemeSha256 = @{
    'x64'   = 'AF6AB67E0A283A0138B827B6731D5BB1F4FFC59E6D905F1C41567EB3305A9537'
    'ARM64' = '2E5CF62249ABDB1D9F6C3B81567587BD13C2094A067B2FA753FDE9BD31A14DFB'
}
if ($SecureUxTheme) {
    $uxArch = ('x64', 'ARM64')[$arm]

    Write-Output "Downloading SecureUxTheme..."
    if (!(Get-RemoteFile -Url "https://github.com/namazso/SecureUxTheme/releases/download/v4.0.0/SecureUxTheme_$uxArch.msi" `
                         -Path "$tempDir\SecureUxTheme.msi" -Name "SecureUxTheme" -Sha256 $secureUxThemeSha256[$uxArch])) {
        Remove-TempDirectory
        exit 1
    }

    Write-Output "Installing SecureUxTheme..."
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$tempDir\SecureUxTheme.msi`" $msiArgs" -WindowStyle Hidden -Wait

    Remove-TempDirectory
    exit
}

# macOS look - cursors and selection colour
# MIT-licensed cursor set from ful1e5/apple_cursor - the bundled install.inf is not used,
# it writes the scheme string in a non-standard order. The release URL is version-pinned,
# so the checksum is pinned alongside it. Update both together when bumping the version.
# Must run as the logged-in user: the scheme lives in HKCU.
$macCursorsSha256 = '64A2C74780908954A2EC497F67919709280EBB8EBDF3E3B9336BAC071589C9DE'
if ($MacLook) {
    $scheme = 'macOS-Regular Cursors'
    $cursorDir = "$env:SystemRoot\Cursors\$scheme"

    # Order matters only for the Schemes value, which Windows reads positionally.
    $cursors = [ordered]@{
        Arrow       = 'Pointer.cur'
        Help        = 'Help.cur'
        AppStarting = 'Work.ani'
        Wait        = 'Busy.ani'
        Crosshair   = 'Cross.cur'
        IBeam       = 'Text.cur'
        NWPen       = 'Handwriting.cur'
        No          = 'Unavailiable.cur'
        SizeNS      = 'Vert.cur'
        SizeWE      = 'Horz.cur'
        SizeNWSE    = 'Dng1.cur'
        SizeNESW    = 'Dng2.cur'
        SizeAll     = 'Move.cur'
        UpArrow     = 'Alternate.cur'
        Hand        = 'Link.cur'
    }

    Write-Output "Downloading macOS cursors..."
    if (!(Get-RemoteFile -Url "https://github.com/ful1e5/apple_cursor/releases/download/v2.0.1/macOS-Windows.zip" `
                         -Path "$tempDir\macOS-cursors.zip" -Name "macOS cursors" -Sha256 $macCursorsSha256)) {
        Remove-TempDirectory
        exit 1
    }

    Expand-Archive -Path "$tempDir\macOS-cursors.zip" -DestinationPath "$tempDir\macOS-cursors" -Force
    $extracted = "$tempDir\macOS-cursors\macOS-Regular-Windows"

    # A silently half-applied scheme leaves the pointer as a black square, so bail out
    # before touching the registry if the archive layout is not what we expect.
    $missing = $cursors.Values | Where-Object { !(Test-Path "$extracted\$_") }
    if ($missing) {
        Write-Error "macOS cursor archive is missing: $($missing -join ', '). Not applying the scheme."
        Remove-TempDirectory
        exit 1
    }

    Write-Output "Installing macOS cursors..."
    New-Item -ItemType Directory -Path $cursorDir -Force | Out-Null
    Copy-Item -Path "$extracted\*" -Include *.cur, *.ani -Destination $cursorDir -Force

    New-Item -Path 'HKCU:\Control Panel\Cursors\Schemes' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\Control Panel\Cursors\Schemes' -Name $scheme `
                     -Value (($cursors.Values | ForEach-Object { "$cursorDir\$_" }) -join ',')

    Set-ItemProperty -Path 'HKCU:\Control Panel\Cursors' -Name '(default)' -Value $scheme
    foreach ($cursor in $cursors.GetEnumerator()) {
        Set-ItemProperty -Path 'HKCU:\Control Panel\Cursors' -Name $cursor.Key -Value "$cursorDir\$($cursor.Value)"
    }

    Add-Type -Namespace Win32 -Name Look -MemberDefinition '
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SystemParametersInfo(uint action, uint param, IntPtr data, uint update);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetSysColors(int count, int[] elements, int[] colors);'

    # SPI_SETCURSORS reloads the pointers now, so the scheme applies without a reboot.
    [Win32.Look]::SystemParametersInfo(0x0057, 0, [IntPtr]::Zero, 0) | Out-Null

    # Selection highlight: Windows' blue -> macOS-style graphite grey.
    # Two separate systems draw it. Classic apps read Control Panel\Colors, where the
    # text colour has to move to black in the same pass or selected text goes white on
    # white. Explorer and anything XAML read the accent palette instead.
    Write-Output "Applying graphite selection colour..."
    Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name 'Hilight' -Value '200 200 200'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name 'HotTrackingColor' -Value '160 160 160'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name 'HilightText' -Value '0 0 0'
    # COLOR_HIGHLIGHT / COLOR_HIGHLIGHTTEXT, applied live to already-running apps.
    [Win32.Look]::SetSysColors(2, @(13, 14), @(0xC8C8C8, 0x000000)) | Out-Null

    # Light-to-dark accent ramp. Deliberately pure greys: every byte of a grey is the
    # same, so the palette's channel order stops mattering and cannot be got wrong.
    $accentPalette = [byte[]] @(
        0xE8, 0xE8, 0xE8, 0x00,   # light 3
        0xDE, 0xDE, 0xDE, 0x00,   # light 2
        0xD4, 0xD4, 0xD4, 0x00,   # light 1
        0xC8, 0xC8, 0xC8, 0x00,   # base - this is the one Explorer selects with
        0xA0, 0xA0, 0xA0, 0x00,   # dark 1
        0x80, 0x80, 0x80, 0x00,   # dark 2
        0x60, 0x60, 0x60, 0x00,   # dark 3
        0x00, 0x00, 0x00, 0x00
    )

    New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Force | Out-Null
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentPalette' -Value $accentPalette -Type Binary
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value 0xFFC8C8C8 -Type DWord
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value 0xFFA0A0A0 -Type DWord
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -Name 'AccentColor' -Value 0xFFC8C8C8 -Type DWord
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -Name 'ColorizationColor' -Value 0xC4C8C8C8 -Type DWord
    # Keeps the grey off the title bars - macOS does not tint them.
    Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' -Name 'ColorPrevalence' -Value 0 -Type DWord

    Remove-TempDirectory
    exit
}

# Brave
if ($Brave) {
    Write-Output "Downloading Brave..."
    if (!(Get-RemoteFile -Url "https://laptop-updates.brave.com/latest/winx64" `
                         -Path "$tempDir\BraveSetup.exe" -Name "Brave")) {
        Remove-TempDirectory
        exit 1
    }

    Write-Output "Installing Brave..."
    Start-Process -FilePath "$tempDir\BraveSetup.exe" -WindowStyle Hidden -ArgumentList '/silent /install'

    do {
        $processesFound = Get-Process | Where-Object { "BraveSetup" -contains $_.Name } | Select-Object -ExpandProperty Name
        if ($processesFound) {
            Write-Output "Still running BraveSetup."
            Start-Sleep -Seconds 2
        }
        else {
            Remove-TempDirectory
        }
    } until (!$processesFound)

    Stop-Process -Name "brave" -Force -EA 0

    exit
}

# Firefox
if ($Firefox) {
    $firefoxArch = ('win64', 'win64-aarch64')[$arm]

    Write-Output "Downloading Firefox..."
    if (!(Get-RemoteFile -Url "https://download.mozilla.org/?product=firefox-latest-ssl&os=$firefoxArch&lang=en-US" `
                         -Path "$tempDir\firefox.exe" -Name "Firefox")) {
        Remove-TempDirectory
        exit 1
    }

    Write-Output "Installing Firefox..."
    Start-Process -FilePath "$tempDir\firefox.exe" -WindowStyle Hidden -ArgumentList '/S /ALLUSERS=1' -Wait

    Remove-TempDirectory
    exit
}

# Chrome
if ($Chrome) {
    Write-Output "Downloading Google Chrome..."
    $chromeArch = ('64', '_Arm64')[$arm]
    if (!(Get-RemoteFile -Url "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise$chromeArch.msi" `
                         -Path "$tempDir\chrome.msi" -Name "Google Chrome")) {
        Remove-TempDirectory
        exit 1
    }

    Write-Output "Installing Google Chrome..."
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$tempDir\chrome.msi`" /qn /norestart" -WindowStyle Hidden -Wait

    Remove-TempDirectory
    exit
}

#####################
##    Utilities    ##
#####################

# Visual C++ Runtimes (referred to as vcredists for short)
# https://learn.microsoft.com/en-US/cpp/windows/latest-supported-vc-redist
$legacyArgs = '/q /norestart'
$modernArgs = "/install /quiet /norestart"

$vcredists = [ordered]@{
    # 2005 - version 8.0.50727.6195 (MSI 8.0.61000/8.0.61001) SP1
    "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.exe"       = @("2005-x64", "/c /q /t:")
    "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.exe"       = @("2005-x86", "/c /q /t:")
    # 2008 - version 9.0.30729.6161 (EXE 9.0.30729.5677) SP1
    "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe"       = @("2008-x64", "/q /extract:")
    "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe"       = @("2008-x86", "/q /extract:")
    # 2010 - version 10.0.40219.325 SP1
    "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe"       = @("2010-x64", $legacyArgs)
    "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe"       = @("2010-x86", $legacyArgs)
    # 2012 - version 11.0.61030.0
    "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe" = @("2012-x64", $modernArgs)
    "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe" = @("2012-x86", $modernArgs)
    # 2013 - version 12.0.40664.0
    "https://aka.ms/highdpimfc2013x64enu"                                                                       = @("2013-x64", $modernArgs)
    "https://aka.ms/highdpimfc2013x86enu"                                                                       = @("2013-x86", $modernArgs)
    # 2015-2022 (2015+) - latest version
    "https://aka.ms/vs/17/release/vc_redist.x64.exe"                                                            = @("2015+-x64", $modernArgs)
    "https://aka.ms/vs/17/release/vc_redist.x86.exe"                                                            = @("2015+-x86", $modernArgs)
}

foreach ($a in $vcredists.GetEnumerator()) {
    $vcName = $a.Value[0]
    $vcArgs = $a.Value[1]
    $vcUrl = $a.Name
    $vcExePath = "$tempDir\vcredist-$vcName.exe"

    Write-Output "Downloading and installing Visual C++ Runtime $vcName..."
    if (!(Get-RemoteFile -Url $vcUrl -Path $vcExePath -Name "Visual C++ Runtime $vcName")) {
        Write-Output "Skipping Visual C++ Runtime $vcName."
        continue
    }

    if ($vcArgs -match ":") {
        $msiDir = "$tempDir\vcredist-$vcName"
        Start-Process -FilePath $vcExePath -ArgumentList "$vcArgs`"$msiDir`"" -Wait -WindowStyle Hidden

        $msiPaths = (Get-ChildItem -Path $msiDir -Filter *.msi -EA 0).FullName
        if (!$msiPaths) {
            Write-Output "Failed to extract MSI for $vcName, not installing."
        }
        else {
            $msiPaths | ForEach-Object {
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/log `"$msiDir\logfile.log`" /i `"$_`" $msiArgs" -WindowStyle Hidden -Wait
            }
        }
    }
    else {
        Start-Process -FilePath $vcExePath -ArgumentList $vcArgs -Wait -WindowStyle Hidden
    }
}

# 7-Zip
# The download URL is scraped from the 7-zip.org homepage, so the scrape result has
# to be validated before it is used - previously a layout change upstream produced an
# empty/multi-value match that was concatenated into a junk URL and executed anyway.
$website = 'https://7-zip.org/'
$7zipArch = ('x64', 'arm64')[$arm]
$7zipLink = @((Invoke-WebRequest $website -UseBasicParsing).Links.href | Where-Object { $_ -like "a/7z*-$7zipArch.exe" })

if ($7zipLink.Count -ne 1) {
    Write-Error "Could not determine the 7-Zip download URL ($($7zipLink.Count) candidates). Skipping 7-Zip."
}
else {
    $download = $website + $7zipLink[0]
    Write-Output "Downloading 7-Zip..."
    if (Get-RemoteFile -Url $download -Path "$tempDir\7zip.exe" -Name "7-Zip") {
        Write-Output "Installing 7-Zip..."
        Start-Process -FilePath "$tempDir\7zip.exe" -WindowStyle Hidden -ArgumentList '/S' -Wait
    }
}

# Legacy DirectX runtimes
Write-Output "Downloading legacy DirectX runtimes..."
if (Get-RemoteFile -Url "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe" `
                   -Path "$tempDir\directx.exe" -Name "legacy DirectX runtimes") {
    Write-Output "Extracting legacy DirectX runtimes..."
    Start-Process -FilePath "$tempDir\directx.exe" -WindowStyle Hidden -ArgumentList "/q /c /t:`"$tempDir\directx`"" -Wait

    if (Test-Path "$tempDir\directx\dxsetup.exe") {
        Write-Output "Installing legacy DirectX runtimes..."
        Start-Process -FilePath "$tempDir\directx\dxsetup.exe" -WindowStyle Hidden -ArgumentList '/silent' -Wait
    }
    else {
        Write-Error "DirectX redist did not extract as expected, skipping install."
    }
}

Remove-TempDirectory

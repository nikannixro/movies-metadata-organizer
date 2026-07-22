# ============================================================================
# Kaelix — Windows Installer
# https://github.com/nikannixro/kaelix
# ============================================================================
param(
    [switch]$Uninstall,
    [switch]$Quiet,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$REPO_URL = "https://github.com/nikannixro/kaelix.git"
$REPO_NAME = "kaelix"

# --- Admin detection (from winutil.ps1) ---------------------------------------

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Kaelix installer requires Administrator privileges. Attempting to relaunch..." -ForegroundColor Yellow

    $argList = @()
    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://kaelix.pages.dev/install.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# --- Logging ------------------------------------------------------------------

$script:LogDir = Join-Path $env:TEMP "kaelix"
if (-not (Test-Path $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}
$script:LogFile = Join-Path $script:LogDir "install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
}

# --- Output helpers ------------------------------------------------------------

function Show-Banner {
    $width = 80
    $height = 24
    try {
        if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width }
        if ($Host.UI.RawUI.WindowSize.Height -gt 0) { $height = $Host.UI.RawUI.WindowSize.Height }
    } catch { }

    $banner = @(
        "=========================================",
        "            K A E L I X",
        "========================================="
    )

    $maxLen = ($banner | Measure-Object -Property Length -Maximum).Maximum
    $bannerHeight = $banner.Count + 2
    $topPad = [Math]::Max(0, [int](($height - $bannerHeight) / 2))
    $leftPad = " " * [Math]::Max(0, [int](($width - $maxLen) / 2))

    for ($i = 0; $i -lt $topPad; $i++) { Write-Host "" }
    foreach ($line in $banner) {
        Write-Host "${leftPad}${line}" -ForegroundColor Green
    }
    Write-Host ""
}

function Write-Step {
    param([int]$Num, [int]$Total, [string]$Message)
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "$Num/$Total" -NoNewline -ForegroundColor Yellow
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host $Message
}

function Write-OK {
    param([string]$Message)
    Write-Host "       " -NoNewline
    Write-Host "✓ $Message" -ForegroundColor Green
    Write-Log $Message "SUCCESS"
}

function Write-Fail {
    param([string]$Message)
    Write-Host "       " -NoNewline
    Write-Host "✗ $Message" -ForegroundColor Red
    Write-Log $Message "ERROR"
}

function Write-Warn {
    param([string]$Message)
    Write-Host "       " -NoNewline
    Write-Host "⚠ $Message" -ForegroundColor Yellow
    Write-Log $Message "WARN"
}

function Write-Installing {
    param([string]$Message)
    Write-Host "       " -NoNewline
    Write-Host "⟳ $Message" -ForegroundColor Cyan
    Write-Log $Message "INFO"
}

function Test-Command {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Pause-Exit {
    param([int]$Code = 1)
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host "Press Enter to continue" }
    }
    exit $Code
}

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

# --- Download with retry (from Ollama install.ps1) ----------------------------

function Invoke-Download {
    param(
        [string]$Url,
        [string]$OutFile,
        [int]$MaxRetries = 3
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Write-Log "Downloading: $Url (attempt $attempt/$MaxRetries)"

            $request = [System.Net.HttpWebRequest]::Create($Url)
            $request.AllowAutoRedirect = $true
            $request.Timeout = 300000

            $response = $request.GetResponse()
            $totalBytes = $response.ContentLength
            $stream = $response.GetResponseStream()
            $fileStream = [System.IO.FileStream]::new($OutFile, [System.IO.FileMode]::Create)
            $buffer = [byte[]]::new(65536)
            $totalRead = 0
            $lastUpdate = [DateTime]::MinValue
            $barWidth = 40

            try {
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $fileStream.Write($buffer, 0, $read)
                    $totalRead += $read

                    $now = [DateTime]::UtcNow
                    if (($now - $lastUpdate).TotalMilliseconds -ge 250) {
                        if ($totalBytes -gt 0) {
                            $pct = [math]::Min(100.0, ($totalRead / $totalBytes) * 100)
                            $filled = [math]::Floor($barWidth * $pct / 100)
                            $empty = $barWidth - $filled
                            $bar = ('▓' * $filled) + ('░' * $empty)
                            $pctFmt = $pct.ToString("0.0")
                            Write-Host -NoNewline "`r  $bar ${pctFmt}%"
                        } else {
                            $sizeMB = [math]::Round($totalRead / 1MB, 1)
                            Write-Host -NoNewline "`r  ${sizeMB} MB downloaded..."
                        }
                        $lastUpdate = $now
                    }
                }

                if ($totalBytes -gt 0) {
                    $bar = '▓' * $barWidth
                    Write-Host "`r  $bar 100.0%"
                }

                Write-Log "Download complete: $OutFile ($totalRead bytes)"
                return $true
            } finally {
                $fileStream.Close()
                $stream.Close()
                $response.Close()
            }
        } catch {
            Write-Log "Download failed: $($_.Exception.Message)" "ERROR"
            if ($attempt -eq $MaxRetries) {
                throw "Download failed after $MaxRetries attempts: $Url"
            }
            Start-Sleep -Seconds (1 * $attempt)
        }
    }
}

# --- Uninstall ----------------------------------------------------------------

function Invoke-Uninstall {
    Write-Host ""
    Write-Step 1 3 "Uninstalling Kaelix..."

    Write-Installing "Removing Python package..."
    pip uninstall kaelix -y -q 2>$null
    Write-OK "Python package removed."

    $targetDir = Join-Path (Get-Location) $REPO_NAME
    if (Test-Path $targetDir) {
        Write-Installing "Removing repository directory..."
        Remove-Item -Recurse -Force $targetDir -ErrorAction SilentlyContinue
        Write-OK "Repository removed."
    }

    if (Test-Path $script:LogDir) {
        Write-Installing "Removing log directory..."
        Remove-Item -Recurse -Force $script:LogDir -ErrorAction SilentlyContinue
        Write-OK "Logs removed."
    }

    Write-Host ""
    Write-OK "Kaelix uninstalled."
}

# --- Main installation ---------------------------------------------------------

function Invoke-Install {
    Show-Banner

    if ($env:OS -ne "Windows_NT") {
        Write-Fail "This script requires Windows."
        Pause-Exit
    }

    $env:GIT_TERMINAL_PROMPT = "0"

    # --- Dependency checks -----------------------------------------------------

    $deps = @(
        @{ Name = "winget"; Id = "winget"; Install = $false; Message = "App Installer from Microsoft Store"; Required = $true },
        @{ Name = "git";    Id = "Git.Git"; Install = $true; Message = "Git"; Required = $true },
        @{ Name = "python"; Id = "Python.Python.3.12"; Install = $true; Message = "Python 3.12+"; Required = $true },
        @{ Name = "mkvmerge"; Id = "MoritzBunkus.MKVToolNix"; Install = $true; Message = "MKVToolNix"; Required = $true },
        @{ Name = "ffmpeg"; Id = "Gyan.FFmpeg"; Install = $true; Message = "ffmpeg"; Required = $true }
    )

    $step = 0
    $total = $deps.Count + 2

    foreach ($dep in $deps) {
        $step++
        Write-Step $step $total "Checking for $($dep.Message)..."

        if (Test-Command $dep.Name) {
            Write-OK "$($dep.Name) found."
        } elseif ($dep.Install -and -not $NonInteractive) {
            Write-Installing "Installing $($dep.Message)..."
            winget install --id $dep.Id -e --source winget --accept-package-agreements --accept-source-agreements 2>$null
            Refresh-Path
            if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335212) {
                Write-OK "$($dep.Message) installed."
            } else {
                Write-Fail "Failed to install $($dep.Message). Install manually and try again."
                Pause-Exit
            }
        } else {
            Write-Fail "$($dep.Message) is not installed."
            Write-Host "       Install it from the Microsoft Store and try again." -ForegroundColor DarkGray
            Pause-Exit
        }
    }

    # --- Repository ------------------------------------------------------------

    $step++
    Write-Step $step $total "Setting up repository..."
    $targetDir = Join-Path (Get-Location) $REPO_NAME

    if (Test-Path (Join-Path $targetDir ".git")) {
        Write-Installing "Repository found. Checking for updates..." -ForegroundColor Gray
        Push-Location $targetDir

        $gitFetchHead = Join-Path ".git" "FETCH_HEAD"
        if (Test-Path $gitFetchHead) {
            try {
                $acl = Get-Acl $gitFetchHead
                $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                $hasAccess = $acl.Access | Where-Object { $_.IdentityReference -eq $currentUser -and $_.FileSystemRights -match "Read" }
                if (-not $hasAccess) {
                    Write-Installing "Fixing .git permissions..."
                    icacls ".git" /grant "${currentUser}:(OI)(CI)F" /T /Q 2>$null
                }
            } catch { }
        }

        git fetch origin --quiet 2>$null
        $remoteUrl = git remote get-url origin 2>$null
        if ($remoteUrl -and $remoteUrl.Trim() -eq $REPO_URL) {
            $localHash = git rev-parse HEAD 2>$null
            $remoteHash = git rev-parse origin/main 2>$null
            if (-not $remoteHash) { $remoteHash = git rev-parse origin/master 2>$null }
            if (-not $remoteHash) { $remoteHash = $localHash }
            if ($localHash -eq $remoteHash) {
                Write-OK "Already up to date."
            } else {
                Write-Installing "Updates available. Pulling..."
                git pull --quiet 2>$null
                Write-OK "Updated to latest version."
            }
        } else {
            Write-Warn "Wrong remote. Cloning fresh..."
            Pop-Location
            Remove-Item -Recurse -Force $targetDir -ErrorAction SilentlyContinue
            git clone $REPO_URL
            Push-Location $REPO_NAME
        }
        Pop-Location
    } else {
        Write-Installing "Cloning repository..."
        git clone $REPO_URL 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to clone repository."
            Pause-Exit
        }
        Write-OK "Repository cloned."
    }

    # --- Python dependencies ---------------------------------------------------

    $step++
    Write-Step $step $total "Installing Python dependencies..."
    Push-Location $targetDir
    pip install --user -r requirements.txt -q 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to install Python dependencies."
        Pop-Location
        Pause-Exit
    }
    Pop-Location
    Write-OK "Dependencies installed."

    # --- Register kaelix command -----------------------------------------------

    $step++
    Write-Step $step $total "Registering kaelix command..."
    Push-Location $targetDir
    pip install --user -e . -q 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to register kaelix command."
        Pop-Location
        Pause-Exit
    }
    Pop-Location
    Write-OK "Kaelix installed."

    # --- Done ------------------------------------------------------------------

    Write-Host ""
    Write-OK "Installation complete."
    Write-Host "  Type " -NoNewline -ForegroundColor Gray
    Write-Host '"kaelix"' -NoNewline -ForegroundColor Green
    Write-Host " to start." -ForegroundColor Gray
    Write-Host ""
}

# --- Entry point ---------------------------------------------------------------

if ($Uninstall) {
    Invoke-Uninstall
} else {
    Invoke-Install
}

if (-not $Quiet) {
    Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        Read-Host "Press Enter to continue"
    }
}
exit

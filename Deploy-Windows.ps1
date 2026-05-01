param(
  [switch]$SkipNodeInstall
)

$ErrorActionPreference = "Stop"

$NpmExe = "npm.cmd"
$VercelExe = "vercel.cmd"

try {
  [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {}

function Write-Banner {
  Clear-Host
  Write-Host "==============================================" -ForegroundColor Cyan
  Write-Host "         XHTTPRelayECO Windows Installer      " -ForegroundColor Cyan
  Write-Host "==============================================" -ForegroundColor Cyan
  Write-Host ""
}

function Write-Step([string]$Text) {
  Write-Host ""
  Write-Host ">> $Text" -ForegroundColor Yellow
}

function Read-Default([string]$Prompt, [string]$DefaultValue) {
  $raw = Read-Host "$Prompt [$DefaultValue]"
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  return $raw.Trim()
}

function Read-Optional([string]$Prompt) {
  $raw = Read-Host $Prompt
  if ([string]::IsNullOrWhiteSpace($raw)) { return "" }
  return $raw.Trim()
}

function Read-Required([string]$Prompt) {
  while ($true) {
    $raw = Read-Host $Prompt
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw.Trim() }
    Write-Host "Value is required." -ForegroundColor Red
  }
}

function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machine;$user"
}

function Invoke-NativeSafe {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.WorkingDirectory = (Get-Location).Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  # PowerShell 5.1-compatible argument handling
  $escaped = $Arguments | ForEach-Object {
    if ($_ -match '[\s"]') {
      '"' + ($_ -replace '"', '\"') + '"'
    } else {
      $_
    }
  }
  $psi.Arguments = ($escaped -join ' ')

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  $lines = @()
  if (-not [string]::IsNullOrWhiteSpace($stdout)) {
    $lines += ($stdout -split "`r?`n" | Where-Object { $_ -ne "" })
  }
  if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    $lines += ($stderr -split "`r?`n" | Where-Object { $_ -ne "" })
  }

  return @{
    Output = @($lines)
    ExitCode = $proc.ExitCode
  }
}

function New-RandomProjectName {
  $chars = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
  $suffix = -join (1..8 | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
  return "relay-$suffix"
}

function Ensure-NodeAndNpm {
  if (Get-Command $NpmExe -ErrorAction SilentlyContinue) {
    Write-Host "npm already installed." -ForegroundColor Green
    return
  }

  if ($SkipNodeInstall) {
    throw "npm is missing and -SkipNodeInstall was used."
  }

  if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
    throw "winget not found. Install Node.js LTS manually and run again."
  }

  Write-Step "Installing Node.js LTS (npm included) via winget..."
  winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
  Refresh-Path

  if (-not (Get-Command $NpmExe -ErrorAction SilentlyContinue)) {
    throw "Node.js installation finished but npm is still not detected. Re-open PowerShell and retry."
  }
}

function Ensure-VercelCli {
  if (Get-Command $VercelExe -ErrorAction SilentlyContinue) {
    Write-Host "Vercel CLI already installed." -ForegroundColor Green
    return
  }

  Write-Step "Installing Vercel CLI..."
  & $NpmExe i -g vercel | Out-Host
  Refresh-Path
  if (-not (Get-Command $VercelExe -ErrorAction SilentlyContinue)) {
    throw "vercel command not found after installation."
  }
}

function Ensure-VercelLogin {
  Write-Step "Checking Vercel login..."
  $loggedIn = $true
  try {
    & $VercelExe whoami *> $null
  } catch {
    $loggedIn = $false
  }

  if (-not $loggedIn) {
    Write-Host "Browser login will open now. Complete login then return here." -ForegroundColor Yellow
    & $VercelExe login | Out-Host
  }

  & $VercelExe whoami | Out-Host
}

function Ensure-VercelProject([string]$ProjectName, [string]$Scope) {
  Write-Step "Creating project (or reusing if already exists)..."
  $args = @("project", "add", $ProjectName)
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }

  $result = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
  $output = $result.Output
  $text = $output | Out-String
  if ($result.ExitCode -ne 0 -and ($text -notmatch "already exists")) {
    throw "vercel project add failed: $text"
  }
  $output | Out-Host
}

function Link-VercelProject([string]$ProjectName, [string]$Scope) {
  Write-Step "Linking local folder to Vercel project..."
  $args = @("link", "--yes", "--project", $ProjectName)
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  & $VercelExe @args | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "vercel link failed."
  }
}

function Set-VercelEnv([string]$Name, [string]$Value, [string]$Target, [string]$Scope) {
  $args = @("env", "add", $Name, $Target, "--value", $Value, "--force", "--yes", "--no-sensitive")
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  & $VercelExe @args | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set env var $Name for $Target."
  }
}

function Deploy-Production([string]$Scope) {
  Write-Step "Deploying to production..."
  $args = @("deploy", "--prod", "--yes")
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }

  $result = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
  $lines = $result.Output
  $lines | Out-Host
  if ($result.ExitCode -ne 0) {
    throw "vercel deploy failed."
  }

  $alias = ""
  $prod = ""
  foreach ($line in $lines) {
    if ($line -match "Aliased:\s*(https://\S+)") { $alias = $Matches[1] }
    if ($line -match "Production:\s*(https://\S+)") { $prod = $Matches[1] }
  }

  return @{
    Alias = $alias
    Production = $prod
  }
}

function Get-LinkedProjectInfo([string]$ProjectRoot) {
  $projectFile = Join-Path $ProjectRoot ".vercel\project.json"
  if (-not (Test-Path $projectFile)) {
    return @{
      IsLinked = $false
      ProjectName = ""
      ProjectId = ""
      Scope = ""
    }
  }

  try {
    $obj = Get-Content $projectFile -Raw | ConvertFrom-Json
  } catch {
    return @{
      IsLinked = $false
      ProjectName = ""
      ProjectId = ""
      Scope = ""
    }
  }

  $name = ""
  if ($obj.PSObject.Properties.Name -contains "projectName" -and $obj.projectName) { $name = [string]$obj.projectName }
  $projectId = ""
  if ($obj.PSObject.Properties.Name -contains "projectId" -and $obj.projectId) { $projectId = [string]$obj.projectId }
  $scope = ""
  if ($obj.PSObject.Properties.Name -contains "orgId" -and $obj.orgId) { $scope = [string]$obj.orgId }

  return @{
    IsLinked = $true
    ProjectName = $name
    ProjectId = $projectId
    Scope = $scope
  }
}

function Show-DeploySummary($deployInfo) {
  Write-Host ""
  Write-Host "==============================================" -ForegroundColor Green
  Write-Host "Deployment complete." -ForegroundColor Green
  if ($deployInfo.Production) { Write-Host "Production: $($deployInfo.Production)" -ForegroundColor Green }
  if ($deployInfo.Alias) { Write-Host "Aliased:    $($deployInfo.Alias)" -ForegroundColor Green }
  Write-Host "==============================================" -ForegroundColor Green
  Write-Host ""
}

function Collect-NewDeploymentConfig {
  Write-Step "Collecting config values..."
  $projectNameInput = Read-Optional "Project name on Vercel (leave empty for random)"
  $projectName = if ([string]::IsNullOrWhiteSpace($projectNameInput)) { New-RandomProjectName } else { $projectNameInput }
  $scope = Read-Host "Scope slug/team (optional, press Enter to skip)"
  $scope = $scope.Trim()
  $targetDomain = Read-Required "TARGET_DOMAIN (example: https://your-upstream-domain:443)"
  $relayPath = Read-Default "RELAY_PATH (MUST be EXACT inbound path on your foreign server, e.g. /api or /freedom)" "/api"
  $maxInflight = Read-Default "MAX_INFLIGHT" "192"
  $maxUpBps = Read-Default "MAX_UP_BPS" "5242880"
  $maxDownBps = Read-Default "MAX_DOWN_BPS" "5242880"

  if (-not $relayPath.StartsWith("/")) { $relayPath = "/$relayPath" }

  Write-Step "Environment values selected:"
  Write-Host "TARGET_DOMAIN = $targetDomain"
  Write-Host "PROJECT_NAME  = $projectName"
  Write-Host "RELAY_PATH    = $relayPath"
  Write-Host "MAX_INFLIGHT  = $maxInflight"
  Write-Host "MAX_UP_BPS    = $maxUpBps"
  Write-Host "MAX_DOWN_BPS  = $maxDownBps"

  return @{
    ProjectName = $projectName
    Scope = $scope
    TargetDomain = $targetDomain
    RelayPath = $relayPath
    MaxInflight = $maxInflight
    MaxUpBps = $maxUpBps
    MaxDownBps = $maxDownBps
  }
}

function Apply-ProductionEnv($cfg) {
  Write-Step "Setting environment variables for production..."
  Set-VercelEnv -Name "TARGET_DOMAIN" -Value $cfg.TargetDomain -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "RELAY_PATH" -Value $cfg.RelayPath -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "MAX_INFLIGHT" -Value $cfg.MaxInflight -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "MAX_UP_BPS" -Value $cfg.MaxUpBps -Target "production" -Scope $cfg.Scope
  Set-VercelEnv -Name "MAX_DOWN_BPS" -Value $cfg.MaxDownBps -Target "production" -Scope $cfg.Scope
}

function Run-NewDeploymentFlow {
  $cfg = Collect-NewDeploymentConfig
  Ensure-VercelProject -ProjectName $cfg.ProjectName -Scope $cfg.Scope
  Link-VercelProject -ProjectName $cfg.ProjectName -Scope $cfg.Scope
  Apply-ProductionEnv -cfg $cfg
  $deployInfo = Deploy-Production -Scope $cfg.Scope
  Show-DeploySummary $deployInfo
  Write-Host "Done."
}

function Run-UpdateEnvFlow([string]$Scope) {
  Write-Step "Update production env vars (all fields are required)..."
  $targetDomain = Read-Required "TARGET_DOMAIN"
  $relayPath = Read-Required "RELAY_PATH (inbound path on foreign server)"
  $maxInflight = Read-Required "MAX_INFLIGHT"
  $maxUpBps = Read-Required "MAX_UP_BPS"
  $maxDownBps = Read-Required "MAX_DOWN_BPS"

  if (-not $relayPath.StartsWith("/")) { $relayPath = "/$relayPath" }

  Set-VercelEnv -Name "TARGET_DOMAIN" -Value $targetDomain -Target "production" -Scope $Scope
  Set-VercelEnv -Name "RELAY_PATH" -Value $relayPath -Target "production" -Scope $Scope
  Set-VercelEnv -Name "MAX_INFLIGHT" -Value $maxInflight -Target "production" -Scope $Scope
  Set-VercelEnv -Name "MAX_UP_BPS" -Value $maxUpBps -Target "production" -Scope $Scope
  Set-VercelEnv -Name "MAX_DOWN_BPS" -Value $maxDownBps -Target "production" -Scope $Scope

  $redeployNow = Read-Default "Redeploy now? (Y/n)" "y"
  if ($redeployNow.ToLowerInvariant() -eq "y") {
    $deployInfo = Deploy-Production -Scope $Scope
    Show-DeploySummary $deployInfo
  }
}

function Show-DeploymentList([string]$ProjectName, [string]$Scope) {
  Write-Step "Recent deployments..."
  $args = @("list")
  if (-not [string]::IsNullOrWhiteSpace($ProjectName)) { $args += @($ProjectName) }
  if (-not [string]::IsNullOrWhiteSpace($Scope)) { $args += @("--scope", $Scope) }
  $result = Invoke-NativeSafe -FilePath $VercelExe -Arguments $args
  $result.Output | Out-Host
  if ($result.ExitCode -ne 0) {
    Write-Host "Could not list deployments with scoped project. Trying generic list..." -ForegroundColor DarkYellow
    $fallback = Invoke-NativeSafe -FilePath $VercelExe -Arguments @("list")
    $fallback.Output | Out-Host
  }
}

function Show-ManageMenu($linkInfo) {
  Write-Host ""
  Write-Host "Detected linked project:" -ForegroundColor Cyan
  if ($linkInfo.ProjectName) { Write-Host "Project: $($linkInfo.ProjectName)" }
  if ($linkInfo.Scope) { Write-Host "Scope:   $($linkInfo.Scope)" }
  Write-Host ""
  Write-Host "[1] Redeploy current linked project"
  Write-Host "[2] Update production env vars"
  Write-Host "[3] List recent deployments"
  Write-Host "[4] Deploy as NEW project"
  Write-Host "[5] Exit"
  return (Read-Default "Choose action" "1")
}

function Run-ManagementLoop {
  while ($true) {
    $currentLink = Get-LinkedProjectInfo -ProjectRoot $scriptDir
    if (-not $currentLink.IsLinked) {
      Write-Host "No linked project found. Running first-time deployment flow..." -ForegroundColor Yellow
      Run-NewDeploymentFlow
      Read-Host "Press Enter to return to main menu (or Ctrl+C to exit)"
      continue
    }

    $choice = Show-ManageMenu -linkInfo $currentLink
    if ($choice -eq "5") {
      Write-Host "Exit."
      break
    }

    try {
      switch ($choice) {
        "1" {
          $deployInfo = Deploy-Production -Scope $currentLink.Scope
          Show-DeploySummary $deployInfo
          Write-Host "Done."
        }
        "2" {
          Run-UpdateEnvFlow -Scope $currentLink.Scope
          Write-Host "Done."
        }
        "3" {
          Show-DeploymentList -ProjectName $currentLink.ProjectName -Scope $currentLink.Scope
          Write-Host "Done."
        }
        "4" {
          Run-NewDeploymentFlow
        }
        default {
          Write-Host "Invalid option." -ForegroundColor Red
        }
      }
    } catch {
      Write-Host ""
      Write-Host "Action failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    Read-Host "Press Enter to return to main menu (or Ctrl+C to exit)"
  }
}

Write-Banner
Write-Host "Important: connect your VPN in TUN Mode before continuing." -ForegroundColor Magenta
Read-Host "Press Enter to continue"
Write-Host "Tip: Press Ctrl+C at any step to stop/exit." -ForegroundColor DarkYellow

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

if (-not (Test-Path (Join-Path $scriptDir "api\index.js"))) {
  throw "api/index.js not found. Run this script from project root."
}
if (-not (Test-Path (Join-Path $scriptDir "vercel.json"))) {
  throw "vercel.json not found. Run this script from project root."
}

Ensure-NodeAndNpm
Ensure-VercelCli
Ensure-VercelLogin
Write-Host "Deploy path: $scriptDir" -ForegroundColor DarkGray

Run-ManagementLoop

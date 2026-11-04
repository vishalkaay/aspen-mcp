# Aspen Plus MCP server - entry point.
# Run by the MCP client as:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File server.ps1
# Windows PowerShell 5.1, no dependencies beyond Aspen Plus itself. Keep all files ASCII.
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = $PSScriptRoot

# MCP hosts (Claude Desktop, Claude Code) start servers with a trimmed environment. Aspen Plus then
# cannot find its license server (LSHOST) and InitNew2 fails with "Unexpected Error". Restore every
# variable the user and system environment define but this process lacks (PATH-like ones are merged).
$restoredEnv = @()
foreach ($src in @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'HKCU:\Environment')) {
    $key = Get-Item $src -ErrorAction SilentlyContinue
    if (-not $key) { continue }
    foreach ($name in $key.GetValueNames()) {
        if (-not $name) { continue }
        $val = [Environment]::ExpandEnvironmentVariables([string]$key.GetValue($name, '', 'DoNotExpandEnvironmentNames'))
        $cur = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($name -ieq 'Path' -or $name -ieq 'PSModulePath') {
            $have = @("$cur" -split ';' | Where-Object { $_ })
            $add = @($val -split ';' | Where-Object { $_ -and ($have -notcontains $_) })
            if ($add.Count) { [Environment]::SetEnvironmentVariable($name, (($have + $add) -join ';'), 'Process'); $restoredEnv += $name }
        } elseif ($null -eq $cur) {
            [Environment]::SetEnvironmentVariable($name, $val, 'Process'); $restoredEnv += $name
        }
    }
}

# ---- configuration ----
$config = [ordered]@{
    progid             = 'auto'                 # newest installed Aspen Plus, or e.g. Apwn.Document.40.0 (V14)
    workspace          = 'workspace'            # working copies, reports, screenshots (relative to this folder)
    protected_paths    = @()                    # folders that are never written to; files there open as copies
    default_unit_set   = 'METCBAR'
    run_wait_seconds   = 40
    quit_aspen_on_exit = $false
    confirm_dialogs    = @('Copy Units From')   # Aspen dialogs answered with OK; any other dialog is closed
}
if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config.json' }
if (Test-Path $ConfigPath) {
    $user = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($p in $user.PSObject.Properties) { if ($p.Name -notlike '_*') { $config[$p.Name] = $p.Value } }
}
$config.protected_paths = @($config.protected_paths)

$ws = [Environment]::ExpandEnvironmentVariables([string]$config.workspace)
if (-not [IO.Path]::IsPathRooted($ws)) { $ws = Join-Path $root $ws }
$ws = [IO.Path]::GetFullPath($ws)
$logDir = Join-Path $root 'logs'
foreach ($d in $ws, $logDir) { if (-not (Test-Path $d)) { [void](New-Item -ItemType Directory -Path $d) } }

$enc = New-Object System.Text.UTF8Encoding($false)
$stdout = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $enc)
$stdout.AutoFlush = $true
$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $enc)

$global:S = @{
    Version   = '1.3.0'
    Root      = $root
    Config    = $config
    Workspace = $ws
    LogFile   = Join-Path $logDir 'server.log'
    Out       = $stdout
    Tools     = New-Object System.Collections.ArrayList
    Handlers  = @{}
    App       = $null      # Apwn.Document
    ProgId    = $null      # COM class actually started
    Source    = $null      # file the user asked to open
    Working   = $null      # file Aspen actually has open / saves to
    RunStart  = $null
}

foreach ($f in 'lib\Com.ps1', 'lib\Protocol.ps1', 'lib\Dialogs.ps1', 'lib\Detect.ps1', 'lib\Session.ps1',
    'tools\Session.ps1', 'tools\Tree.ps1', 'tools\Flowsheet.ps1', 'tools\Models.ps1', 'tools\Analysis.ps1',
    'tools\Run.ps1', 'tools\Results.ps1', 'tools\View.ps1', 'tools\Files.ps1') {
    . (Join-Path $root $f)
}

Write-McpLog "server $($global:S.Version) started (pid $PID, $($global:S.Tools.Count) tools, workspace $ws)"
if ($restoredEnv.Count) { Write-McpLog "restored environment variables missing from the host: $($restoredEnv -join ', ')" }

try {
    while ($null -ne ($line = $stdin.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $msg = $null
        try { $msg = $line | ConvertFrom-Json } catch { Send-McpError $null -32700 'Parse error'; continue }
        try { $null = Invoke-McpRequest $msg }
        catch {
            $err = Get-ErrorText $_
            Write-McpLog "request failed: $err"
            if ($msg.PSObject.Properties.Name -contains 'id') { Send-McpError $msg.id -32603 $err }
        }
    }
} finally {
    Write-McpLog 'stdin closed, shutting down'
    if ($global:S.Config.quit_aspen_on_exit) { Close-AspInstance }
}

# Minimal MCP stdio client used by the tests: starts server.ps1 as a child process, like Claude Desktop does.

$script:Passed = 0
$script:Failed = 0

function Start-McpServer([string]$serverPath) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $script:McpProc = $p
    $script:McpNextId = 1
    $p
}

function Stop-McpServer {
    if ($script:McpProc -and -not $script:McpProc.HasExited) {
        $script:McpProc.StandardInput.Close()
        if (-not $script:McpProc.WaitForExit(10000)) { $script:McpProc.Kill() }
    }
}

function Send-McpRaw([string]$json) { $script:McpProc.StandardInput.WriteLine($json); $script:McpProc.StandardInput.Flush() }

function Invoke-Mcp([string]$method, $params = $null, [int]$timeoutSec = 120) {
    $id = $script:McpNextId++
    $req = [ordered]@{ jsonrpc = '2.0'; id = $id; method = $method }
    if ($null -ne $params) { $req.params = $params }
    Send-McpRaw (ConvertTo-Json -InputObject $req -Depth 20 -Compress)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $task = $script:McpProc.StandardOutput.ReadLineAsync()
        if (-not $task.Wait([int][math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds))) { break }
        $line = $task.Result
        if ($null -eq $line) { throw "Server exited. stderr: $($script:McpProc.StandardError.ReadToEnd())" }
        $msg = $line | ConvertFrom-Json
        if ($msg.id -eq $id) { return $msg }
    }
    throw "Timeout waiting for response to $method"
}

# Call a tool; returns @{ isError; text; json; raw }
function Invoke-Tool([string]$name, $arguments = @{}, [int]$timeoutSec = 180) {
    $resp = Invoke-Mcp 'tools/call' @{ name = $name; arguments = $arguments } $timeoutSec
    if ($resp.error) { return @{ isError = $true; text = $resp.error.message; json = $null; raw = $resp } }
    $texts = @($resp.result.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
    $text = $texts -join "`n"
    $json = $null; try { $json = $texts[0] | ConvertFrom-Json } catch {}
    @{ isError = [bool]$resp.result.isError; text = $text; json = $json; raw = $resp }
}

function Assert-True([bool]$cond, [string]$what, $detail = $null) {
    if ($cond) { $script:Passed++; Write-Host "  PASS  $what" -ForegroundColor Green }
    else {
        $script:Failed++; Write-Host "  FAIL  $what" -ForegroundColor Red
        if ($null -ne $detail) { $d = "$detail"; if ($d.Length -gt 600) { $d = $d.Substring(0, 600) + '...' }; Write-Host "        $d" -ForegroundColor DarkGray }
    }
}

function Write-Summary {
    $c = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
    Write-Host "`n$script:Passed passed, $script:Failed failed" -ForegroundColor $c
}

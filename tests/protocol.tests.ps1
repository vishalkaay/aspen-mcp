# Protocol and file-tool tests. Does not start Aspen.
#   powershell -ExecutionPolicy Bypass -File tests\protocol.tests.ps1 [-SampleBkp <any .bkp file>]
# -SampleBkp (or $env:ASPEN_MCP_SAMPLE_BKP) enables the .bkp reading tests; the file is only read.
param([string]$SampleBkp = $env:ASPEN_MCP_SAMPLE_BKP)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'McpClient.ps1')

[void](Start-McpServer (Join-Path $root 'server.ps1'))
try {
    Write-Host 'protocol'
    $init = Invoke-Mcp 'initialize' @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'test'; version = '0' } }
    Assert-True ($init.result.protocolVersion -eq '2025-06-18') 'initialize negotiates the requested protocol version' ($init | ConvertTo-Json -Depth 5)
    Assert-True ($init.result.serverInfo.name -eq 'aspen-plus') 'serverInfo.name'
    Assert-True ([string]$init.result.instructions -match 'variable tree') 'instructions present'
    $old = Invoke-Mcp 'initialize' @{ protocolVersion = '1999-01-01' }
    Assert-True ($old.result.protocolVersion -eq '2025-11-25') "unknown protocol version falls back to latest ($($old.result.protocolVersion))"
    $new = Invoke-Mcp 'initialize' @{ protocolVersion = '2025-11-25' }
    Assert-True ($new.result.protocolVersion -eq '2025-11-25') 'the 2025-11-25 protocol used by current Claude clients is accepted'

    Send-McpRaw '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    $ping = Invoke-Mcp 'ping'
    Assert-True ($null -ne $ping.result) 'notification gets no reply; next request answered in order'

    $list = Invoke-Mcp 'tools/list'
    $tools = @($list.result.tools)
    Assert-True ($tools.Count -ge 30) "tools/list returns $($tools.Count) tools"
    $bad = @($tools | Where-Object { -not $_.name -or -not $_.description -or $_.inputSchema.type -ne 'object' -or $null -eq $_.inputSchema.properties })
    Assert-True ($bad.Count -eq 0) 'every tool has name, description and an object schema' ($bad | ConvertTo-Json -Depth 4)
    $req = @($tools | Where-Object { $_.inputSchema.PSObject.Properties.Name -contains 'required' })
    $notArr = @($req | Where-Object { $_.inputSchema.required -isnot [array] })
    Assert-True ($notArr.Count -eq 0) 'required is always a JSON array' ($notArr | ForEach-Object { $_.name })
    $dupes = @($tools | Group-Object name | Where-Object Count -gt 1)
    Assert-True ($dupes.Count -eq 0) 'tool names are unique'

    $um = Invoke-Mcp 'no/such/method'
    Assert-True ($um.error.code -eq -32601) 'unknown method -> -32601'
    $ut = Invoke-Mcp 'tools/call' @{ name = 'nope'; arguments = @{} }
    Assert-True ($ut.error.code -eq -32602) 'unknown tool -> -32602'

    Write-Host 'no-session behaviour'
    $info = Invoke-Tool 'aspen_info'
    Assert-True (-not $info.isError -and $info.json.open -eq $false) 'aspen_info reports open=false' $info.text
    $g = Invoke-Tool 'aspen_get' @{ path = '\Data' }
    Assert-True ($g.isError -and $g.text -match 'No Aspen simulation is open') 'tree tools explain that nothing is open' $g.text
    $sv = Invoke-Tool 'aspen_save'
    Assert-True $sv.isError 'aspen_save without a simulation is an error' $sv.text

    Write-Host 'file tools (read-only)'
    $fake = Join-Path $env:TEMP 'aspen_mcp_test.apw'
    [IO.File]::WriteAllBytes($fake, [byte[]](0, 1, 2, 3))
    $bin = Invoke-Tool 'aspen_read_file' @{ path = $fake }
    Assert-True ($bin.isError -and $bin.text -match 'binary') 'binary .apw is refused by aspen_read_file' $bin.text
    Remove-Item $fake -Force
    if ($SampleBkp -and (Test-Path $SampleBkp)) {
        $proj = Split-Path $SampleBkp -Parent
        $base = [IO.Path]::GetFileNameWithoutExtension($SampleBkp)
        $lf = Invoke-Tool 'aspen_list_files' @{ dir = $proj; recurse = $false; filter = $base }
        Assert-True (-not $lf.isError -and @($lf.json).Count -gt 0) "aspen_list_files finds $(@($lf.json).Count) $base files" $lf.text
        $bk = Invoke-Tool 'aspen_read_file' @{ path = $SampleBkp; head = 5 }
        Assert-True (-not $bk.isError -and $bk.text -match 'VERSION') '.bkp text is readable' $bk.text
        $sr = Invoke-Tool 'aspen_read_file' @{ path = $SampleBkp; pattern = 'VERSION'; context = 0 }
        Assert-True (-not $sr.isError -and $sr.text -match '\[line \d+\]') 'pattern search reports line numbers' $sr.text
    } else { Write-Host '  (no -SampleBkp / ASPEN_MCP_SAMPLE_BKP; .bkp reading tests skipped)' }
    $nf = Invoke-Tool 'aspen_read_file' @{ path = 'C:\definitely\not\here.bkp' }
    Assert-True ($nf.isError -and $nf.text -match 'not found') 'missing file is a clear error'
} finally {
    Stop-McpServer
}
Write-Summary
if ($script:Failed -gt 0) { exit 1 }

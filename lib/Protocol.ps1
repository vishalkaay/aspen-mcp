# MCP over stdio: newline-delimited JSON-RPC 2.0. stdout carries protocol messages ONLY,
# so nothing in this server may use Write-Host / Write-Output to the console; diagnostics go to the log file.

$script:SupportedProtocols = @('2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05')

function Write-McpLog([string]$msg) {
    try {
        $f = $global:S.LogFile
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 5MB) { Move-Item $f "$f.old" -Force }
        [IO.File]::AppendAllText($f, ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "  $msg`r`n"))
    } catch {}
}

function Send-McpMessage($obj) {
    $global:S.Out.WriteLine((ConvertTo-Json -InputObject $obj -Depth 30 -Compress))
}
function Send-McpResult($id, $result) { Send-McpMessage ([ordered]@{ jsonrpc = '2.0'; id = $id; result = $result }) }
function Send-McpError($id, [int]$code, [string]$message) {
    Send-McpMessage ([ordered]@{ jsonrpc = '2.0'; id = $id; error = [ordered]@{ code = $code; message = $message } })
}

# ---- tool results ----
function New-TextResult([string]$text) { @{ content = @(, [ordered]@{ type = 'text'; text = $text }) } }
function New-JsonResult($obj) { New-TextResult (ConvertTo-Json -InputObject $obj -Depth 12 -Compress) }
function New-ErrorResult([string]$text) { $r = New-TextResult "Error: $text"; $r.isError = $true; $r }

# ---- tool registry ----
function Register-McpTool {
    param([string]$Name, [string]$Description, [hashtable]$Properties = @{}, [string[]]$Required = @(), [scriptblock]$Handler)
    $schema = [ordered]@{ type = 'object'; properties = $Properties }
    if ($Required.Count -gt 0) { $schema.required = [object[]]$Required }
    $tool = [ordered]@{ name = $Name; description = $Description; inputSchema = $schema }
    [void]$global:S.Tools.Add($tool)
    $global:S.Handlers[$Name] = $Handler
}

# Schema shorthands
function P-Str([string]$d) { [ordered]@{ type = 'string'; description = $d } }
function P-Num([string]$d) { [ordered]@{ type = 'number'; description = $d } }
function P-Int([string]$d) { [ordered]@{ type = 'integer'; description = $d } }
function P-Bool([string]$d) { [ordered]@{ type = 'boolean'; description = $d } }
function P-Enum([string]$d, [string[]]$values) { [ordered]@{ type = 'string'; enum = [object[]]$values; description = $d } }
function P-StrList([string]$d) { [ordered]@{ type = 'array'; items = @{ type = 'string' }; description = $d } }
function P-Map([string]$d) { [ordered]@{ type = 'object'; additionalProperties = $true; description = $d } }
function P-Any([string]$d) { [ordered]@{ description = $d } }

# PSCustomObject (from JSON) -> ordered dictionary of its properties
function ConvertTo-Map($o) {
    $m = [ordered]@{}
    if ($null -eq $o) { return $m }
    if ($o -is [System.Collections.IDictionary]) { foreach ($k in $o.Keys) { $m[$k] = $o[$k] }; return $m }
    foreach ($p in $o.PSObject.Properties) { $m[$p.Name] = $p.Value }
    return $m
}

$script:Instructions = @'
Drives a live, visible Aspen Plus window over COM (the newest installed version, V11 or later).
- Start with aspen_new (blank, choose a unit set) or aspen_open (.bkp/.apw/.apwz). Files are opened as working copies in the server workspace by default; protected folders are never written to.
- Everything is a node in the variable tree, e.g. \Data\Streams\FEED\Input\TEMP\MIXED, \Data\Blocks\B1\Input\PRES, \Data\Blocks\B1\Output\QCALC. Explore with aspen_list / aspen_tree / aspen_find, then aspen_get / aspen_set. Values are in the simulation's unit set; aspen_get returns the units.
- Build: aspen_add_components, aspen_set_property_method, aspen_add_block, aspen_add_stream, aspen_connect, aspen_set_stream. Columns: aspen_radfrac; stoichiometric reactors: aspen_rstoic; kinetics: aspen_reactions + aspen_kinetic_reactor (RCSTR/RPlug). Any other model: aspen_describe_inputs on the block (Aspen's help text and allowed values per field), then aspen_set.
- Analysis: aspen_design_spec, aspen_sensitivity and aspen_calculator create them; after a run, aspen_analysis_results reads them.
- aspen_run starts the solver and waits briefly; if it reports running=true, poll aspen_status. Then read aspen_streams, aspen_block_results, aspen_column_results, aspen_analysis_results, or aspen_report.
- aspen_screenshot returns an image of the Aspen window. aspen_flowsheet returns the topology as text.
- Save with aspen_save (defaults to the working copy).
'@

function Invoke-McpRequest($msg) {
    $id = $msg.id
    $hasId = $msg.PSObject.Properties.Name -contains 'id'
    switch ($msg.method) {
        'initialize' {
            $req = $null; try { $req = [string]$msg.params.protocolVersion } catch {}
            $ver = if ($script:SupportedProtocols -contains $req) { $req } else { $script:SupportedProtocols[0] }
            Write-McpLog "initialize (client protocol $req -> $ver)"
            Send-McpResult $id ([ordered]@{
                protocolVersion = $ver
                capabilities    = [ordered]@{ tools = [ordered]@{ listChanged = $false } }
                serverInfo      = [ordered]@{ name = 'aspen-plus'; version = $global:S.Version }
                instructions    = $script:Instructions
            })
        }
        'ping' { Send-McpResult $id @{} }
        'tools/list' { Send-McpResult $id @{ tools = [object[]]$global:S.Tools.ToArray() } }
        'resources/list' { Send-McpResult $id @{ resources = @() } }
        'prompts/list' { Send-McpResult $id @{ prompts = @() } }
        'tools/call' {
            $name = [string]$msg.params.name
            $h = $global:S.Handlers[$name]
            if (-not $h) { Send-McpError $id -32602 "Unknown tool: $name"; return }
            $a = $msg.params.arguments
            if ($null -eq $a) { $a = [pscustomobject]@{} }
            $t0 = Get-Date
            try {
                $r = & $h $a
                # A handler's stray pipeline output would turn the result into an array; keep the real result.
                if ($r -is [array]) { $r = @($r | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('content') }) | Select-Object -Last 1 }
                if ($null -eq $r) { $r = New-TextResult 'OK' }
                Write-McpLog ("{0} ok {1:N1}s" -f $name, ((Get-Date) - $t0).TotalSeconds)
            } catch {
                $err = Get-ErrorText $_
                Write-McpLog ("{0} FAILED {1:N1}s: {2}" -f $name, ((Get-Date) - $t0).TotalSeconds, $err)
                $r = New-ErrorResult $err
            }
            # Report any Aspen dialog the watchdog had to answer during this call.
            $ev = @([AspenDialogWatch]::Drain())
            if ($ev.Count -gt 0) {
                Write-McpLog ("dialogs: " + ($ev -join ' | '))
                $r.content = @($r.content) + @([ordered]@{ type = 'text'; text = ($ev -join "`n") })
            }
            Send-McpResult $id $r
        }
        default {
            if ($hasId) { Send-McpError $id -32601 "Method not found: $($msg.method)" }
        }
    }
}

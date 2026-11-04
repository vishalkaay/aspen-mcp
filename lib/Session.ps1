# Aspen instance lifecycle, working copies and write protection.

function Test-AspSession {
    if ($null -eq $global:S.App) { return $false }
    try { [void](Get-ComProp $global:S.App 'Visible'); return $true }
    catch { $global:S.App = $null; return $false }
}

function Start-AspInstance {
    $progid = Resolve-AspProgId "$($global:S.Config.progid)"
    $t = [type]::GetTypeFromProgID($progid)
    if ($null -eq $t) { throw "Aspen Plus COM class $progid is not registered. Is Aspen Plus installed on this PC? (run check.ps1)" }
    $global:S.ProgId = $progid
    Write-McpLog "starting $(Get-AspVersionName $progid) ($progid)"
    $app = [Activator]::CreateInstance($t)
    Start-DialogWatch $app
    return ,$app
}

# Switch the global unit set. ENG, MET and SI are always complete. Others (METCBAR in a blank
# simulation) start incomplete: referencing one makes Aspen ask "Copy Units From", and a set cannot
# be edited while referenced. So: reference it once (the dialog watch confirms), point back to MET,
# write every unit type from data\<name>.json, then reference it again.
function Set-AspUnitSet([string]$name) {
    $name = $name.ToUpper()
    $g = '\Data\Setup\Global\Input'
    $def = Join-Path $global:S.Root "data\$name.json"
    $asked = Find-AspNode "\Data\Setup\Units-Sets\$name\Input\ASKED"
    $complete = (@('ENG', 'MET', 'SI') -contains $name) -or ($null -ne $asked -and "$(Get-AspValue $asked)" -eq '1')
    if (-not $complete -and (Test-Path $def)) {
        Set-AspValue (Get-AspNode "$g\INSET") $name
        Set-AspValue (Get-AspNode "$g\INSET") 'MET'
        Set-AspValue (Get-AspNode "$g\OUTSET") 'MET'
        $types = (Get-Content $def -Raw | ConvertFrom-Json).unit_types
        foreach ($p in $types.PSObject.Properties) {
            $n = Find-AspNode "\Data\Setup\Units-Sets\$name\Unit-Types\$($p.Name)"
            if ($null -ne $n) { try { Set-AspValue $n $p.Value } catch { Write-McpLog "unit type $($p.Name): $(Get-ErrorText $_)" } }
        }
    }
    Set-AspValue (Get-AspNode "$g\INSET") $name
    Set-AspValue (Get-AspNode "$g\OUTSET") $name
    [ordered]@{
        in  = Get-AspValue (Get-AspNode "$g\INSET")
        out = Get-AspValue (Get-AspNode "$g\OUTSET")
        temperature = Get-AspValue (Find-AspNode "\Data\Setup\Units-Sets\$name\Unit-Types\TEMPERATURE")
        pressure    = Get-AspValue (Find-AspNode "\Data\Setup\Units-Sets\$name\Unit-Types\PRESSURE")
        mole_flow   = Get-AspValue (Find-AspNode "\Data\Setup\Units-Sets\$name\Unit-Types\MOLE-FLOW")
    }
}

# An instance whose InitNew2/InitFromArchive2 failed has no window; quit it (and kill it if that
# fails) so it does not linger invisibly and hold an Aspen license.
function Stop-FailedInstance($app) {
    $procId = $null; try { $procId = [int](Get-ComProp $app 'ProcessId') } catch {}
    try { [void](Invoke-ComMethod $app 'Quit') } catch {}
    try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($app) } catch {}
    if ($procId) { Start-Sleep -Milliseconds 500; Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    [AspenDialogWatch]::Stop()
}
function Format-StartError($err) {
    $m = Get-ErrorText $err
    if ($m -match 'Unexpected Error') {
        $m += ' - Aspen Plus could not start a simulation. This is usually licensing: check that Aspen Plus opens by hand, that a license is free, and that LSHOST (license server) is set in the system environment. Run check.ps1 -Aspen for a full diagnosis.'
    }
    return $m
}

function Show-AspInstance($app) {
    Set-ComProp $app 'Visible' $true
    try { Set-ComProp $app 'SuppressDialogs' $true } catch {}
}

function Close-AspInstance {
    if ($null -ne $global:S.App) {
        try { [void](Invoke-ComMethod $global:S.App 'Quit') } catch {}
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($global:S.App) } catch {}
    }
    [AspenDialogWatch]::Stop()
    $global:S.App = $null
    $global:S.Source = $null
    $global:S.Working = $null
    $global:S.RunStart = $null
}

function Assert-NoSession([bool]$replace) {
    if ((Test-AspSession) -and -not $replace) {
        $f = if ($global:S.Working) { $global:S.Working } else { 'an unsaved simulation' }
        throw "A simulation is already open ($f). Save it with aspen_save, or call again with replace=true to discard it."
    }
    if (Test-AspSession) { Close-AspInstance }
}

# Relative paths resolve against the workspace folder.
function Resolve-AspPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { throw 'Empty path' }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $global:S.Workspace $p }
    return [IO.Path]::GetFullPath($p)
}

function Test-ProtectedPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    foreach ($pp in $global:S.Config.protected_paths) {
        if (-not $pp) { continue }
        $root = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($pp)).TrimEnd('\')
        if ($full -ieq $root -or $full.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function New-WorkingCopy([string]$src) {
    $name = (Get-Date).ToString('yyyyMMdd-HHmmss') + '_' + [IO.Path]::GetFileName($src)
    $dest = Join-Path $global:S.Workspace $name
    Copy-Item -LiteralPath $src -Destination $dest
    return $dest
}

function Get-RunStatusCodes {
    $o = [ordered]@{}
    foreach ($k in 'PER_ERROR', 'UOSSTAT2', 'CVSTAT') {
        $n = Find-AspNode "\Data\Results Summary\Run-Status\Output\$k"
        if ($null -ne $n) { $v = Get-AspValue $n; if ("$v" -ne '') { $o[$k] = $v } }
    }
    return $o
}

# Input completeness: attribute 12 (HAP_COMPSTATUS) is a bit mask; 0x40 = input incomplete.
# Aspen will not run at all while anything is incomplete, so this explains a run that produced nothing.
function Test-AspIncomplete($n) { $s = [AspCom]::Attr($n, 12); return ($null -ne $s -and "$s" -ne '' -and ([int64]$s -band 0x40) -ne 0) }
function Get-IncompleteInput {
    $items = @()
    if (-not (Test-AspIncomplete (Get-AspNode '\Data'))) { return ,$items }
    foreach ($g in @(@('setup', '\Data\Setup'), @('components', '\Data\Components'), @('properties', '\Data\Properties'))) {
        $n = Find-AspNode $g[1]; if ($n -and (Test-AspIncomplete $n)) { $items += $g[0] }
    }
    foreach ($g in @(@('block', '\Data\Blocks'), @('stream', '\Data\Streams'), @('design-spec', '\Data\Flowsheeting Options\Design-Spec'),
            @('calculator', '\Data\Flowsheeting Options\Calculator'), @('sensitivity', '\Data\Model Analysis Tools\Sensitivity'))) {
        $root = Find-AspNode $g[1]; if ($null -eq $root) { continue }
        foreach ($k in ([AspCom]::Children($root))) {
            if (Test-AspIncomplete $k) {
                $m = [AspCom]::Attr($k, 6)
                $items += if ($g[0] -eq 'block' -and $m) { "block $([AspCom]::Name($k)) ($m)" } else { "$($g[0]) $([AspCom]::Name($k))" }
            }
        }
    }
    if ($items.Count -eq 0) { $items += 'unknown (check the Aspen window: incomplete forms are marked red)' }
    return ,$items
}

# When blocks finish with warnings or errors, PER_ERROR holds message lines instead of a code
# ("The following Convergence blocks were / completed with warnings: / $OLVER01").
function Get-RunSummaryMessages {
    $n = Find-AspNode '\Data\Results Summary\Run-Status\Output\PER_ERROR'
    if ($null -eq $n -or (Get-AspChildCount $n) -eq 0) { return ,@() }
    $vals = [AspCom]::ChildValues($n)
    $msgs = @(); $cur = ''
    foreach ($k in $vals.Keys) {
        $s = "$($vals[$k])".Trim()
        if (-not $s) { if ($cur) { $msgs += $cur; $cur = '' }; continue }
        $cur = if ($cur) { "$cur $s" } else { $s }
    }
    if ($cur) { $msgs += $cur }
    return ,$msgs
}

# Export the .rep report to the workspace; returns its path, or $null when Aspen has no results yet.
function Export-AspReport {
    $dir = Join-Path $global:S.Workspace 'reports'
    if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $f = Join-Path $dir ('rep_' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
    [void](Invoke-ComMethod (Get-AspApp) 'Export' @([int]2, $f))
    if (Test-Path "$f.rep") { return "$f.rep" }
    return $null
}

# Status line + problem messages from the report (the PROBLEM STATUS SECTION).
function Get-RunMessages([string]$rep) {
    $L = Get-Content -LiteralPath $rep
    $o = [ordered]@{}
    $st = $L | Select-String -Pattern 'STATUS: ' | Select-Object -First 1
    if ($st) { $o.status = $st.Line.Trim() }
    $hits = $L | Select-String -Pattern '^\s*PROBLEM STATUS SECTION\s*$'
    $msgs = @()
    if ($hits) {
        $i = ($hits | Select-Object -Last 1).LineNumber
        for ($j = $i; $j -lt $L.Count -and $msgs.Count -lt 80; $j++) {
            $line = $L[$j]
            if ($line -match '^\s\*\s+\S') { $msgs += ($line.Trim().Trim('*').Trim()) }
        }
    }
    $o.messages = [object[]]$msgs
    if (-not $o.status) {
        # Simple flowsheets have no convergence STATUS line; use the overall summary message instead.
        $first = $msgs | Where-Object { $_ -match 'completed|error|warning' } | Select-Object -First 1
        if ($first) { $o.status = $first }
    }
    return $o
}

function Get-RunState([bool]$withReport = $true) {
    $app = Get-AspApp
    $eng = Get-ComProp $app 'Engine'
    $running = $false
    try { $running = [bool](Get-ComProp $eng 'IsRunning') } catch {}
    $o = [ordered]@{ running = $running }
    if ($global:S.RunStart) { $o.elapsed_s = [int]((Get-Date) - $global:S.RunStart).TotalSeconds }
    $o.codes = Get-RunStatusCodes
    if (-not $running) { $sm = Get-RunSummaryMessages; if ($sm.Count) { $o.summary = [object[]]$sm } }
    if (-not $running -and $withReport) {
        $rep = Export-AspReport
        if ($rep) {
            $m = Get-RunMessages $rep
            $o.status = $m.status
            $o.messages = $m.messages
            Remove-Item -LiteralPath $rep -Force -ErrorAction SilentlyContinue
        } else {
            $inc = Get-IncompleteInput
            if ($inc.Count) {
                $o.status = 'Input is incomplete, so Aspen cannot run. Complete these first.'
                $o.incomplete = [object[]]$inc
            } else { $o.status = 'No results yet (run the simulation).' }
        }
    }
    return $o
}

function Get-AspSummary {
    $o = [ordered]@{ open = (Test-AspSession) }
    if (-not $o.open) { return $o }
    $app = Get-AspApp
    $o.source_file = $global:S.Source
    $o.working_file = $global:S.Working
    try { $o.aspen_pid = [int](Get-ComProp $app 'ProcessId') } catch {}
    if ($global:S.ProgId) { $o.aspen_version = Get-AspVersionName $global:S.ProgId }
    $o.unit_set = Get-AspValue (Find-AspNode '\Data\Setup\Global\Input\INSET')
    $o.property_method = Get-AspValue (Find-AspNode '\Data\Properties\Specifications\Input\GBASEOPSET')
    $o.components = Get-AspChildNames '\Data\Components\Specifications\Input\TYPE'
    $o.blocks = Get-AspChildNames '\Data\Blocks'
    $o.streams = Get-AspChildNames '\Data\Streams'
    $ds = Get-AspChildNames '\Data\Flowsheeting Options\Design-Spec'; if ($ds.Count) { $o.design_specs = $ds }
    $se = Get-AspChildNames '\Data\Model Analysis Tools\Sensitivity'; if ($se.Count) { $o.sensitivities = $se }
    $ca = Get-AspChildNames '\Data\Flowsheeting Options\Calculator'; if ($ca.Count) { $o.calculators = $ca }
    $rx = Get-AspChildNames '\Data\Reactions\Reactions'; if ($rx.Count) { $o.reaction_sets = $rx }
    # Informational: Aspen marks e.g. unreviewed binary parameters as incomplete but still runs.
    $inc = Get-IncompleteInput
    if ($inc.Count) { $o.incomplete_input = [object[]]$inc }
    $o.run_codes = Get-RunStatusCodes
    return $o
}

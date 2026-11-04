# Session tools: create, open, inspect, save, close.

Register-McpTool -Name 'aspen_new' `
    -Description 'Start a new blank simulation in a visible Aspen Plus window. unit_set: METCBAR (C, bar, kmol/hr, kg/hr; default), MET (K, atm), SI (K, Pa) or ENG (F, psia, lbmol/hr). Takes ~15 s for METCBAR.' `
    -Properties @{ unit_set = (P-Enum 'Global unit set for input and output' @('METCBAR', 'MET', 'SI', 'ENG')); replace = (P-Bool 'Discard an already open simulation') } `
    -Handler {
        param($a)
        Assert-NoSession ([bool]$a.replace)
        $app = Start-AspInstance
        [void](Invoke-ComMethod $app 'InitNew2')
        $global:S.App = $app
        Show-AspInstance $app
        $us = if ($a.unit_set) { $a.unit_set } else { $global:S.Config.default_unit_set }
        $units = if ($us) { Set-AspUnitSet $us } else { $null }
        $o = Get-AspSummary
        if ($units) { $o.units = $units }
        New-JsonResult $o
    }

Register-McpTool -Name 'aspen_open' `
    -Description 'Open a .bkp, .apw or .apwz file in a visible Aspen Plus window. By default the file is copied into the server workspace and the copy is opened, so the original is never modified; files under protected folders are always copied. Results in a .bkp may be absent or stale until you run.' `
    -Properties @{ file = (P-Str 'Path to the simulation file'); in_place = (P-Bool 'Open the original file instead of a working copy (refused for protected folders)'); replace = (P-Bool 'Discard an already open simulation') } `
    -Required @('file') `
    -Handler {
        param($a)
        $src = Resolve-AspPath $a.file
        if (-not (Test-Path -LiteralPath $src)) { throw "File not found: $src" }
        $ext = [IO.Path]::GetExtension($src).ToLower()
        if (@('.bkp', '.apw', '.apwz', '.inp') -notcontains $ext) { throw "Unsupported file type $ext (use .bkp, .apw, .apwz or .inp)" }
        Assert-NoSession ([bool]$a.replace)
        $protected = Test-ProtectedPath $src
        if ($a.in_place -and $protected) { throw "$src is in a protected folder; it can only be opened as a working copy." }
        $work = if ($a.in_place) { $src } else { New-WorkingCopy $src }
        $app = Start-AspInstance
        try {
            if ($ext -eq '.apw') { [void](Invoke-ComMethod $app 'InitFromFile2' @($work)) }
            else { [void](Invoke-ComMethod $app 'InitFromArchive2' @($work)) }
        } catch {
            try { [void](Invoke-ComMethod $app 'Quit') } catch {}
            throw
        }
        $global:S.App = $app
        $global:S.Source = $src
        $global:S.Working = $work
        Show-AspInstance $app
        $o = Get-AspSummary
        $o.protected_source = $protected
        New-JsonResult $o
    }

Register-McpTool -Name 'aspen_info' `
    -Description 'Summary of the open simulation: files, Aspen PID, unit set, property method, components, blocks, streams, run status codes.' `
    -Handler { param($a) New-JsonResult (Get-AspSummary) }

Register-McpTool -Name 'aspen_save' `
    -Description 'Save the simulation. Without file, saves over the working copy. file may be absolute or relative to the workspace; .bkp (text archive, small) or .apw. Saving into a protected folder is refused.' `
    -Properties @{ file = (P-Str 'Target path (.bkp or .apw)'); overwrite = (P-Bool 'Allow replacing an existing file other than the working copy') } `
    -Handler {
        param($a)
        $app = Get-AspApp
        $target = if ($a.file) { Resolve-AspPath $a.file } elseif ($global:S.Working) { $global:S.Working } else { $null }
        if (-not $target) { throw 'This simulation has no file yet. Pass file, e.g. "my_case.bkp" (saved in the workspace).' }
        $ext = [IO.Path]::GetExtension($target).ToLower()
        if (@('.bkp', '.apw') -notcontains $ext) { throw 'Save as .bkp or .apw' }
        if (Test-ProtectedPath $target) { throw "Refusing to write into a protected folder: $target" }
        $isWorking = $global:S.Working -and ($target -ieq $global:S.Working)
        if ((Test-Path -LiteralPath $target) -and -not $isWorking -and -not $a.overwrite) { throw "$target already exists. Pass overwrite=true to replace it." }
        $dir = Split-Path $target -Parent
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
        $saved = $false
        if (Test-Path -LiteralPath $target) {
            try { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
            catch { if ($isWorking) { [void](Invoke-ComMethod $app 'Save'); $saved = $true } else { throw } }
        }
        if (-not $saved) { [void](Invoke-ComMethod $app 'SaveAs' @($target)) }
        if (-not (Test-Path -LiteralPath $target)) { throw "Aspen did not write $target" }
        $global:S.Working = $target
        New-JsonResult ([ordered]@{ saved = $target; kb = [int]((Get-Item -LiteralPath $target).Length / 1KB) })
    }

Register-McpTool -Name 'aspen_close' `
    -Description 'Close the simulation and quit the Aspen window. Unsaved changes are lost unless save=true (saves the working copy first).' `
    -Properties @{ save = (P-Bool 'Save the working copy before closing') } `
    -Handler {
        param($a)
        if (-not (Test-AspSession)) { return New-TextResult 'No simulation open.' }
        if ($a.save) {
            if (-not $global:S.Working) { throw 'No working file to save to; use aspen_save with a file first.' }
            if (Test-ProtectedPath $global:S.Working) { throw 'Working file is protected.' }
            [void](& $global:S.Handlers['aspen_save'] ([pscustomobject]@{}))
        }
        $w = $global:S.Working
        Close-AspInstance
        New-TextResult ("Closed." + $(if ($w) { " Last file: $w" } else { '' }))
    }

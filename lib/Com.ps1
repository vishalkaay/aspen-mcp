# COM helpers for Aspen Plus (Apwn.Document).
#
# PowerShell 5.1 pitfalls shape everything here:
#  1. The PS COM adapter exposes Aspen's Value/Name/Label as "parameterized properties" that cannot
#     be read or written normally, so all access goes through reflection (InvokeMember).
#  2. Calling InvokeMember from PowerShell costs ~20 ms per call (the COM adapter rebuilds type
#     info for every object), so a 1000-node walk took minutes. The calls are therefore made from
#     the compiled AspCom class below (~1 ms each), and whole-subtree walks run entirely in C#.
#  3. A function that returns a COM collection (or a node that has children) gets enumerated into
#     its items on the way out. Every helper therefore returns with the unary comma (return ,$x),
#     and returns nothing at all for $null.
# Also: never name a helper like a built-in alias (sv, gp, sp, set, mv ...). Verb-Noun names are safe.

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Diagnostics;
using System.Reflection;
using System.Globalization;
using System.Collections.Generic;
using System.Text.RegularExpressions;

public static class AspCom {
    const BindingFlags GP = BindingFlags.GetProperty, SP = BindingFlags.SetProperty, IM = BindingFlags.InvokeMethod;
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public static object Get(object o, string n, object[] a) { return o.GetType().InvokeMember(n, GP, null, o, a); }
    public static void Set(object o, string n, object[] a) { o.GetType().InvokeMember(n, SP, null, o, a); }
    public static object Call(object o, string n, object[] a) { return o.GetType().InvokeMember(n, IM, null, o, a); }

    public static object Find(object app, string path) { return Call(Get(app, "Tree", null), "FindNode", new object[] { path }); }
    public static string Name(object n) { try { return Convert.ToString(Get(n, "Name", null), Inv); } catch { return null; } }
    public static object Value(object n) { try { return Get(n, "Value", null); } catch { return null; } }
    public static string Units(object n) {
        try { string u = Convert.ToString(Get(n, "UnitString", null), Inv); return string.IsNullOrEmpty(u) ? null : u; } catch { return null; }
    }
    public static object Attr(object n, int i) {
        try { return Get(n, "AttributeValue", new object[] { i }); } catch { }
        try { return Call(n, "AttributeValue", new object[] { i }); } catch { return null; }
    }
    public static string Text(object v) {
        if (v == null) return "";
        return Convert.ToString(v, Inv);
    }

    static object Elements(object n) { try { return Get(n, "Elements", null); } catch { return null; } }
    public static object[] Children(object n) {
        object els = Elements(n);
        if (els == null) return new object[0];
        int c = Convert.ToInt32(Get(els, "Count", null));
        var r = new List<object>(c);
        for (int i = 0; i < c; i++) { object e = Get(els, "Item", new object[] { i }); if (e != null) r.Add(e); }
        return r.ToArray();
    }
    public static int ChildCount(object n) {
        object els = Elements(n);
        if (els == null) return 0;
        try { return Convert.ToInt32(Get(els, "Count", null)); } catch { return 0; }
    }
    public static string[] ChildNames(object n) {
        object[] k = Children(n);
        var r = new string[k.Length];
        for (int i = 0; i < k.Length; i++) r[i] = Name(k[i]);
        return r;
    }

    // "path = value [units]" lines for a subtree (aspen_tree).
    public static string Tree(object n, string path, int maxDepth, bool nonEmpty, int limit) {
        var lines = new List<string>();
        Walk(n, path, 0, maxDepth, nonEmpty, lines, limit);
        return string.Join("\n", lines.ToArray());
    }
    static void Walk(object n, string path, int depth, int maxDepth, bool nonEmpty, List<string> lines, int limit) {
        if (lines.Count >= limit) return;
        object[] kids = Children(n);
        if (kids.Length == 0) {
            string v = Text(Value(n));
            if (!nonEmpty || v.Length > 0) {
                string u = Units(n);
                lines.Add(path + " = " + v + (u != null ? " [" + u + "]" : ""));
            }
            return;
        }
        if (depth >= maxDepth) { lines.Add(path + "\\ (+" + kids.Length + " children)"); return; }
        foreach (object k in kids) {
            if (lines.Count >= limit) { lines.Add("...(limit reached)"); return; }
            Walk(k, path + "\\" + Name(k), depth + 1, maxDepth, nonEmpty, lines, limit);
        }
    }

    // Breadth-first name search (aspen_find). Each hit is {path, value, units}.
    public static List<string[]> Search(object root, string rootPath, string pattern, int maxDepth, int max, int maxNodes, int maxMs, out int visited) {
        var rx = new Regex(pattern, RegexOptions.IgnoreCase);
        var hits = new List<string[]>();
        var q = new Queue<KeyValuePair<object, KeyValuePair<string, int>>>();
        q.Enqueue(new KeyValuePair<object, KeyValuePair<string, int>>(root, new KeyValuePair<string, int>(rootPath, 0)));
        visited = 0;
        var sw = Stopwatch.StartNew();
        while (q.Count > 0 && hits.Count < max && visited < maxNodes && sw.ElapsedMilliseconds < maxMs) {
            var it = q.Dequeue();
            string p = it.Value.Key; int d = it.Value.Value;
            foreach (object k in Children(it.Key)) {
                visited++;
                string nm = Name(k), kp = p + "\\" + nm;
                if (nm != null && rx.IsMatch(nm)) {
                    hits.Add(new string[] { kp, Text(Value(k)), Units(k) });
                    if (hits.Count >= max) break;
                }
                if (d + 1 < maxDepth) q.Enqueue(new KeyValuePair<object, KeyValuePair<string, int>>(k, new KeyValuePair<string, int>(kp, d + 1)));
            }
        }
        return hits;
    }

    // Input fields with Aspen's own help text (attribute 19) and allowed values (attribute 5, a node
    // whose value is a newline-separated list). Each row: {path, value, units, options, prompt, children}.
    public static List<string[]> Describe(object n, string path, int maxDepth, string pattern, bool specifiedOnly, int max) {
        var rows = new List<string[]>();
        Regex rx = string.IsNullOrEmpty(pattern) ? null : new Regex(pattern, RegexOptions.IgnoreCase);
        DescribeWalk(n, path, 0, maxDepth, rx, specifiedOnly, max, rows);
        return rows;
    }
    static void DescribeWalk(object n, string path, int depth, int maxDepth, Regex rx, bool specifiedOnly, int max, List<string[]> rows) {
        foreach (object k in Children(n)) {
            if (rows.Count >= max) return;
            string nm = Name(k);
            if (nm == null || nm == "Unit Set" || nm.StartsWith("User T")) continue;
            string kp = path + "\\" + nm;
            object[] kids = Children(k);
            if (kids.Length > 0 && depth + 1 < maxDepth) { DescribeWalk(k, kp, depth + 1, maxDepth, rx, specifiedOnly, max, rows); continue; }
            string v = Text(Value(k));
            if (specifiedOnly && v.Length == 0 && kids.Length == 0) continue;
            string prompt = Text(Attr(k, 19));
            if (rx != null && !rx.IsMatch(nm) && !rx.IsMatch(prompt)) continue;
            string opts = "";
            object o = Attr(k, 5);
            if (o != null && !(o is string)) { try { opts = Text(Value(o)).Replace("\r", "").Replace("\n", ","); } catch { } }
            string kidNames = "";
            if (kids.Length > 0) {
                var names = new List<string>();
                for (int i = 0; i < kids.Length && i < 12; i++) names.Add(Name(kids[i]));
                kidNames = string.Join(",", names.ToArray()) + (kids.Length > 12 ? ",..." : "");
            }
            rows.Add(new string[] { kp, v, Units(k) ?? "", opts, prompt, kidNames });
        }
    }

    // Leaf children of a node as name -> value (component flows, profiles ...).
    public static Dictionary<string, object> ChildValues(object n) {
        var r = new Dictionary<string, object>();
        foreach (object k in Children(n)) { string nm = Name(k); if (nm != null && !r.ContainsKey(nm)) r[nm] = Value(k); }
        return r;
    }
}
'@

# Cmdlet output (Join-Path, Get-Content ...) arrives wrapped in PSObject, which COM rejects with
# DISP_E_TYPEMISMATCH, so every argument is unwrapped to its base object first.
function ConvertTo-ComArgs($argList) {
    if ($null -eq $argList) { return $null }
    $out = New-Object object[] (@($argList).Count)
    $i = 0
    foreach ($x in @($argList)) { $out[$i++] = if ($x -is [psobject]) { $x.PSObject.BaseObject } else { $x } }
    return ,$out
}
function Get-ComProp($o, [string]$name, $argList = $null) {
    $r = [AspCom]::Get($o, $name, (ConvertTo-ComArgs $argList))
    if ($null -eq $r) { return }
    return ,$r
}
function Set-ComProp($o, [string]$name, $value) {
    [AspCom]::Set($o, $name, (ConvertTo-ComArgs @(, $value)))
}
function Set-ComPropArgs($o, [string]$name, [object[]]$argList) {
    [AspCom]::Set($o, $name, (ConvertTo-ComArgs $argList))
}
function Invoke-ComMethod($o, [string]$name, $argList = $null) {
    $r = [AspCom]::Call($o, $name, (ConvertTo-ComArgs $argList))
    if ($null -eq $r) { return }
    return ,$r
}

# Innermost exception message (COM errors arrive wrapped in TargetInvocationException).
function Get-ErrorText($err) {
    $e = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception } else { $err }
    $msgs = @()
    while ($e) { if ($e.Message -and $msgs -notcontains $e.Message) { $msgs += $e.Message }; $e = $e.InnerException }
    if ($msgs.Count -gt 1) { $msgs = $msgs | Where-Object { $_ -notmatch '^Exception (calling|has been thrown)' } }
    ($msgs -join ' | ')
}

function ConvertTo-AspInput($v) {
    # ConvertFrom-Json in PS 5.1 yields Decimal for fractions; COM wants a double.
    if ($v -is [decimal] -or $v -is [single]) { return [double]$v }
    if ($v -is [long]) { if ($v -ge [int]::MinValue -and $v -le [int]::MaxValue) { return [int]$v } else { return [double]$v } }
    return $v
}

function ConvertTo-Double($v) {
    $x = 0.0
    if ($null -eq $v) { return $null }
    if ([double]::TryParse("$v", [Globalization.NumberStyles]::Float, $script:Inv, [ref]$x)) { return $x }
    return $null
}

# ---- variable tree ----
function Get-AspApp {
    if (-not (Test-AspSession)) { throw 'No Aspen simulation is open. Use aspen_new or aspen_open first.' }
    return ,$global:S.App
}
function Find-AspNode([string]$path) {
    $n = [AspCom]::Find((Get-AspApp), $path)
    if ($null -eq $n) { return }
    return ,$n
}
function Get-AspNode([string]$path) {
    $n = Find-AspNode $path
    if ($null -eq $n) { throw "Node not found: $path (use aspen_list or aspen_find on the parent to see valid names)" }
    return ,$n
}
function Get-AspValue($n) { $v = [AspCom]::Value($n); if ($null -eq $v) { return $null }; return ,$v }
function Get-AspName($n) { [AspCom]::Name($n) }
function Get-AspUnits($n) { [AspCom]::Units($n) }
function Get-AspAttr($n, [int]$i) { [AspCom]::Attr($n, $i) }
function Set-AspValue($n, $v) { Set-ComProp $n 'Value' (ConvertTo-AspInput $v) }

function Get-AspChildren($n) { return ,([AspCom]::Children($n)) }
function Get-AspChildCount($n) { [AspCom]::ChildCount($n) }
# Returns one string[] object: assign it to a variable before looping; @(Get-AspChildNames ...) would
# wrap the whole array as a single element.
function Get-AspChildNames([string]$path) {
    $n = Find-AspNode $path
    if ($null -eq $n) { return ,@() }
    return ,([string[]][AspCom]::ChildNames($n))
}
function Get-AspCollection([string]$path) {
    $n = Get-AspNode $path
    $c = Get-ComProp $n 'Elements'
    if ($null -eq $c) { throw "Node has no element collection: $path" }
    return ,$c
}
function Add-AspElement([string]$path, [string]$name) {
    $c = Get-AspCollection $path
    [void](Invoke-ComMethod $c 'Add' @($name))
}
function Remove-AspElement([string]$path, [string]$name) {
    $c = Get-AspCollection $path
    [void](Invoke-ComMethod $c 'Remove' @($name))
}
# Table-style nodes (component lists, flow tables, heat-curve keys) grow by inserting a labelled row.
# Some tables (sensitivity vary rows) have no labels; their rows are named #0, #1 ... by Aspen.
function Add-AspRow([string]$path, [string]$label) {
    $c = Get-AspCollection $path
    $rn = Get-ComProp $c 'RowCount' @([int]0)
    [void](Invoke-ComMethod $c 'InsertRow' @([int]0, [int]$rn))
    if ($label) { Set-ComPropArgs $c 'Label' @([int]0, [int]$rn, "$label") }
    return $rn
}
# Two-dimensional tables (RStoic coefficients: component x substream) take a label per dimension.
function Add-AspRow2([string]$path, [string]$label0, [string]$label1) {
    $c = Get-AspCollection $path
    $rn = Get-ComProp $c 'RowCount' @([int]0)
    [void](Invoke-ComMethod $c 'InsertRow' @([int]0, [int]$rn))
    Set-ComPropArgs $c 'Label' @([int]0, [int]$rn, "$label0")
    Set-ComPropArgs $c 'Label' @([int]1, [int]$rn, "$label1")
    return $rn
}
function Remove-AspRow([string]$path, [string]$label) {
    $c = Get-AspCollection $path
    $rows = Get-ComProp $c 'RowCount' @([int]0)
    for ($i = 0; $i -lt $rows; $i++) {
        if ("$(Get-ComProp $c 'Label' @([int]0, [int]$i))" -ieq $label) {
            [void](Invoke-ComMethod $c 'RemoveRow' @([int]0, [int]$i))
            return
        }
    }
    throw "No row '$label' under $path"
}

# Value + units of one node as an ordered dictionary.
function Read-AspNode([string]$path) {
    $n = Find-AspNode $path
    if ($null -eq $n) { return [ordered]@{ path = $path; error = 'node not found' } }
    $o = [ordered]@{ path = $path; value = (Get-AspValue $n) }
    $u = Get-AspUnits $n; if ($u) { $o.units = $u }
    $k = Get-AspChildCount $n; if ($k -gt 0) { $o.children = $k }
    return $o
}
function Read-AspNumber([string]$path) {
    $n = Find-AspNode $path
    if ($null -eq $n) { return $null }
    return (ConvertTo-Double (Get-AspValue $n))
}
# Number when the value parses as one, else the raw value; $null for empty.
function ConvertTo-AspOutput($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    $d = ConvertTo-Double $v
    if ($null -ne $d) { return $d }
    return "$v".Trim()
}
# Leaf children of a node as an ordered name -> value map (numbers where possible); units of the first child.
function Read-AspVector([string]$path, $units, [string]$key) {
    $n = Find-AspNode $path
    if ($null -eq $n) { return $null }
    $o = [ordered]@{}
    $first = $null
    foreach ($k in ([AspCom]::Children($n))) {
        if ($null -eq $first) { $first = $k }
        $o[[AspCom]::Name($k)] = ConvertTo-AspOutput ([AspCom]::Value($k))
    }
    if ($units -and $key -and $first -and -not $units.Contains($key)) { $u = [AspCom]::Units($first); if ($u) { $units[$key] = $u } }
    return $o
}
# Set several nodes; emits one {path, value, units} or {path, error} row per entry, in order.
# Rows are emitted one by one (not as one array), so collect them with @(Set-AspValues ...).
function Set-AspValues($map) {
    $out = @()
    foreach ($p in $map.Keys) {
        $n = Find-AspNode $p
        if ($null -eq $n) { $out += [ordered]@{ path = $p; error = 'node not found' }; continue }
        try {
            Set-AspValue $n $map[$p]
            $r = [ordered]@{ path = $p; value = (Get-AspValue $n) }
            $u = Get-AspUnits $n; if ($u) { $r.units = $u }
            $out += $r
        } catch { $out += [ordered]@{ path = $p; error = (Get-ErrorText $_) } }
    }
    return $out
}

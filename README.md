# Aspen Plus MCP server

Lets Claude build, edit, run and inspect **Aspen Plus V14** simulations in a live, visible Aspen window.
Claude talks to the server over MCP (stdio). The server drives Aspen through its COM automation interface.

- **No dependencies.** It's plain Windows PowerShell 5.1, which ships with Windows, plus Aspen Plus itself.
- **Live view.** You watch the flowsheet change in Aspen. Claude can also take a screenshot of the window.
- **Safe with existing work.** Files are opened as working copies, and folders listed in `config.json` are never written to.

## Install

```bash
powershell -ExecutionPolicy Bypass -File install.ps1
```

This registers the server as `aspen-plus` in every Claude Desktop config it finds, backing each one up first. If the Claude Code CLI is installed, it registers the server there too. Then fully quit Claude Desktop, reopen it, and start a **new** chat or session. MCP tools load when a session starts.

To remove it, run `install.ps1 -Uninstall`.

For a manual setup, add this to `claude_desktop_config.json`:

```json
"mcpServers": {
  "aspen-plus": {
    "command": "powershell.exe",
    "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\path\\to\\aspen-mcp\\server.ps1"]
  }
}
```

## Try it

> Start a new METCBAR simulation with water and methanol (NRTL). Feed 80 kmol/h water and 20 kmol/h methanol at 25 °C and 1.5 bar into a Heater that heats it to 60 °C, run it, and show me the duty.

> Open my_plant.bkp from my project folder, list the RadFrac columns and their reboiler duties.

> Take a screenshot of the flowsheet.

## Tools

| Area | Tools |
|---|---|
| Session | `aspen_new` (blank, unit set METCBAR/MET/SI/ENG), `aspen_open` (.bkp/.apw/.apwz, as a working copy), `aspen_info`, `aspen_save`, `aspen_close` |
| Variable tree | `aspen_get` (one or many paths, with units), `aspen_set` (one, or a `{path: value}` map), `aspen_list`, `aspen_tree` (non-empty leaves of a subtree), `aspen_find` (regex on node names), `aspen_add_row` (table rows) |
| Flowsheet | `aspen_flowsheet` (topology), `aspen_add_components`, `aspen_remove_component`, `aspen_set_property_method`, `aspen_set_units`, `aspen_add_block`, `aspen_add_stream` (material/heat/work), `aspen_connect`, `aspen_disconnect`, `aspen_delete`, `aspen_set_stream` |
| Run | `aspen_run` (starts, waits up to 40 s, then poll), `aspen_status`, `aspen_stop`, `aspen_reinit`, `aspen_report` (search the .rep) |
| Results | `aspen_streams` (T, P, vapour fraction, flows, components), `aspen_block_results` (scalar outputs with units) |
| View | `aspen_screenshot` (PNG of the Aspen window) |
| Files | `aspen_list_files`, `aspen_read_file` (text files: .bkp, .rep, .csv ...; read-only, no Aspen needed) |

Everything in Aspen is a node in the variable tree, so anything without a dedicated tool can still be reached with `aspen_get` and `aspen_set`. For example:

| What | Path |
|---|---|
| Stream input temperature | `\Data\Streams\FEED\Input\TEMP\MIXED` |
| Component flow in a feed | `\Data\Streams\FEED\Input\FLOW\MIXED\WATER` |
| Stream result temperature | `\Data\Streams\OUT\Output\TEMP_OUT\MIXED` |
| Block spec | `\Data\Blocks\C1\Input\NSTAGE`, `...\Input\BASIS_RR` (string `"2"`) |
| Block result | `\Data\Blocks\H1\Output\QCALC`, `\Data\Blocks\C1\Output\REB_DUTY` |
| Run status | `\Data\Results Summary\Run-Status\Output\PER_ERROR` (0 = no errors) |

## Configuration (`config.json`)

Copy `config.example.json` to `config.json` and edit it. `config.json` is gitignored, so your local paths stay out of the repo. Without it, the defaults below apply.

| Key | Default | Meaning |
|---|---|---|
| `protected_paths` | `[]` | Folders that are never written to. Files there always open as copies, and saving or exporting into them is refused. |
| `workspace` | `workspace` | Where working copies, saved cases, reports and screenshots go. |
| `default_unit_set` | `METCBAR` | Unit set for `aspen_new`. |
| `run_wait_seconds` | `40` | How long `aspen_run` waits before returning `running=true`. |
| `confirm_dialogs` | `["Copy Units From"]` | Aspen dialog titles the watchdog answers with OK. It closes every other dialog. |
| `quit_aspen_on_exit` | `false` | Quit Aspen when Claude disconnects. Off by default, so unsaved work stays open. |
| `progid` | `Apwn.Document.40.0` | COM class (V14). Change it for other Aspen versions. |

## Tests

```bash
powershell -ExecutionPolicy Bypass -File tests\protocol.tests.ps1
```

```bash
powershell -ExecutionPolicy Bypass -File tests\live.tests.ps1
```

Optional inputs: `-SampleBkp <file.bkp>` (or `ASPEN_MCP_SAMPLE_BKP`) turns on the `.bkp` reading tests in `protocol.tests.ps1`. `-ProtectedFile <file.bkp>` (or `ASPEN_MCP_PROTECTED_FILE`) turns on the protection tests in `live.tests.ps1`; the file must be inside a folder listed in `protected_paths`.

`protocol.tests.ps1` takes about 2 seconds and doesn't start Aspen. `live.tests.ps1` takes about 2 minutes and opens Aspen windows. It builds a water/methanol heater from scratch, runs it and checks the mass balance and duty. It also takes a screenshot, saves the case, and opens a file from a protected folder to confirm nothing there gets written. Both scripts drive `server.ps1` as a child process over stdio, the same way Claude does.

## How it works and what was hard

- **Layout.** `server.ps1` handles the stdio loop. `lib\Protocol.ps1` holds the JSON-RPC handling and tool registry. `lib\Com.ps1` has the COM helpers. `lib\Session.ps1` covers the instance lifecycle, protection, unit sets and run status. `lib\Dialogs.ps1` is the dialog watchdog, and `tools\*.ps1` registers the tools.
- **Value and Name.** PowerShell's COM adapter can't read or write Aspen's `Value` and `Name`, which are parameterized properties. All access goes through `InvokeMember`.
- **Unrolled return values.** Functions that return a COM collection must use `return ,$x`, or PowerShell unrolls it, and an empty one becomes `$null`.
- **Wrapped arguments.** Cmdlet output is wrapped in `PSObject`, and COM rejects it with `DISP_E_TYPEMISMATCH`, so every argument is unwrapped first.
- **Alias names.** Helper names must not collide with built-in aliases such as `sv`, `gp`, `sp` or `set`. Aliases win over functions.
- **Hidden dialogs.** Aspen can raise modal dialogs that `SuppressDialogs` doesn't cover. Without the watchdog, the COM call would block forever. Each tool result reports any dialog the watchdog handled.
- **METCBAR.** In a blank simulation METCBAR is an incomplete unit set. `aspen_new` completes it from `data\METCBAR.json`, which was captured from a working V14 case.
- **Runs.** `Engine.Run2` returns immediately, so runs are polled through `IsRunning`. Status comes from the run codes and the exported `.rep` report. Aspen only writes a report once results exist.
- **Heat stream sign.** A heat stream leaving a heater carries the negative of the heater duty, which is Aspen's convention.

## Limits

- The server opens its own Aspen window. It can't attach to an Aspen window you opened yourself, because Aspen doesn't register in the running-object table. Close the file there first, then use `aspen_open`.
- It handles one simulation at a time per server.
- Large flowsheets can take minutes to converge from a cold start. Use `aspen_run` with a longer `wait_seconds`, or poll `aspen_status`.
- The log is in `logs\server.log`.

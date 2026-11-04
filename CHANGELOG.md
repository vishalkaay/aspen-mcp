# Changelog

## 1.3.0

- **Fixed: "Unexpected Error" when Claude starts a simulation.** Claude Desktop and Claude Code start MCP servers with a trimmed environment. Without `LSHOST`, Aspen Plus can't find its license server. The server now restores missing variables from the user and system environment when it starts.
- A failed start no longer leaves an invisible Aspen process holding a license, and the error says what to check.
- `progid: "auto"` (the default) finds the newest installed Aspen Plus (V11–V16), so it is no longer locked to V14.
- `install.ps1` registers with both Claude Desktop and Claude Code (`~/.claude.json`). It edits only its own entry, keeps backups, unblocks downloaded files and checks the PC first. `-Uninstall` restores each config byte for byte.
- New `check.ps1` health check, with `-Aspen` for a live test.
- New `tests\run-all.ps1` and `tests\install.tests.ps1`.
- Supports MCP protocol 2025-11-25.
- README rewritten for first-time users, with a screenshot, examples (`docs/EXAMPLES.md`) and troubleshooting.

## 1.2.0

- `aspen_describe_inputs`: Aspen's help text and allowed values for every input field.
- Kinetic reactors: `aspen_reactions` (power law) and `aspen_kinetic_reactor` (RCSTR, RPlug).
- `aspen_calculator` (Fortran) and calculator results.

## 1.1.0

- `aspen_radfrac`, `aspen_column_results`, `aspen_rstoic`, `aspen_design_spec`, `aspen_sensitivity`, `aspen_analysis_results`.
- Solids: `type: SOLID` components, CISOLID feeds and substream results; mass and std-volume feed flows.
- COM calls moved into a compiled helper, 10–20× faster on large flowsheets.
- `aspen_run` reports when Aspen skips a run for incomplete input.

## 1.0.0

- First release: session, variable tree, flowsheet building, run, results, screenshots and file tools; dialog watchdog; protected folders.

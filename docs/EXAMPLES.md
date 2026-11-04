# Examples

Each example is a prompt you can give Claude, followed by the tool calls it typically leads to. You don't need to name the tools; Claude picks them. The numbers come from the test suites, run on Aspen Plus V14 in the METCBAR unit set.

## 1. A heater, from nothing

> Start a new simulation with water and methanol using NRTL. Feed 80 kmol/h water and 20 kmol/h methanol at 25 °C and 1.5 bar into a heater that takes it to 60 °C at 1.2 bar. Run it and tell me the duty.

1. `aspen_new`, then `aspen_add_components` `["WATER", "MEOH=METHANOL"]`, then `aspen_set_property_method` `NRTL`.
2. `aspen_add_stream` FEED and OUT, plus a heat stream Q1; `aspen_add_block` H1 `Heater`; `aspen_connect` on `F(IN)`, `P(OUT)` and `HS(OUT)`.
3. `aspen_set_stream` FEED; `aspen_set` H1's `SPEC_OPT=TP`, `TEMP=60` and `PRES=1.2` (Claude finds these keys with `aspen_describe_inputs`).
4. `aspen_run`, then `aspen_block_results` H1, which gives `QCALC` with its units.

## 2. A distillation column, a purity target and a sensitivity study

> Add a 15-stage column (total condenser, feed on stage 8, 1.013 bar, reflux ratio 1.5, D/F 0.4) for 60 kmol/h water and 40 kmol/h methanol. Then make the distillate 99 mol% methanol by adjusting the reflux ratio. Finally, show reboiler duty and purity for reflux ratios 1 to 3.

- `aspen_radfrac` with `stages`, `condenser`, `feed_stages {"F": 8}`, `pressure`, and `specs {"reflux_ratio": 1.5, "distillate_to_feed": 0.4}`.
- `aspen_column_results` with `components ["MEOH", "WATER"]` gives the duties, the ratios and a stage-by-stage T/P/L/V/x/y profile.
- `aspen_design_spec` DS-1:
  - measured variable `XD` = mole fraction of MEOH in stream D;
  - target 0.99;
  - adjusts the reflux ratio (`BLOCK-VAR` C1 `COL-SPECS` `MOLE-RR`) between 0.5 and 10.
  - Result: XD = 0.99000 at a reflux ratio of 1.671.
- `aspen_delete` the design spec, then `aspen_sensitivity` S-1, varying the reflux ratio from 1 to 3 in 3 points and tabulating `REB-DUTY` and XD. Results come back from `aspen_analysis_results`. Aspen adds the base case as an extra row.

## 3. Reactors: fixed conversion and kinetics

> Ethanol and acetic acid react to ethyl acetate and water. First model it as 60 % conversion of acid in an RStoic at 70 °C. Then use power-law kinetics (k = 1e-5, E = 0, first order in each reactant) in a 1 m³ CSTR and a 5 m × 0.5 m plug-flow reactor, and compare the conversions.

- `aspen_rstoic` with `reactions [{"reactants": {"ETOH": 1, "ACID": 1}, "products": {"ETAC": 1, "WATER": 1}, "conversion": 0.6, "key": "ACID"}]` gives 6 kmol/h of ETAC from 10 kmol/h.
- `aspen_reactions` R-1 with `k`, `E` and `phase "L"`; the exponents default to the reactant coefficients.
- `aspen_kinetic_reactor`, once for the RCSTR (`volume 1000`, in litres in METCBAR) and once for the RPlug (`length 5`, `diameter 0.5`).
- Results: the CSTR converts 16.8 % and the plug-flow reactor 19.2 %, as second-order kinetics predict.

## 4. A calculator block

> Before the heater runs, set the acetic acid in its feed to twice the ethanol flow.

- `aspen_calculator` C-1:
  - define `FE` (MOLE-FLOW of ETOH in F3) and `FA` (MOLE-FLOW of ACID in F3);
  - read `FE`, write `FA`;
  - Fortran `FA = 2.0 * FE`;
  - `when BEFORE`, `block H1`.
- `aspen_analysis_results` C-1 shows FE read as 10 and FA written as 20 kmol/h.

## 5. Working with an existing model

> Open C:\work\plant.bkp (protected folder). List the columns and their reboiler duties, then show me the flowsheet.

- `aspen_open` makes a copy in the workspace. The original is never touched; saving into a protected folder is refused.
- `aspen_flowsheet` gives every block with its model; then `aspen_column_results` or `aspen_block_results` for each column.
- `aspen_screenshot` returns a picture of the live window.

## 6. Any other model

> I need a Flash2 at 40 °C and 2 bar, and a pump to 10 bar with 70 % efficiency.

- `aspen_add_block` with `Flash2` and `Pump`.
- `aspen_describe_inputs` with a filter such as `spec|temp|pres|eff`. It returns each field's help text and allowed values, for example `SPEC_OPT` with options TP, TV, PV, PD …
- `aspen_set` with the fields it found.

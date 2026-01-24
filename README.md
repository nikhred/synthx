# synthx
Vivado out-of-context synth/impl/bit generation driven by a simple YAML config. Use the `synthx` CLI for all workflows.

## CLI
Install and use the `synthx` console script. It reads a YAML config and can queue multiple runs with different generics.

``` bash
# Run builds from YAML
synthx run examples/build.yaml

# Force rebuild (ignore up-to-date checks)
synthx run examples/build.yaml --force

# Print version
synthx version

# Create a starter YAML in current directory
synthx init --file build.yaml

# Summarize utilization across runs (auto-detects utilization_impl/synth/bts reports)
# Adds Fmax (MHz) using timing_metrics.json produced by Vivado
synthx report --root examples/build
```

``` yaml
tool: vivado
board: xczu7ev-ffvc1156-2-e
runs:
  - top: add2
    clk: 4.0
    files:
      - operators.sv
  - top: increment_by_n
    clk: 4.0
    files:
      - operators.sv
    generics: 
      DW: 8
      N: 8
```

## Build Directory Behavior
- Default build root is `<yaml_dir>/build`.
- Override with `--out-dir` (relative paths are resolved against the YAML directory).
- Or set `SYNTHX_OUT_DIR` env var (used if `--out-dir` not provided).
- Per-run outputs are placed in subdirectories like `<top>[_k<v>...]`, sanitized for CI-friendly names.
- All artifacts (Vivado logs, reports, checkpoints, bitstreams) are kept under the chosen build root.

## Incremental Rebuilds
- synthx tracks each run with a small manifest containing input file timestamps/sizes and key options (flow, board, generics, clk, Vivado path).
- If nothing has changed and a previous `done` marker exists, the run is skipped as up-to-date.
- Use `--force` to rebuild regardless of manifest state.

## Notes
- Tcl scripts are packaged and used internally by the CLI; direct Tcl usage is not required.
- Select Vivado binary with `--vivado` or `VIVADO` env var.
- Parallelism: `--jobs` (default `min(4, CPU cores)`).
- Flow override: `--flow {synth,impl,bts,prj,sim}`.

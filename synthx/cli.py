import argparse
import os
import sys
from .runner import run_from_yaml
from . import __version__
from tabulate import tabulate

def _cmd_version() -> int:
    print(__version__)
    return 0


def _write_template_yaml(path: str) -> None:
    template = """tool: vivado
board: xczu7ev-ffvc1156-2-e
runs:
  - top: my_top
    clk: 4.0
    files:
      - path/to/top.sv
    # generics:
    #   DW: 8
"""
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w") as f:
        f.write(template)


def _parse_utilization_file(filepath: str):
    try:
        with open(filepath, "r") as f:
            lines = [line.strip() for line in f.readlines()]
    except Exception:
        return None, None
    design_name = None
    for line in lines:
        if "| Design       :" in line:
            parts = line.split(":")
            if len(parts) >= 2:
                design_name = parts[1].strip()
                break
    if not design_name:
        return None, None
    table_start = None
    for i, line in enumerate(lines):
        if line.startswith("1. Utilization by Hierarchy"):
            for j in range(i, len(lines)):
                if lines[j].startswith("+"):
                    table_start = j
                    break
            if table_start:
                break
    if not table_start:
        return None, None
    header_line = None
    for j in range(table_start + 1, len(lines)):
        if "|" in lines[j]:
            header_line = lines[j]
            break
    if not header_line:
        return None, None
    headers = [cell.strip() for cell in header_line.split("|")[1:-1]]
    data_rows = []
    in_data = False
    for line in lines[table_start + 2 :]:
        if line.startswith("+"):
            if in_data:
                break
            else:
                in_data = True
                continue
        if in_data and "|" in line:
            row = [cell.strip() for cell in line.split("|")[1:-1]]
            data_rows.append(row)
    instance_col = headers.index("Instance") if "Instance" in headers else -1
    if instance_col == -1:
        return None, None
    top_row = None
    for row in data_rows:
        if len(row) > instance_col and row[instance_col] == design_name:
            top_row = row
            break
    if not top_row:
        return None, None
    return headers, top_row


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="synthx", description="Vivado OOC synth/sim runner")
    sub = p.add_subparsers(dest="cmd", required=True)

    prun = sub.add_parser("run", help="Run builds from a YAML config")
    prun.add_argument("config", help="Path to YAML config file")
    prun.add_argument("--jobs", "-j", type=int, default=None, help="Parallel jobs (default: min(4, CPU cores))")
    prun.add_argument("--flow", choices=["synth", "impl", "bts", "prj", "sim"], default=None, help="Override flow for all runs")
    prun.add_argument("--out-dir", default=None, help="Build root directory. Relative paths resolved against YAML dir.")
    prun.add_argument("--vivado", default=os.environ.get("VIVADO", "vivado"), help="Vivado executable path")
    prun.add_argument("--force", action="store_true", help="Force rebuild even if up-to-date")

    pver = sub.add_parser("version", help="Print synthx version")

    pinit = sub.add_parser("init", help="Create a starter YAML config")
    pinit.add_argument("--file", default="build.yaml", help="Path to write the YAML template")

    prep = sub.add_parser("report", help="Summarize utilization from build outputs")
    prep.add_argument("--root", default=".", help="Root directory to scan (looks for utilization_*.txt under it)")
    prep.add_argument("--csv", default=None, help="Optional CSV output path")

    return p


def main(argv=None) -> int:
    argv = argv or sys.argv[1:]
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.cmd == "run":
        return run_from_yaml(
            config_path=args.config,
            jobs=args.jobs,
            flow_override=args.flow,
            out_dir=args.out_dir,
            vivado=args.vivado,
            force=args.force,
        )
    if args.cmd == "version":
        return _cmd_version()
    if args.cmd == "init":
        _write_template_yaml(args.file)
        print(f"Wrote template YAML to {args.file}")
        return 0
    if args.cmd == "report":
        # Walk root for mode-suffixed utilization files; prefer impl > synth > bts
        results = []
        headers_out = None
        pref = ["utilization_impl.txt", "utilization_synth.txt", "utilization_bts.txt"]
        for root, dirs, files in os.walk(args.root):
            chosen = None
            for name in pref:
                if name in files:
                    chosen = os.path.join(root, name)
                    break
            if not chosen:
                continue
            headers, top_row = _parse_utilization_file(chosen)
            if headers and top_row:
                if headers_out is None:
                    headers_out = ["Directory"] + headers
                results.append([os.path.basename(root)] + top_row)
        if not results:
            print("No utilization data found.")
            return 1
        # Sort by Module column if present, else by Directory
        sort_idx = 0  # Directory
        if headers_out:
            try:
                sort_idx = headers_out.index("Directory")
            except ValueError:
                try:
                    sort_idx = headers_out.index("Instance")
                except ValueError:
                    sort_idx = 0
        results.sort(key=lambda r: str(r[sort_idx]).lower())

        print(tabulate(results, headers=headers_out, tablefmt="grid"))
        if args.csv:
            try:
                import csv

                with open(args.csv, "w", newline="") as f:
                    writer = csv.writer(f)
                    writer.writerow(headers_out)
                    writer.writerows(results)
                print(f"Wrote CSV to {args.csv}")
            except Exception as e:
                print(f"Failed writing CSV: {e}", file=sys.stderr)
                return 2
        return 0

    parser.error("Unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

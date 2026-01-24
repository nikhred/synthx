import os
import re
import sys
import yaml
import shlex
import subprocess
import json
from multiprocessing import Pool, cpu_count
from importlib import resources


def _read_yaml(file_path: str) -> dict:
    with open(file_path, "r") as f:
        return yaml.safe_load(f)


def _tcl_path(name: str) -> str:
    # Return an absolute path to a packaged TCL file (from synthx/tcl)
    with resources.path("synthx.tcl", name) as p:
        return str(p)


def _build_root(config_path: str, out_dir_arg: str | None) -> str:
    ydir = os.path.dirname(os.path.abspath(config_path))
    if out_dir_arg:
        return os.path.abspath(os.path.join(ydir, out_dir_arg)) if not os.path.isabs(out_dir_arg) else out_dir_arg
    env = os.environ.get("SYNTHX_OUT_DIR")
    if env:
        return os.path.abspath(os.path.join(ydir, env)) if not os.path.isabs(env) else env
    return os.path.join(ydir, "build")


def _write_f(file_list: list[str], out_root: str, outdir: str) -> None:
    d = os.path.join(out_root, outdir)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "synth.f"), "w") as f:
        for path in file_list:
            f.write(path + "\n")


def _sanitize_name(s: str) -> str:
    # Lowercase, replace invalid chars with '-'
    s = s.lower()
    return re.sub(r"[^a-z0-9._-]", "-", s)


def _format_generics(gen: dict | None) -> tuple[str, str]:
    if not gen:
        return "", ""
    args = []
    suffix = []
    for k, v in gen.items():
        args.append(f"-generic {k}={v}")
        sval = str(v)
        sval = _sanitize_name(sval)
        suffix.append(f"_{k.lower()}{sval}")
    return " ".join(args), "".join(suffix)


def _run_cmd(cmd: list[str], cwd: str) -> int:
    p = subprocess.run(cmd, cwd=cwd)
    return p.returncode


def _vivado_ok(vivado: str) -> bool:
    try:
        p = subprocess.run([vivado, "-version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return p.returncode == 0
    except FileNotFoundError:
        return False


def _stat_map(paths: list[str]) -> dict[str, list]:
    out: dict[str, list] = {}
    for p in paths:
        try:
            st = os.stat(p)
            out[p] = [st.st_mtime, st.st_size]
        except FileNotFoundError:
            out[p] = [0.0, -1]
    return out


def _manifest_path(out_dir: str) -> str:
    return os.path.join(out_dir, "build_manifest.json")


def _load_manifest(path: str) -> dict | None:
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return None


def _save_manifest(path: str, data: dict) -> None:
    try:
        with open(path, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
    except Exception:
        pass


def _is_up_to_date(ctx: dict, run: dict, out_arg: str, tcl_path: str) -> bool:
    done = os.path.join(out_arg, "done")
    if not os.path.isfile(done):
        return False
    current = {
        "version": 1,
        "board": ctx["board"],
        "flow_override": ctx["flow_override"],
        "vivado": ctx["vivado"],
        "run": {
            "top": run.get("top"),
            "clk": run.get("clk"),
            "generics": run.get("generics", {}),
            "flow": run.get("flow"),
        },
    }
    files_rel = run.get("files", [])
    files_abs = [os.path.join(ctx["ydir"], f) for f in files_rel]
    current["files"] = _stat_map(files_abs)
    current["tcl"] = _stat_map([tcl_path])

    mpath = _manifest_path(out_arg)
    prev = _load_manifest(mpath)
    return prev == current


def _build_one_task(task: tuple[dict, dict]) -> tuple[str, int]:
    ctx, run = task
    ydir = ctx["ydir"]
    board = ctx["board"]
    out_root = ctx["out_root"]
    flow_override = ctx["flow_override"]
    vivado = ctx["vivado"]
    force = ctx.get("force", False)

    top = run["top"]
    clk = str(run["clk"])
    files_rel = run.get("files", [])
    files_abs = [os.path.join(ydir, f) for f in files_rel]
    missing = [f for f in files_abs if not os.path.isfile(f)]
    if missing:
        print(f"Missing files for top={top}: {missing}", file=sys.stderr)
        return top, 2

    gen = run.get("generics")
    gen_args, suffix = _format_generics(gen)
    outdir = _sanitize_name(top + suffix)

    _write_f(files_abs, out_root, outdir)

    flow = flow_override or run.get("flow", "impl")
    tcl = _tcl_path("vivado.tcl")
    out_arg = os.path.join(out_root, outdir)
    # Up-to-date check
    if not force and _is_up_to_date(ctx, run, out_arg, tcl):
        print(f"[synthx] Skipping {top}: up-to-date")
        return top, 0
    cmd = [
        vivado,
        "-mode",
        "batch",
        "-source",
        tcl,
        "-journal",
        os.path.join(out_arg, "vivado.jou"),
        "-log",
        os.path.join(out_arg, "vivado.log"),
        "-tclargs",
        "-clk",
        clk,
        "-part",
        board,
        "-top",
        top,
        "-out",
        out_arg,
        "-synth",
        gen_args,
        "-run",
        flow,
    ]
    rc = _run_cmd(cmd, cwd=ydir)
    # Save manifest only on success
    if rc == 0:
        manifest = {
            "version": 1,
            "board": board,
            "flow_override": flow_override,
            "vivado": vivado,
            "run": {
                "top": top,
                "clk": clk,
                "generics": gen or {},
                "flow": run.get("flow"),
            },
            "files": _stat_map(files_abs),
            "tcl": _stat_map([tcl]),
        }
        _save_manifest(_manifest_path(out_arg), manifest)
    return top, rc


def run_from_yaml(config_path: str, jobs: int | None, flow_override: str | None, out_dir: str | None, vivado: str, force: bool = False) -> int:
    data = _read_yaml(config_path)
    ydir = os.path.dirname(os.path.abspath(config_path))

    board = data.get("board")
    if not board:
        print("Error: 'board' missing in YAML", file=sys.stderr)
        return 2

    flow_default = data.get("tool", "vivado")
    if flow_default != "vivado":
        print("Error: only 'vivado' is supported currently", file=sys.stderr)
        return 2

    runs = data.get("runs", [])
    if not runs:
        print("No runs found in YAML", file=sys.stderr)
        return 1

    out_root = _build_root(config_path, out_dir)

    # Preflight Vivado
    if not _vivado_ok(vivado):
        print(
            f"Vivado not found or not runnable at '{vivado}'. Set --vivado or VIVADO env to the Vivado binary.",
            file=sys.stderr,
        )
        return 2

    n = jobs or min(4, cpu_count())
    results: list[tuple[str, int]] = []
    if n > 1 and len(runs) > 1:
        ctx = {
            "ydir": ydir,
            "board": board,
            "out_root": out_root,
            "flow_override": flow_override,
            "vivado": vivado,
            "force": force,
        }
        tasks = [(ctx, r) for r in runs]
        with Pool(processes=n) as pool:
            results = pool.map(_build_one_task, tasks)
    else:
        ctx = {
            "ydir": ydir,
            "board": board,
            "out_root": out_root,
            "flow_override": flow_override,
            "vivado": vivado,
            "force": force,
        }
        for r in runs:
            results.append(_build_one_task((ctx, r)))

    failures = [(t, rc) for t, rc in results if rc != 0]
    if failures:
        print("Some runs failed:")
        for t, rc in failures:
            print(f" - {t}: rc={rc}")
        return 2
    return 0

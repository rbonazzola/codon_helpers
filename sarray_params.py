#!/usr/bin/env python3
"""
sarray_params — submit one SLURM array job per row of a parameter file.

Each row becomes one array task; column names map to CLI argument names of
the target script. Supports grid expansion (Cartesian product over parameter
values) and Google Sheets as input.
"""

import argparse
import csv
import itertools
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path


# Job script executed on each compute node.
# SCRIPT, PARAMS_FILE, SEP, AWK_SEP, FIXED_ARGS are injected via --export.
_JOB_SCRIPT = r"""#!/bin/bash
header=$(head -n1 "$PARAMS_FILE" | tr -d '\r')
IFS="$SEP" read -r -a cols <<< "$header"

line=$(awk -F"$AWK_SEP" -v i=$SLURM_ARRAY_TASK_ID 'NR==i+1' "$PARAMS_FILE" | tr -d '\r')
IFS="$SEP" read -r "${cols[@]}" <<< "$line"

args=()
for col in "${cols[@]}"; do
    val=$(echo "${!col}" | xargs)
    if [ -n "$val" ]; then
        if [ "$val" = "True" ] || [ "$val" = "true" ]; then
            args+=("--$col")
        elif [ "$val" = "False" ] || [ "$val" = "false" ]; then
            :
        else
            args+=("--$col" "$val")
        fi
    fi
done

echo "Running: python $SCRIPT ${args[*]} $FIXED_ARGS"
python "$SCRIPT" "${args[@]}" $FIXED_ARGS
"""


def expand_line_spec(spec):
    """Expand '1-5,8,10-12' → [1, 2, 3, 4, 5, 8, 10, 11, 12]."""
    result = []
    for part in spec.split(','):
        part = part.strip()
        if '-' in part:
            s, e = part.split('-', 1)
            result.extend(range(int(s), int(e) + 1))
        else:
            result.append(int(part))
    return result


def expand_grid_values(vals_str):
    """Expand '1-5;7' → ['1','2','3','4','5','7']. Non-numeric parts are kept as-is."""
    result = []
    for part in vals_str.split(';'):
        part = part.strip()
        if re.match(r'^\d+-\d+$', part):
            s, e = part.split('-', 1)
            result.extend(str(i) for i in range(int(s), int(e) + 1))
        else:
            result.append(part)
    return result


def detect_sep(path):
    return ',' if str(path).endswith('.csv') else '\t'


def awk_sep_for(sep):
    if len(sep) == 1:
        return f'[{sep}]'
    return re.sub(r'([]\\^$.|?*+(){}[])', r'\\\1', sep)


def download_gsheet(url):
    sheet_id = re.search(r'/d/([^/?#]+)', url)
    gid = re.search(r'gid=(\d+)', url)
    if not sheet_id:
        raise ValueError(f"Cannot extract sheet ID from: {url}")
    sheet_id = sheet_id.group(1)
    gid = gid.group(1) if gid else '0'
    tsv_url = (
        f"https://docs.google.com/spreadsheets/d/{sheet_id}"
        f"/export?format=tsv&gid={gid}"
    )
    dest = Path(f".gsheet_{sheet_id}_{gid}.tsv")
    print(f"Downloading Google Sheet → {dest}")
    with urllib.request.urlopen(tsv_url) as resp:
        content = resp.read()
    if content.lstrip().startswith(b'<'):
        raise RuntimeError("Received HTML — is the sheet shared publicly?")
    dest.write_bytes(content)
    return dest


def read_params(path, sep):
    with open(path, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f, delimiter=sep)
        headers = list(reader.fieldnames or [])
        rows = [dict(r) for r in reader]
    # Strip \r from all values (CRLF files)
    rows = [{k: (v or '').strip('\r') for k, v in r.items()} for r in rows]
    return headers, rows


def expand_grid(headers, rows, grid_specs):
    """
    grid_specs: list of (key, [val1, val2, ...]) tuples.
    Returns (new_headers, new_rows) with one row per original × combo.
    Order: for each combo, all original rows (combos vary slowest).
    """
    new_cols = [k for k, _ in grid_specs if k not in headers]
    new_headers = headers + new_cols

    combos = list(itertools.product(*[vals for _, vals in grid_specs]))
    keys = [k for k, _ in grid_specs]

    new_rows = []
    for combo in combos:
        override = dict(zip(keys, combo))
        for row in rows:
            new_row = {**row, **override}
            new_rows.append(new_row)

    return new_headers, new_rows


def row_to_args(row, headers):
    args = []
    for col in headers:
        val = (row.get(col) or '').strip()
        if not val:
            continue
        if val.lower() == 'true':
            args.append(f'--{col}')
        elif val.lower() == 'false':
            pass
        else:
            args += [f'--{col}', val]
    return args


def write_tsv(path, headers, rows, sep):
    with open(path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(
            f, fieldnames=headers, delimiter=sep, extrasaction='ignore'
        )
        writer.writeheader()
        writer.writerows(rows)


def build_log_pattern(log_dir, log_prefix, job_name):
    parts = []
    if log_dir:
        parts.append(log_dir.rstrip('/') + '/')
    if log_prefix:
        parts.append(log_prefix + '_')
    if job_name:
        parts.append('%x_')
    parts.append('slurm-%A_%a.out')
    return ''.join(parts)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('script', help='Python script to run')
    parser.add_argument('params', help='TSV/CSV parameter file or Google Sheets URL')
    parser.add_argument('--dry-run', '--dryrun', '--dry_run',
                        dest='dry_run', action='store_true',
                        help='Print commands without submitting')
    parser.add_argument('--lines', default=None,
                        help='Row selection, 1-based (e.g. 1-5,8,10-12)')
    parser.add_argument('--sep', default=None,
                        help='Column separator (default: auto-detect from extension)')
    parser.add_argument('--grid', action='append', default=[],
                        metavar='KEY=V1;V2;...',
                        help='Replicate each row for each value of KEY, '
                             'semicolon-separated. Repeatable; multiple --grid '
                             'args produce the Cartesian product.')
    parser.add_argument('--time', default='09:00:00', help='Wall time (HH:MM:SS)')
    parser.add_argument('--mem', default='64G', help='Memory per job')
    parser.add_argument('--cpus', default='8', help='CPUs per job')
    parser.add_argument('--gpus', default=None, help='Number of GPUs')
    parser.add_argument('--gpu-type', dest='gpu_type', default=None,
                        help='GPU model (e.g. a100)')
    parser.add_argument('--max-parallel', dest='max_parallel', default=None,
                        type=int, help='Max simultaneously running array tasks')
    parser.add_argument('--log-dir', dest='log_dir', default=None,
                        help='Directory for SLURM log files')
    parser.add_argument('--log-prefix', dest='log_prefix', default=None,
                        help='Prefix for SLURM log filenames')
    parser.add_argument('--yes', '-y', action='store_true',
                        help='Skip confirmation prompt and submit immediately')

    args, fixed_args = parser.parse_known_args()

    # ── Load params ──────────────────────────────────────────────────────────
    params_path = args.params
    if params_path.startswith('https://docs.google.com/spreadsheets/'):
        params_path = str(download_gsheet(params_path))

    sep = args.sep if args.sep else detect_sep(params_path)
    headers, rows = read_params(params_path, sep)

    if not rows:
        print(f"Error: {params_path} has no data rows", file=sys.stderr)
        sys.exit(1)

    # ── Grid expansion ───────────────────────────────────────────────────────
    grid_tmp = None
    if args.grid:
        grid_specs = []
        for spec in args.grid:
            key, _, vals_str = spec.partition('=')
            grid_specs.append((key.strip(), expand_grid_values(vals_str)))

        n_orig = len(rows)
        n_combos = 1
        for _, vals in grid_specs:
            n_combos *= len(vals)

        headers, rows = expand_grid(headers, rows, grid_specs)
        print(f"Grid expansion: {n_combos} combo(s) × {n_orig} row(s) = {len(rows)} jobs")

        grid_tmp = Path(f'.sarray_grid_{os.getpid()}.tsv')
        write_tsv(grid_tmp, headers, rows, sep)
        params_path = str(grid_tmp)

    n = len(rows)
    array_spec = args.lines or f'1-{n}'
    max_parallel_str = f'%{args.max_parallel}' if args.max_parallel else ''

    # ── Dry-run ──────────────────────────────────────────────────────────────
    if args.dry_run:
        line_nums = expand_line_spec(array_spec)
        print(f'[Dry-run] {len(line_nums)} jobs would be generated (lines: {array_spec}):')
        for i in line_nums:
            row = rows[i - 1]
            cli_args = row_to_args(row, headers)
            print('python', args.script, *cli_args, *fixed_args)
        if grid_tmp:
            grid_tmp.unlink(missing_ok=True)
        return

    # ── Job name from experiment_name column ─────────────────────────────────
    job_name = ''
    if not args.log_prefix and 'experiment_name' in headers:
        first = expand_line_spec(array_spec)[0] - 1
        job_name = (rows[first].get('experiment_name') or '').strip()

    # ── Confirmation prompt ──────────────────────────────────────────────────
    if not args.yes:
        n_selected = len(expand_line_spec(array_spec))
        gpu_summary = ''
        if args.gpus:
            gpu_summary = f", {args.gpus}× {args.gpu_type or 'GPU'}"
        print(f"\n  Script  : {args.script}")
        print(f"  Params  : {params_path}")
        print(f"  Jobs    : {n_selected}  (array: {array_spec})")
        print(f"  Resources: {args.time}, {args.mem} RAM, {args.cpus} CPUs{gpu_summary}")
        if fixed_args:
            print(f"  Fixed   : {' '.join(fixed_args)}")
        print()
        try:
            answer = input("Submit? [y/N] ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.")
            if grid_tmp:
                grid_tmp.unlink(missing_ok=True)
            return
        if answer not in ('y', 'yes'):
            print("Aborted.")
            if grid_tmp:
                grid_tmp.unlink(missing_ok=True)
            return

    # ── sbatch ───────────────────────────────────────────────────────────────
    log_pattern = build_log_pattern(args.log_dir, args.log_prefix, job_name)

    gpu_args = []
    if args.gpus:
        gres = (
            f"gpu:{args.gpu_type}:{args.gpus}" if args.gpu_type
            else f"gpu:{args.gpus}"
        )
        gpu_args = [f'--gres={gres}']

    awk_sep = awk_sep_for(sep)
    fixed_args_str = ' '.join(fixed_args)

    sbatch_cmd = [
        'sbatch',
        f'--output={log_pattern}',
        *([ f'--job-name={job_name}' ] if job_name else []),
        f'--array={array_spec}{max_parallel_str}',
        f'--time={args.time}',
        f'--mem={args.mem}',
        '-c', args.cpus,
        *gpu_args,
        (
            f'--export=ALL'
            f',SCRIPT={args.script}'
            f',PARAMS_FILE={params_path}'
            f',SEP={sep}'
            f',AWK_SEP={awk_sep}'
            f',FIXED_ARGS={fixed_args_str}'
        ),
    ]

    result = subprocess.run(sbatch_cmd, input=_JOB_SCRIPT.encode())

    if grid_tmp:
        grid_tmp.unlink(missing_ok=True)

    sys.exit(result.returncode)


if __name__ == '__main__':
    main()

# codon_helpers

Utilities for SLURM job submission on the Codon cluster.

## Files

- `sarray_params.py` — main Python script, all logic lives here
- `slurm_functions.sh` — bash wrapper: `source` this to get `sarray_params` as a shell function
- `README.md` — user-facing documentation

## `sarray_params`

Submits a SLURM job array where each row of a TSV/CSV becomes one task.
Column names in the file map to CLI argument names of the target script.
Extra args passed after the file are forwarded verbatim to every job.

### Architecture

The bash function in `slurm_functions.sh` is a one-liner that delegates to
`sarray_params.py`. All logic is in Python:

1. Parse arguments (argparse; unknown args → `fixed_args` forwarded to jobs)
2. Download Google Sheet if URL given
3. Read TSV/CSV with `csv.DictReader`
4. Grid expansion (optional): compute Cartesian product, write expanded TSV to
   `$PWD/.sarray_grid_<pid>.tsv` (shared FS, readable by compute nodes)
5. Dry-run: print commands and exit
6. Submit: call `sbatch` via `subprocess.run`, passing the job script via stdin

The job script (string constant `_JOB_SCRIPT` in the Python file) runs on
compute nodes. It reads its row from `PARAMS_FILE` using `SLURM_ARRAY_TASK_ID`,
builds CLI args, and calls `python $SCRIPT`.

### Grid expansion

`--grid KEY=V1;V2;...` (semicolon-separated values). Multiple `--grid` args
produce the Cartesian product. Expansion order: for each combo, all original
rows are emitted in sequence. `--lines` applies to the expanded result.

If KEY already exists as a column, its value is overridden per row.
If KEY is new, it is appended as an extra column.

The temp expanded TSV is deleted after `sbatch` returns (or after dry-run).

### Key implementation notes

- `parse_known_args` is used so unrecognised flags go to `fixed_args` and are
  forwarded to every job via `FIXED_ARGS` env var in `--export`.
- **Precedence:** extra (fixed) args > `--grid` values > TSV column values.
  Fixed args win because they appear last in the job command (`python $SCRIPT
  ${args[@]} $FIXED_ARGS`) and argparse last-write-wins. Grid values win over
  TSV because `expand_grid` does `{**row, **override}` (override is the grid).
- The job script uses `IFS="$SEP" read -r "${cols[@]}"` to assign each TSV
  field to a bash variable named after the column — this is how column values
  become CLI args on the compute node.
- Google Sheets are downloaded to `$PWD/.gsheet_<id>_<gid>.tsv` so the file
  is on the shared FS and accessible from compute nodes.
- `--max-parallel N` maps to SLURM's `%N` throttle syntax appended to `--array`.

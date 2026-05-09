# Helpers for Codon cluster

## `sarray_params`

Submits a SLURM job array where each row of a parameter file becomes one job.
Column names map directly to CLI argument names of the target script.

Implemented in `sarray_params.py` (Python); `slurm_functions.sh` provides a
bash wrapper so it can be called after `source slurm_functions.sh`.

### Setup

```bash
source slurm_functions.sh
```

### Usage

```bash
sarray_params <script.py> <params.tsv | google-sheets-url> [options] [extra args]
```

`extra args` are forwarded verbatim to every job (constant across the array).

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` | — | Print the command each job would run without submitting |
| `--lines=SPEC` | all rows | Run only selected rows (1-based, SLURM syntax: `3`, `1-5`, `1-3,7,10-12`) |
| `--grid KEY=V1;V2;...` | — | Replicate each row for each value of KEY (semicolon-separated). Repeatable; multiple `--grid` args produce the Cartesian product. `--lines` applies to the expanded result. |
| `--time=HH:MM:SS` | `09:00:00` | Wall-clock time limit |
| `--mem=XXG` | `64G` | Memory per job |
| `--cpus=N` | `8` | CPUs per job |
| `--gpus=N` | — | Number of GPUs |
| `--gpu-type=TYPE` | — | GPU model (`a100`, `v100`, `h200`, …) |
| `--max-parallel=N` | — | Max simultaneously running array tasks |
| `--log-dir=DIR` | current dir | Directory for `slurm-%A_%a.out` log files |
| `--log-prefix=PFX` | — | Prefix added to log filenames |
| `--sep=SEP` | auto | Column separator (auto-detected: `.csv` → `,`, otherwise tab) |
| `--yes` / `-y` | — | Skip confirmation prompt and submit immediately |

### Parameter file format

A TSV (or CSV) with a header row. Column names must match CLI arguments of the script.

```
learning_rate	n_embd	batch_size
0.0001	256	32
0.001	256	32
0.0001	128	64
0.001	128	64
```

```bash
sarray_params train.py params.tsv --time=12:00:00 --mem=32G --gpus=1 --gpu-type=a100
# → submits 4 jobs
```

**Special cell values:**
- Empty cell → argument is omitted (script default applies)
- `True` / `true` → flag with no value (e.g. `--use_amp`)
- `False` / `false` → argument omitted entirely

**Parameter precedence (highest to lowest):**
1. Extra args passed directly on the command line (after the TSV path)
2. `--grid` values
3. TSV column values

Extra args are appended after TSV-derived args in the job command, so argparse
sees them last and they win. `--grid` overrides TSV column values at expansion
time (the expanded TSV already contains the grid value in that column).

**Auto job name:** if the file has an `experiment_name` column, SLURM uses its value as the job name (visible in `squeue`).

### Grid expansion

`--grid KEY=V1;V2;...` replicates every row once per value, using `;` as separator.
Ranges of integers are supported: `1-5` expands to `1;2;3;4;5`.
Multiple `--grid` args produce the full Cartesian product.

```bash
# 3 rows × 5 folds = 15 jobs
sarray_params train.py params.tsv --grid test_fold=1;2;3;4;5

# 3 rows × 5 folds × 3 seeds = 45 jobs
sarray_params train.py params.tsv \
    --grid test_fold=1;2;3;4;5 \
    --grid seed=42;123;456

# Preview the expansion
sarray_params train.py params.tsv --grid test_fold=1;2;3;4;5 --dry-run
```

Expansion order: for each combo in the Cartesian product, all original rows
are emitted in order. So with `--grid test_fold=1;2;3` and 2 original rows:

```
row 1 → test_fold=1
row 2 → test_fold=1
row 1 → test_fold=2
row 2 → test_fold=2
row 1 → test_fold=3
row 2 → test_fold=3
```

`--lines` applies to the **expanded** TSV (the script prints the total job
count after expansion so you know the index range).

If KEY is already a column in the TSV, its value is overridden. If it is new,
it is appended as an extra column.

### Google Sheets support

Pass the sharing URL directly instead of a local file. The sheet must be shared
as *"Anyone with the link can view"*. The sheet is downloaded as TSV to a hidden
file in the current directory (`.gsheet_<id>_<gid>.tsv`) so SLURM compute nodes
can read it.

Example sheet (5 CV folds for `train.py`):

```
test_fold   batch_size   block_size   auc    run_name
1           32           128          True   test_fold_1
2           32           128          True   test_fold_2
3           32           128          True   test_fold_3
4           32           128          True   test_fold_4
5           32           128          True   test_fold_5
```

```bash
# First sheet (default tab, gid=0)
sarray_params train.py \
  "https://docs.google.com/spreadsheets/d/15HfWjD0ACNyzfegEMZpnZ7dvG9J9PFzxv5fZZl38Jks/edit#gid=0" \
  --experiment_name my_experiment \
  --time=12:00:00 --mem=32G --gpus=1 --gpu-type=a100 --dry-run

# Second sheet: navigate to that tab in the browser — the gid appears in the URL
# e.g. edit#gid=1234567890
sarray_params train.py \
  "https://docs.google.com/spreadsheets/d/15HfWjD0ACNyzfegEMZpnZ7dvG9J9PFzxv5fZZl38Jks/edit#gid=1234567890" \
  --time=12:00:00 --mem=32G
```

For sheets with multiple tabs, navigate to the tab in your browser — the `gid`
in the URL identifies it and is picked up automatically.

### Examples

```bash
# Preview what would run for rows 1-3
sarray_params train.py params.tsv --dry-run --lines=1-3

# Submit only rows 2 and 5, at most 2 jobs running at once
sarray_params train.py params.tsv --lines=2,5 --max-parallel=2 --time=24:00:00 --mem=64G --gpus=1

# Pass a constant flag to every job
sarray_params train.py params.tsv --time=06:00:00 --no-compile --dryrun

# Grid over 5 CV folds using range syntax, dry-run first
sarray_params train.py params.tsv --grid test_fold=1-5 --dry-run
sarray_params train.py params.tsv --grid test_fold=1-5 --time=12:00:00 --mem=32G --gpus=1

# Mix ranges and individual values
sarray_params train.py params.tsv --grid test_fold=1-3;5;7
```

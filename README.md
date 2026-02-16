# Helpers for Codon cluster

Source `slurm_functions.sh` to use `sarray_params` in the following manner:

```bash
source slurm_functions.sh
sarray_params my_script.py params.tsv [--dry-run] [--time=HH:MM:SS] [--mem=XXG] [--cpus=N] [--gpus=N --gpu-type=v100|a100|h200] [--max-parallel=N] [extra args]
```

This command submits a SLURM job array with the following characteristics:
- Each job corresponds to a combination of parameters given by `params.tsv` (each row is one job). 
- Column names in this file must be command-line arguments of `my_script.py`.
- If for some row, the column is empty, then the corresponding argument is not passed (i.e. the default value is used for that argument).
- Use `--dry-run` to see what are the commands that will get executed in each job.
- `extra args` corresponds to additional arguments to `my_script.py` which will be constant across all jobs.

`params.tsv` needs to be generated beforehand.

Example:
```
learning_rate\tn_embd\tbatch_size
0.0001\t256\t32
0.001\t256\t32
0.0001\t128\t64
0.001\t128\t64
0.0001\t256\t64
0.001\t256\t64
```

And then `sarray_params.py train.py params.tsv` will submit 6 jobs (assuming `train.py` accepts `--learning_rate`, `--n_embd` and `--batch_size` as arguments).

## TODO
- Provide values to build a grid of parameters on-the-fly instead of creating the TSV file. For instance, `--from_grid learning_rate=0.0001,0.001 n_embd=128,256 batch_size=32,64` would create these 8 combinations without the need for the file.
- Option to choose specific rows from the file to be run (for instance, adding the option `--rows=1:4,8,12:13` would only run rows 1, 2, 3, 4, 8, 12 and 13).

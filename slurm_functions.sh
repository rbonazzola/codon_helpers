#!/bin/bash

# Submit one SLURM array job per row of a parameter file.
# Each row becomes one job; column names become CLI argument names.
# See sarray_params.py for full documentation.
sarray_params() {
    python "$(dirname "${BASH_SOURCE[0]}")/sarray_params.py" "$@"
}

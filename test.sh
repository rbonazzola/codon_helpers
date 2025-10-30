#!/bin/bash
set -e

source slurm_functions.sh 

DRYRUN=""

cat params.tsv
echo "-----------------------------------------------"

# -----------------------------------------------
echo "TEST 1: No GPU"
sarray_params dummy_test.py params.tsv $DRYRUN
echo "-----------------------------------------------"

# -----------------------------------------------
echo "TEST 2: --gpus=1"
sarray_params dummy_test.py params.tsv $DRYRUN --gpus=1
echo "-----------------------------------------------"

# -----------------------------------------------
echo "TEST 3: --gpus=2 --gpu-type=a100"
sarray_params dummy_test.py params.tsv $DRYRUN --gpus=2 --gpu-type=a100
echo "-----------------------------------------------"

echo "TEST 3: --gpus=2 --gpu-type=h200"
sarray_params dummy_test.py params.tsv $DRYRUN --gpus=1 --gpu-type=h200

# -----------------------------------------------
echo "TEST 4: --mem=8G --cpus=4"
sarray_params dummy_test.py params.tsv $DRYRUN --mem=8G --cpus=4

# -----------------------------------------------
echo "TEST 5: --max-parallel=3"
sarray_params dummy_test.py params.tsv $DRYRUN --max-parallel=3

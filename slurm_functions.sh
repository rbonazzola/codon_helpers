#!/bin/bash

sarray_params () {
    if [ $# -lt 2 ]; then
        echo "Usage: sarray_params <script.py> <params.tsv/csv> [--dry-run|--dryrun|--dry_run] [--time=HH:MM:SS] [--mem=XXG] [--cpus=N] [--gpus=N|--gpu-type=TYPE] [--max-parallel=N] [extra args]"
        return 1
    fi

    local script=$1
    local params=$2
    shift 2

    # Defaults
    local dryrun=0
    local slurm_time="01:00:00"
    local slurm_mem="4G"
    local slurm_cpus=1
    local max_parallel=""
    local fixed_args=()

    # Parse optional arguments
    for arg in "$@"; do
        case $arg in
            --dry-run|--dryrun|--dry_run)
                dryrun=1
                ;;
            --time=*)
                slurm_time="${arg#*=}"
                ;;
            --mem=*)
                slurm_mem="${arg#*=}"
                ;;
            --cpus=*)
                slurm_cpus="${arg#*=}"
                ;;
            --max-parallel=*)
                max_parallel="%${arg#*=}"
                ;;
            *)
                fixed_args+=("$arg")   # only non-slurm args end up here
                ;;
        esac
    done

    # Detect separator (TSV = tab, CSV = comma)
    local sep=$'\t'
    [[ $params == *.csv ]] && sep=','

    # Count number of rows excluding header
    local n=$(($(wc -l < "$params") - 1))
    if [ $n -le 0 ]; then
        echo "The file $params has no parameter rows"
        return 1
    fi

    if [ $dryrun -eq 1 ]; then
        echo "[Dry-run] $n jobs would be generated:"
        header=$(head -n1 "$params" | tr "$sep" ' ')
        for i in $(seq 1 $n); do
            line=$(awk -F"$sep" -v i=$i 'NR==i+1' "$params")
            args=""
            j=1
            for col in $header; do
                val=$(echo "$line" | awk -F"$sep" -v j=$j '{print $j}')
                args="$args --$col $val"
                j=$((j+1))
            done
            echo "python $script$args ${fixed_args[*]}"
        done
        return 0
    fi

    # Normal case: submit array job to Slurm
    sbatch --output=slurm-%A_%a.out \
           --array=1-$n$max_parallel \
           --time=$slurm_time \
           --mem=$slurm_mem \
           -c $slurm_cpus \
           --export=ALL,SCRIPT="$script",PARAMS_FILE="$params",SEP="$sep",FIXED_ARGS="${fixed_args[*]}" <<'EOF'
#!/bin/bash
# Extract header and corresponding line for this task
header=$(head -n1 "$PARAMS_FILE" | tr "$SEP" ' ')
line=$(awk -F"$SEP" -v i=$SLURM_ARRAY_TASK_ID 'NR==i+1' "$PARAMS_FILE")

# Build CLI arguments --col value
args=""
j=1
for col in $header; do
    val=$(echo "$line" | awk -F"$SEP" -v j=$j '{print $j}')
    args="$args --$col $val"
    j=$((j+1))
done

echo "Running: python $SCRIPT$args $FIXED_ARGS"
python "$SCRIPT" $args $FIXED_ARGS
EOF
}

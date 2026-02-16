#!/bin/bash

sarray_params () {
    if [ $# -lt 2 ]; then
        echo "Usage: sarray_params <script.py> <params.tsv/csv> [--dry-run] [--time=HH:MM:SS] [--mem=XXG] [--cpus=N] [--gpus=N|--gpu-type=TYPE] [--max-parallel=N] [extra args]"
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
    local slurm_gpus=""
    local slurm_gpu_type=""
    local max_parallel=""
    local fixed_args=()

    # Parse optional arguments
    for arg in "$@"; do
        case $arg in
            --dry-run|--dryrun|--dry_run)
                dryrun=1 ;;
            --time=*)
                slurm_time="${arg#*=}" ;;
            --mem=*)
                slurm_mem="${arg#*=}" ;;
            --cpus=*)
                slurm_cpus="${arg#*=}" ;;
            --gpus=*)
                slurm_gpus="${arg#*=}" ;;
            --gpu-type=*)
                slurm_gpu_type="${arg#*=}" ;;
            --max-parallel=*)
                max_parallel="%${arg#*=}" ;;
            *)
                fixed_args+=("$arg") ;;
        esac
    done

    # Detect separator
    local sep=$'\t'
    [[ $params == *.csv ]] && sep=','

    # Count rows (excluding header)
    local n=$(($(wc -l < "$params") - 1))
    if [ $n -le 0 ]; then
        echo "The file $params has no parameter rows"
        return 1
    fi

    # GPU args
    local gpu_args=""
    if [ -n "$slurm_gpus" ]; then
        gpu_args="--gres=gpu:${slurm_gpu_type:+${slurm_gpu_type}:}$slurm_gpus"
    fi

    if [ $dryrun -eq 1 ]; then
        echo "[Dry-run] $n jobs would be generated:"
        header=$(head -n1 "$params")
        IFS="$sep" read -r -a cols <<< "$header"
        
        tail -n +2 "$params" | while IFS="$sep" read -r "${cols[@]}"; do
            # 1. Usamos un array en lugar de un string
            args=()
            for col in "${cols[@]}"; do
                val="${!col}"
                # 2. Solo agregamos el flag si el valor no está vacío
                if [ -n "$val" ]; then
                    args+=("--$col" "$val")
                fi
            done
            # 3. Al imprimirlo, usamos "${args[@]}" para que respete los grupos
            echo "python $script" "${args[@]}" "${fixed_args[@]}"
        done
        return 0
    fi

    # Actual submission
    sbatch --output=slurm-%A_%a.out \
           --array=1-$n$max_parallel \
           --time=$slurm_time \
           --mem=$slurm_mem \
           -c $slurm_cpus \
           $gpu_args \
           --export=ALL,SCRIPT="$script",PARAMS_FILE="$params",SEP="$sep",FIXED_ARGS="${fixed_args[*]}" <<'EOF'
#!/bin/bash
header=$(head -n1 "$PARAMS_FILE")
IFS="$SEP" read -r -a cols <<< "$header"
line=$(awk -F"$SEP" -v i=$SLURM_ARRAY_TASK_ID 'NR==i+1' "$PARAMS_FILE")
IFS="$SEP" read -r "${cols[@]}" <<< "$line"

args=()
for col in "${cols[@]}"; do
    val=$(echo "${!col}" | xargs)
    if [ -n "$val" ]; then
        args+=("--$col" "$val")
    fi
done

echo "Running: python $SCRIPT" "${args[@]}" $FIXED_ARGS
python "$SCRIPT" "${args[@]}" $FIXED_ARGS
EOF
}

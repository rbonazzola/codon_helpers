#!/bin/bash

# Expands a SLURM-style line spec like "1-5,8,10-12" into individual integers.
# Used to enumerate which rows of the params file to preview in dry-run mode.
__sarray_expand_spec() {
    local spec=$1
    local result=()
    IFS=',' read -ra parts <<< "$spec"
    for part in "${parts[@]}"; do
        part="${part// /}"  # strip spaces around commas
        if [[ $part == *-* ]]; then
            # Range like "3-7": expand to 3 4 5 6 7
            local s=${part%-*} e=${part#*-}
            for ((i=s; i<=e; i++)); do result+=($i); done
        else
            # Single number
            result+=($part)
        fi
    done
    echo "${result[@]}"
}

# Submit one SLURM array job per row of a parameter file.
# Each row becomes one job; column names become CLI argument names.
# Usage: sarray_params <script.py> <params.tsv/csv> [options] [extra args passed to every job]
sarray_params () {
    if [ $# -lt 2 ]; then
        echo "Usage: sarray_params <script.py> <params.tsv/csv> [--dry-run] [--lines=SPEC] [--sep=SEP] [--time=HH:MM:SS] [--mem=XXG] [--cpus=N] [--gpus=N|--gpu-type=TYPE] [--max-parallel=N] [--log-dir=DIR] [extra args]"
        echo "  --lines=SPEC   Run only selected rows (1-based, e.g. 3, 1-5, 1-3,7,10-12)"
        echo "  --sep=SEP      Column separator (default: auto-detect from extension: .csv→',', else tab)"
        echo "  --log-dir=DIR    Directory for SLURM log files (default: current dir, pattern slurm-%A_%a.out)"
        echo "  --log-prefix=PFX Prefix for SLURM log filenames (e.g. myrun → myrun_slurm-%A_%a.out)"
        return 1
    fi

    local script=$1
    local params=$2
    shift 2

    # Default SLURM resource limits
    local dryrun=0
    local lines_spec=""
    local slurm_time="09:00:00"
    local slurm_mem="64G"
    local slurm_cpus=8
    local slurm_gpus=""
    local slurm_gpu_type=""
    local max_parallel=""
    local custom_sep=""
    local log_dir=""
    local log_prefix=""
    local fixed_args=()   # arguments forwarded verbatim to every job

    # Parse our own flags; anything unrecognised is forwarded to the Python script
    for arg in "$@"; do
        case $arg in
            --dry-run|--dryrun|--dry_run)
                dryrun=1 ;;
            --lines=*)
                lines_spec="${arg#*=}" ;;
            --sep=*)
                custom_sep="${arg#*=}" ;;
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
                # SLURM throttle: %N means "run at most N array tasks simultaneously"
                max_parallel="%${arg#*=}" ;;
            --log-dir=*)
                log_dir="${arg#*=}" ;;
            --log-prefix=*)
                log_prefix="${arg#*=}" ;;
            *)
                fixed_args+=("$arg") ;;
        esac
    done

    # Auto-detect separator from file extension; explicit --sep always wins
    local sep=$'\t'
    [[ $params == *.csv ]] && sep=','
    [[ -n "$custom_sep" ]] && sep="$custom_sep"

    # Build the awk field-separator string.
    # Single-character separators are wrapped in a bracket expression [...] so that
    # awk treats them as literals instead of ERE metacharacters. Without this,
    # e.g. | would mean alternation in ERE and gawk would emit a warning.
    # Multi-character separators are regex-escaped with backslashes via sed.
    local awk_sep
    if [[ ${#sep} -eq 1 ]]; then
        awk_sep="[$sep]"
    else
        awk_sep=$(printf '%s' "$sep" | sed 's/[]\\^$.|?*+(){}[]/\\&/g')
    fi

    # Count data rows (file line count minus the header line).
    # awk NR is used instead of wc -l because wc -l counts newlines and silently
    # ignores a final line that has no trailing newline.
    local n=$(($(awk 'END{print NR}' "$params") - 1))
    if [ $n -le 0 ]; then
        echo "The file $params has no parameter rows"
        return 1
    fi

    # Build --gres string only when a GPU count was requested.
    # If --gpu-type is also given, format is gpu:<type>:<count>, else gpu:<count>.
    local gpu_args=""
    if [ -n "$slurm_gpus" ]; then
        gpu_args="--gres=gpu:${slurm_gpu_type:+${slurm_gpu_type}:}$slurm_gpus"
    fi

    # Default to all rows; --lines overrides to a subset (same syntax SLURM uses for --array)
    local array_spec="${lines_spec:-1-$n}"

    # Auto-detect job name from experiment_name column (first selected row) unless overridden by --log-prefix
    local job_name=""
    local job_name_arg=()
    if [ -z "$log_prefix" ]; then
        local _header _first_line
        _header=$(head -n1 "$params" | tr -d '\r')
        _first_line=$(echo "$array_spec" | grep -oE '[0-9]+' | head -1)
        IFS="$sep" read -r -a _cols <<< "$_header"
        for i in "${!_cols[@]}"; do
            if [ "${_cols[$i]}" = "experiment_name" ]; then
                job_name=$(awk -F"$awk_sep" -v row="$_first_line" 'NR==row+1{print $'"$((i+1))"'}' "$params" | tr -d '\r')
                break
            fi
        done
        [ -n "$job_name" ] && job_name_arg=(--job-name="$job_name")
    fi

    # ── Dry-run: print the command that each job would run, without submitting ──
    if [ $dryrun -eq 1 ]; then
        local line_nums=($(__sarray_expand_spec "$array_spec"))
        echo "[Dry-run] ${#line_nums[@]} jobs would be generated (lines: $array_spec):"

        # tr -d '\r' strips Windows CRLF line endings so column names don't
        # acquire a trailing \r that would make them invalid bash variable names.
        header=$(head -n1 "$params" | tr -d '\r')
        # Split the header into an array of column names using the chosen separator
        IFS="$sep" read -r -a cols <<< "$header"

        for i in "${line_nums[@]}"; do
            local line
            # awk row index is 1-based in the file; row 1 is the header → data starts at NR==2,
            # so data row i lives at NR==i+1.
            line=$(awk -F"$awk_sep" -v row="$i" 'NR==row+1' "$params" | tr -d '\r')

            # Assign each field to a variable whose name is the corresponding column header.
            # After this, e.g. the value under column "n_layer" is available as $n_layer.
            IFS="$sep" read -r "${cols[@]}" <<< "$line"

            args=()
            for col in "${cols[@]}"; do
                # Indirect expansion: get the value of the variable named $col
                val="${!col}"
                if [ -n "$val" ]; then
                    if [ "$val" = "True" ] || [ "$val" = "true" ]; then
                        # Boolean true → flag with no value (e.g. --use_amp)
                        args+=("--$col")
                    elif [ "$val" = "False" ] || [ "$val" = "false" ]; then
                        : # Boolean false → omit the flag entirely
                    else
                        args+=("--$col" "$val")
                    fi
                fi
            done
            echo "python $script" "${args[@]}" "${fixed_args[@]}"
        done
        return 0
    fi

    # ── Actual SLURM submission ──
    # sbatch reads the heredoc as the job script.
    # --export passes the separator, params file path, and fixed args into the job environment
    # so the heredoc script can reconstruct the same argument-building logic on the compute node.
    # SLURM_ARRAY_TASK_ID (set automatically by SLURM) identifies which row this task should run.
    local log_pattern="${log_dir:+${log_dir%/}/}${log_prefix:+${log_prefix}_}${job_name:+%x_}slurm-%A_%a.out"
    sbatch --output="$log_pattern" \
        "${job_name_arg[@]}" \
        --array=$array_spec$max_parallel \
        --time=$slurm_time \
        --mem=$slurm_mem \
        -c $slurm_cpus \
        $gpu_args \
        --export=ALL,SCRIPT="$script",PARAMS_FILE="$params",SEP="$sep",AWK_SEP="$awk_sep",FIXED_ARGS="${fixed_args[*]}" <<'EOF'
#!/bin/bash
# tr -d '\r' guards against CRLF line endings in the params file
header=$(head -n1 "$PARAMS_FILE" | tr -d '\r')
IFS="$SEP" read -r -a cols <<< "$header"

# SLURM_ARRAY_TASK_ID is 1-based; header is at NR==1, so data row i is at NR==i+1
line=$(awk -F"$AWK_SEP" -v i=$SLURM_ARRAY_TASK_ID 'NR==i+1' "$PARAMS_FILE" | tr -d '\r')
IFS="$SEP" read -r "${cols[@]}" <<< "$line"

args=()
for col in "${cols[@]}"; do
    # xargs trims any stray whitespace from the value
    val=$(echo "${!col}" | xargs)
    if [ -n "$val" ]; then
        if [ "$val" = "True" ] || [ "$val" = "true" ]; then
            args+=("--$col")
        elif [ "$val" = "False" ] || [ "$val" = "false" ]; then
            : # skip boolean false
        else
            args+=("--$col" "$val")
        fi
    fi
done

echo "Running: python $SCRIPT" "${args[@]}" $FIXED_ARGS
python "$SCRIPT" "${args[@]}" $FIXED_ARGS
EOF
}

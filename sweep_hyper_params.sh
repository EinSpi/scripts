#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Hyperparameter lists
# =========================
# You can edit these arrays directly, or override them with command-line
# arguments. For example:
#   ./vllm_pp_hyperparam_sweep.sh \
#     --pruning-rates 2,4 \
#     --pruning-layers 10,15 \
#     --pruning-strats pp,random \
#     --compress-ratios 0.2,0.3
PRUNING_RATES=(4)
PRUNING_LAYERS=(15)
PRUNING_STRATS=(pp)
# Leave empty by default. When --compress-ratios is omitted (or passed an
# empty value), the sweep runs only the additional-config combinations.
COMPRESS_RATIOS=()

MODEL_PATH="/softwarePlatform/models_directory/Qwen3.5-4B-sft-v002"
SERVED_MODEL_NAME="Qwen3.5-4B"
HOST="0.0.0.0"
PORT=8095
MAX_DECODE_NUM=5

# Each configuration gets its own benchmark output directory.
OUTPUT_ROOT="./exp_name"
OPEN_SOURCE_OUTPUT_NAME="open_source"
ATTENTION_OUTPUT_NAME="mm_custom_gen"

# Service startup timeout in seconds.
STARTUP_TIMEOUT=900

usage() {
    cat <<'EOF'
Usage:
  ./vllm_pp_hyperparam_sweep.sh [options]

Options:
  --pruning-rates LIST     Comma-separated list, e.g. 2,4,8
  --pruning-layers LIST    Comma-separated list, e.g. 10,15,20
  --pruning-strats LIST    Comma-separated list, e.g. pp,random
  --compress-ratios LIST   Optional comma-separated list, e.g. 0.1,0.2,0.3
  --output-root DIR        Benchmark output root (default: ./exp_name)
  --startup-timeout SEC    Service readiness timeout (default: 900)
  -h, --help               Show this help

Without --compress-ratios, the script scans only --additional-config.

When --compress-ratios is provided, the script covers all four feature
combinations:
  1. neither option;
  2. only --additional-config;
  3. only --image-token-compress-ratio;
  4. both options (the full Cartesian product).
EOF
}

csv_to_array() {
    local csv="$1"
    local array_name="$2"
    IFS=',' read -r -a "$array_name" <<< "$csv"
}

while (($#)); do
    case "$1" in
        --pruning-rates)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            csv_to_array "$2" PRUNING_RATES
            shift 2
            ;;
        --pruning-layers)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            csv_to_array "$2" PRUNING_LAYERS
            shift 2
            ;;
        --pruning-strats)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            csv_to_array "$2" PRUNING_STRATS
            shift 2
            ;;
        --compress-ratios)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            csv_to_array "$2" COMPRESS_RATIOS
            shift 2
            ;;
        --output-root)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            OUTPUT_ROOT="$2"
            shift 2
            ;;
        --startup-timeout)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            STARTUP_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for array_name in PRUNING_RATES PRUNING_LAYERS PRUNING_STRATS; do
    declare -n values="$array_name"
    ((${#values[@]} > 0)) || {
        echo "$array_name must not be empty" >&2
        exit 2
    }
done
unset -n values

command -v vllm >/dev/null || {
    echo "vllm command not found" >&2
    exit 127
}
command -v ais_bench >/dev/null || {
    echo "ais_bench command not found" >&2
    exit 127
}
command -v curl >/dev/null || {
    echo "curl command not found" >&2
    exit 127
}
command -v setsid >/dev/null || {
    echo "setsid command not found" >&2
    exit 127
}

mkdir -p \
    "$OUTPUT_ROOT/$OPEN_SOURCE_OUTPUT_NAME" \
    "$OUTPUT_ROOT/$ATTENTION_OUTPUT_NAME" \
    "$OUTPUT_ROOT/server_logs"

SERVER_PID=""

stop_server() {
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Stopping vLLM service (PID $SERVER_PID)..."

        # vLLM can create worker child processes. Because it was launched with
        # setsid, terminating the whole process group also stops those workers.
        kill -TERM -- "-$SERVER_PID" 2>/dev/null || true

        local deadline=$((SECONDS + 60))
        while kill -0 "$SERVER_PID" 2>/dev/null && ((SECONDS < deadline)); do
            sleep 1
        done

        if kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "Service did not stop within 60 seconds; sending SIGKILL." >&2
            kill -KILL -- "-$SERVER_PID" 2>/dev/null || true
        fi

        wait "$SERVER_PID" 2>/dev/null || true
    fi

    SERVER_PID=""

    # Avoid racing the next service start while the port is still closing.
    local port_deadline=$((SECONDS + 30))
    while curl -fsS --max-time 1 \
        "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; do
        if ((SECONDS >= port_deadline)); then
            echo "Port $PORT is still serving after shutdown." >&2
            return 1
        fi
        sleep 1
    done
}

handle_signal() {
    local signal_name="$1"
    echo "Received $signal_name; stopping the active service." >&2
    stop_server
    trap - EXIT
    exit 130
}

trap stop_server EXIT
trap 'handle_signal SIGINT' INT
trap 'handle_signal SIGTERM' TERM

wait_until_ready() {
    local log_file="$1"
    local deadline=$((SECONDS + STARTUP_TIMEOUT))

    echo "Waiting for http://127.0.0.1:${PORT}/v1/models ..."
    while ((SECONDS < deadline)); do
        if curl -fsS --max-time 2 \
            "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
            echo "vLLM service is ready."
            return 0
        fi

        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "vLLM exited before becoming ready. Log: $log_file" >&2
            tail -n 100 "$log_file" >&2 || true
            return 1
        fi

        sleep 2
    done

    echo "Timed out after ${STARTUP_TIMEOUT}s waiting for vLLM." >&2
    echo "Server log: $log_file" >&2
    tail -n 100 "$log_file" >&2 || true
    return 1
}

run_configuration() {
    local tag="$1"
    shift
    local -a optional_args=("$@")
    local log_file="$OUTPUT_ROOT/server_logs/${tag}.log"

    if curl -fsS --max-time 2 \
        "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
        echo "Port $PORT already has a responding vLLM-compatible service." >&2
        echo "Stop that service before running this sweep." >&2
        return 1
    fi

    local -a serve_cmd=(
        vllm serve "$MODEL_PATH"
        --host "$HOST"
        --port "$PORT"
        --data-parallel-size 1
        --tensor-parallel-size 1
        --served-model-name "$SERVED_MODEL_NAME"
        --max-num-seqs 32
        --max-model-len 3072
        --max-num-batched-tokens 70000
        --trust-remote-code
        --gpu-memory-utilization 0.7
        --compilation-config
        '{"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[1,2,3,4,5]}'
        --async-scheduling
        --default-chat-template-kwargs
        '{"enable_thinking":false}'
    )
    serve_cmd+=("${optional_args[@]}")

    echo
    echo "============================================================"
    echo "Configuration: $tag"
    printf 'Launching:'
    printf ' %q' "${serve_cmd[@]}"
    printf '\n'
    echo "Server log: $log_file"

    setsid "${serve_cmd[@]}" >"$log_file" 2>&1 &
    SERVER_PID=$!

    wait_until_ready "$log_file"

    local open_source_dir="$OUTPUT_ROOT/$OPEN_SOURCE_OUTPUT_NAME/$tag"
    local attention_dir="$OUTPUT_ROOT/$ATTENTION_OUTPUT_NAME/$tag"
    mkdir -p "$open_source_dir" "$attention_dir"

    #echo "Running TextVQA benchmark..."
    #ais_bench \
    #    --models vllm_api_stream_chat \
    #    --datasets textvqa_gen_base64 \
    #    --num-prompts 1000 \
    #    -w "$open_source_dir"

    echo "Running multimodal custom benchmark..."
    ais_bench \
        --models vllm_api_stream_chat \
        --datasets mm_custom_gen \
        --num-prompts 1530 \
        -w "$attention_dir"

    stop_server
}

# When compression ratios are supplied, cover the baseline and all compression
# combinations. With an empty list, only the additional-config sweep below is
# run, and vLLM is never passed --image-token-compress-ratio.
if ((${#COMPRESS_RATIOS[@]} > 0)); then
    # 1. Neither pruning config nor image compression ratio.
    run_configuration "baseline_no_pruning_no_compression"
fi

# 2. Only --additional-config.
# This is outside the compression-ratio loop so each pruning configuration is
# run exactly once without --image-token-compress-ratio.
for pruning_rate in "${PRUNING_RATES[@]}"; do
    for pruning_layer in "${PRUNING_LAYERS[@]}"; do
        for pruning_strat in "${PRUNING_STRATS[@]}"; do
            tag="additional_only_rate_${pruning_rate}_layer_${pruning_layer}_strat_${pruning_strat}"
            additional_config="$(
                printf \
                    '{"llm_pruning_config":{"pruning_rate":%s,"pruning_layer":%s,"pruning_strat":"%s","max_decode_num":%s}}' \
                    "$pruning_rate" \
                    "$pruning_layer" \
                    "$pruning_strat" \
                    "$MAX_DECODE_NUM"
            )"

            run_configuration \
                "$tag" \
                --additional-config "$additional_config"
        done
    done
done

# 3. Only --image-token-compress-ratio.
for compress_ratio in "${COMPRESS_RATIOS[@]}"; do
    run_configuration \
        "compression_only_ratio_${compress_ratio}" \
        --image-token-compress-ratio "$compress_ratio"
done

# 4. Both options: full Cartesian product of all four parameter lists.
for pruning_rate in "${PRUNING_RATES[@]}"; do
    for pruning_layer in "${PRUNING_LAYERS[@]}"; do
        for pruning_strat in "${PRUNING_STRATS[@]}"; do
            for compress_ratio in "${COMPRESS_RATIOS[@]}"; do
                tag="both_rate_${pruning_rate}_layer_${pruning_layer}_strat_${pruning_strat}_ratio_${compress_ratio}"
                additional_config="$(
                    printf \
                        '{"llm_pruning_config":{"pruning_rate":%s,"pruning_layer":%s,"pruning_strat":"%s","max_decode_num":%s}}' \
                        "$pruning_rate" \
                        "$pruning_layer" \
                        "$pruning_strat" \
                        "$MAX_DECODE_NUM"
                )"

                run_configuration \
                    "$tag" \
                    --additional-config "$additional_config" \
                    --image-token-compress-ratio "$compress_ratio"
            done
        done
    done
done

echo
echo "All hyperparameter configurations completed successfully."

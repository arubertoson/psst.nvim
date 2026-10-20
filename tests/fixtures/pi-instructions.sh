#!/bin/sh
# Deterministic Pi JSON-mode substitute; records the process boundary without a model.
set -eu

if [ "${1-}" = "--list-models" ]; then
    printf 'provider model\ntest fixture\n'
    exit 0
fi

capture_dir=$(dirname "$0")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --append-system-prompt) printf '%s' "$2" > "$capture_dir/instructions"; shift 2 ;;
        --tools) printf '%s' "$2" > "$capture_dir/tools"; shift 2 ;;
        --session-id) printf '%s' "$2" > "$capture_dir/session-id"; shift 2 ;;
        --mode|--model|--preset|--session-dir) shift 2 ;;
        --no-session|--no-tools) shift ;;
        *) printf 'Unexpected Pi argument: %s\n' "$1" >&2; exit 1 ;;
    esac
done

cat > "$capture_dir/request"
printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"generated"}}'

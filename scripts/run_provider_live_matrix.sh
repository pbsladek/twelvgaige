#!/bin/sh
set -eu

artifact_dir=${LIVE_ARTIFACT_DIR:-artifacts/live/provider-matrix}
requested=${TWELVGAIGE_PROVIDER_LIVE_PROVIDERS:-}
test_file=test/twelvgaige/llm/provider_live_test.exs
ran=0

mkdir -p "$artifact_dir"

contains_provider() {
  provider=$1

  if [ -z "$requested" ]; then
    return 0
  fi

  case ",$requested," in
    *",$provider,"*) return 0 ;;
    *) return 1 ;;
  esac
}

run_contract() {
  provider=$1
  api=$2
  log=$3

  if TWELVGAIGE_PROVIDER_LIVE=1 \
    TWELVGAIGE_PROVIDER_LIVE_PROVIDERS="$provider" \
    TWELVGAIGE_OPENAI_LIVE_APIS="$api" \
    MIX_ENV=test mix test --include provider_live "$test_file" > "$log" 2>&1; then
    printf '%s\n' "Live provider contract passed: $provider${api:+/$api} ($log)"
  else
    cat "$log"
    return 1
  fi
}

if contains_provider openai && [ -n "${TWELVGAIGE_OPENAI_LIVE_MODEL:-}" ] &&
  { [ -n "${TWELVGAIGE_OPENAI_API_KEY:-}" ] || [ -n "${OPENAI_API_KEY:-}" ]; }; then
  old_ifs=$IFS
  IFS=,
  for api in ${TWELVGAIGE_OPENAI_LIVE_APIS:-responses,chat_completions}; do
    case "$api" in
      responses|chat_completions) ;;
      *) printf '%s\n' "unsupported OpenAI live API: $api" >&2; exit 2 ;;
    esac

    run_contract openai "$api" "$artifact_dir/openai-$api.log"
    ran=1
  done
  IFS=$old_ifs
fi

if contains_provider ollama && [ -n "${TWELVGAIGE_OLLAMA_LIVE_MODEL:-}" ] &&
  { [ -n "${TWELVGAIGE_OLLAMA_BASE_URL:-}" ] || [ -n "${OLLAMA_HOST:-}" ]; }; then
  run_contract ollama "" "$artifact_dir/ollama.log"
  ran=1
fi

if [ "$ran" -ne 1 ]; then
  printf '%s\n' "no requested live provider has complete model and credential/base-URL configuration" >&2
  exit 2
fi

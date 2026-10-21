#!/usr/bin/env bash
set -euo pipefail

case "${INPUT_STATUS:-firing}" in
  firing | failure) status=firing ;;
  resolved | success) status=resolved ;;
  cancelled | skipped)
    echo "Job status is ${INPUT_STATUS}; not sending an alert."
    echo "sent-status=" >>"$GITHUB_OUTPUT"
    exit 0
    ;;
  *)
    echo "::error::Unknown status '${INPUT_STATUS}': expected firing, resolved, success, failure or cancelled."
    exit 1
    ;;
esac

: "${INPUT_ALERT_SOURCE_CONFIG_ID:?alert-source-config-id is required}"
: "${INPUT_TOKEN:?token is required}"

metadata="${INPUT_METADATA:-}"
[[ -n "$metadata" ]] || metadata='{}'
if ! jq -e 'type == "object"' <<<"$metadata" >/dev/null 2>&1; then
  echo "::error::metadata must be a JSON object."
  exit 1
fi

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}"
commit_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
short_sha="${GITHUB_SHA:0:7}"
head_commit_message="${HEAD_COMMIT_MESSAGE:-}"
commit_subject="${head_commit_message%%$'\n'*}"

dedup_key="${INPUT_DEDUPLICATION_KEY:-${GITHUB_REPOSITORY}/${GITHUB_WORKFLOW}/${GITHUB_JOB}/${GITHUB_REF_NAME}}"
title="${INPUT_TITLE:-${GITHUB_WORKFLOW} failed on ${GITHUB_REF_NAME} in ${GITHUB_REPOSITORY}}"
source_url="${INPUT_SOURCE_URL:-$run_url}"

if [[ -n "${INPUT_DESCRIPTION:-}" ]]; then
  description="$INPUT_DESCRIPTION"
else
  description="**Workflow:** ${GITHUB_WORKFLOW} (job \`${GITHUB_JOB}\`)
**Ref:** \`${GITHUB_REF_NAME}\` at [\`${short_sha}\`](${commit_url})
**Triggered by:** ${GITHUB_EVENT_NAME} from @${GITHUB_ACTOR}"
  if [[ -n "$commit_subject" ]]; then
    description+="
**Commit:** ${commit_subject}"
  fi
  description+="

[View workflow run](${run_url})"
fi

body=$(
  jq -n \
    --arg status "$status" \
    --arg title "$title" \
    --arg description "$description" \
    --arg dedup_key "$dedup_key" \
    --arg source_url "$source_url" \
    --argjson extra "$metadata" \
    --arg repository "$GITHUB_REPOSITORY" \
    --arg workflow "$GITHUB_WORKFLOW" \
    --arg job "$GITHUB_JOB" \
    --arg ref "$GITHUB_REF_NAME" \
    --arg sha "$GITHUB_SHA" \
    --arg actor "$GITHUB_ACTOR" \
    --arg event_name "$GITHUB_EVENT_NAME" \
    --arg run_id "$GITHUB_RUN_ID" \
    --arg run_attempt "$GITHUB_RUN_ATTEMPT" \
    --arg run_url "$run_url" \
    '{
      status: $status,
      title: $title,
      description: $description,
      deduplication_key: $dedup_key,
      source_url: $source_url,
      metadata: ({
        repository: $repository,
        workflow: $workflow,
        job: $job,
        ref: $ref,
        sha: $sha,
        actor: $actor,
        event_name: $event_name,
        run_id: $run_id,
        run_attempt: $run_attempt,
        run_url: $run_url
      } + $extra)
    }'
)

url="${INPUT_API_URL%/}/v2/alert_events/http/${INPUT_ALERT_SOURCE_CONFIG_ID}"
response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

# The token goes through a file descriptor so it never appears in the process list.
http_code=$(
  curl --silent --show-error \
    --retry 3 --retry-all-errors --retry-max-time 60 \
    --output "$response_file" --write-out '%{http_code}' \
    --request POST "$url" \
    --header @<(printf 'Authorization: Bearer %s\n' "$INPUT_TOKEN") \
    --header 'Content-Type: application/json' \
    --data-binary "$body"
) || true

echo "deduplication-key=${dedup_key}" >>"$GITHUB_OUTPUT"

if [[ "$http_code" =~ ^2 ]]; then
  echo "Sent ${status} alert to incident.io (deduplication key: ${dedup_key})."
  echo "sent-status=${status}" >>"$GITHUB_OUTPUT"
  exit 0
fi

echo "sent-status=" >>"$GITHUB_OUTPUT"
if [[ "$http_code" == 000 ]]; then
  message="Could not reach incident.io at ${INPUT_API_URL}."
else
  message="incident.io returned HTTP ${http_code}: $(head -c 1000 "$response_file")"
fi
if [[ "${INPUT_FAIL_ON_ERROR:-false}" == "true" ]]; then
  echo "::error::${message}"
  exit 1
fi
echo "::warning::${message}"

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

repo="$GITHUB_REPOSITORY"
event_file="${GITHUB_EVENT_PATH:-/dev/null}"

event() {
  jq -r "$1 // empty" "$event_file" 2>/dev/null || true
}

github_api() {
  [[ -n "${INPUT_GITHUB_TOKEN:-}" ]] || return 1
  curl --silent --fail --retry 2 \
    --header @<(printf 'Authorization: Bearer %s\n' "$INPUT_GITHUB_TOKEN") \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "${GITHUB_API_URL:-https://api.github.com}/$1"
}

api_notice() {
  if [[ -n "${INPUT_GITHUB_TOKEN:-}" ]]; then
    echo "::notice::Could not read $1 from the GitHub API, so the alert will not include it. The token needs $2."
  fi
}

# Under workflow_run, describe the run that triggered this workflow rather than this one.
if [[ "${GITHUB_EVENT_NAME:-}" == workflow_run ]]; then
  current_run=false
  run_id=$(event .workflow_run.id)
  run_attempt=$(event .workflow_run.run_attempt)
  run_url=$(event .workflow_run.html_url)
  workflow=$(event .workflow_run.name)
  job=""
  branch=$(event .workflow_run.head_branch)
  sha=$(event .workflow_run.head_sha)
  trigger=$(event .workflow_run.event)
  actor=$(event .workflow_run.triggering_actor.login)
  default_dedup_key="${repo}/${workflow}/${branch}"
else
  current_run=true
  run_id="$GITHUB_RUN_ID"
  run_attempt="$GITHUB_RUN_ATTEMPT"
  run_url="${GITHUB_SERVER_URL}/${repo}/actions/runs/${run_id}/attempts/${run_attempt}"
  workflow="$GITHUB_WORKFLOW"
  job="$GITHUB_JOB"
  branch="${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}"
  # On pull_request events GITHUB_SHA is a merge commit nobody authored.
  sha=$(event .pull_request.head.sha)
  sha="${sha:-$GITHUB_SHA}"
  trigger="$GITHUB_EVENT_NAME"
  actor="${GITHUB_TRIGGERING_ACTOR:-$GITHUB_ACTOR}"
  default_dedup_key="${repo}/${workflow}/${job}/${GITHUB_REF_NAME}"
fi

commit_jq='{message, author_name, author_email, author_login, url}'
commit=$(
  github_api "repos/${repo}/commits/${sha}" |
    jq "{message: .commit.message, author_name: .commit.author.name, author_email: .commit.author.email, author_login: .author.login, url: .html_url} | $commit_jq"
) || commit=""
if [[ -z "$commit" ]]; then
  api_notice "the commit" "contents: read"
  commit=$(
    jq --arg sha "$sha" \
      "(.head_commit // .workflow_run.head_commit) | select(.id == \$sha)
        | {message, author_name: .author.name, author_email: .author.email, author_login: .author.username, url}
        | $commit_jq" \
      "$event_file" 2>/dev/null
  ) || true
  [[ -n "$commit" ]] || commit='{}'
fi
commit=$(jq --arg url "${GITHUB_SERVER_URL}/${repo}/commit/${sha}" '.url //= $url' <<<"$commit")

failed_jobs='[]'
if [[ "$status" == firing && -n "$run_id" ]]; then
  if jobs=$(github_api "repos/${repo}/actions/runs/${run_id}/attempts/${run_attempt}/jobs?per_page=100"); then
    # Within a run, report only this job: the jobs API marks it in progress on this runner.
    failed_jobs=$(
      jq --arg runner "${RUNNER_NAME:-}" --argjson current_run "$current_run" '
        [.jobs[] | select(.conclusion == "failure" or any(.steps[]?; .conclusion == "failure"))] as $failed
        | [$failed[] | select(.status == "in_progress" and .runner_name == $runner)] as $this_job
        | (if $current_run and ($this_job | length) > 0 then $this_job else $failed end)
        | map({id, name, url: .html_url, failed_steps: [.steps[]? | select(.conclusion == "failure") | .name]})
        | .[:5]' <<<"$jobs"
    )
  else
    api_notice "the failed jobs" "actions: read"
  fi

  with_errors='[]'
  while IFS= read -r failed_job; do
    job_id=$(jq -r .id <<<"$failed_job")
    # A job's check run shares its ID, and its failure annotations hold the ::error messages.
    errors=$(
      github_api "repos/${repo}/check-runs/${job_id}/annotations?per_page=100" |
        jq '[.[] | select(.annotation_level == "failure")
              | select(.message | test("^Process completed with exit code \\d+\\.$") | not)
              | {message: (.message | gsub("\\s+"; " ") | .[0:300]), path, line: .start_line}][:5]'
    ) || errors='[]'
    with_errors=$(jq --argjson job "$failed_job" --argjson errors "$errors" '. + [$job + {errors: $errors}]' <<<"$with_errors")
  done < <(jq -c '.[]' <<<"$failed_jobs")
  failed_jobs=$(jq 'map(del(.id))' <<<"$with_errors")
fi

dedup_key="${INPUT_DEDUPLICATION_KEY:-$default_dedup_key}"
title="${INPUT_TITLE:-${workflow} failed on ${branch} in ${repo}}"
source_url="${INPUT_SOURCE_URL:-$run_url}"

if [[ -n "${INPUT_DESCRIPTION:-}" ]]; then
  description="$INPUT_DESCRIPTION"
else
  description=$(
    jq -rn \
      --arg workflow "$workflow" --arg job "$job" --arg branch "$branch" --arg sha "$sha" \
      --arg trigger "$trigger" --arg actor "$actor" --arg run_url "$run_url" \
      --argjson commit "$commit" --argjson failed_jobs "$failed_jobs" '
      [
        "**Workflow:** \($workflow)" + (if $job != "" then " (job `\($job)`)" else "" end),
        "**Branch:** `\($branch)`",
        "**Commit:** [`\($sha[0:7])`](\($commit.url))"
          + (if $commit.message then " " + ($commit.message | split("\n")[0]) else "" end),
        (if $commit.author_name or $commit.author_login then
          "**Author:** " + ([$commit.author_name, ($commit.author_login | values | "@\(.)")] | map(values) | join(" "))
        else empty end),
        "**Triggered by:** \($trigger) from @\($actor)"
      ]
      + (if ($failed_jobs | length) > 0 then
          ["", "**Failed:**"]
          + [$failed_jobs[]
              | "- [\(.name)](\(.url))"
                + (if (.failed_steps | length) > 0 then ", step " + (.failed_steps | map("`\(.)`") | join(", ")) else "" end),
                (.errors[] | "  - \(.message)")]
        else [] end)
      + ["", "[View workflow run](\($run_url))"]
      | join("\n")'
  )
fi

body=$(
  jq -n \
    --arg status "$status" \
    --arg title "$title" \
    --arg description "$description" \
    --arg dedup_key "$dedup_key" \
    --arg source_url "$source_url" \
    --argjson extra "$metadata" \
    --argjson commit "$commit" \
    --argjson failed_jobs "$failed_jobs" \
    --arg repository "$repo" \
    --arg workflow "$workflow" \
    --arg job "$job" \
    --arg branch "$branch" \
    --arg sha "$sha" \
    --arg actor "$actor" \
    --arg event_name "$trigger" \
    --arg run_id "$run_id" \
    --arg run_attempt "$run_attempt" \
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
        branch: $branch,
        sha: $sha,
        actor: $actor,
        event_name: $event_name,
        run_id: $run_id,
        run_attempt: $run_attempt,
        run_url: $run_url,
        commit_message: $commit.message,
        commit_url: $commit.url,
        commit_author_name: $commit.author_name,
        commit_author_email: $commit.author_email,
        commit_author_login: $commit.author_login,
        failed_jobs: $failed_jobs
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

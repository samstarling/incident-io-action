# incident-io-action

Send a failing GitHub Actions job to an [incident.io](https://incident.io) HTTP alert source, and resolve the alert when the job next succeeds. There's no build step, and it has and no dependencies beyond `bash`, `curl` and `jq`, which every GitHub-hosted runner has.

## Setup

1. In incident.io, go to **Alerts → Sources → New alert source → HTTP**.
2. Copy the alert source config ID and the secret token.
3. Add the token as a secret, e.g. `INCIDENT_IO_ALERT_TOKEN`.

## What the alert includes

- The workflow, job, branch and a link to the run.
- The commit: SHA, message, and author's name, email and GitHub login. On pull requests this is the PR's head commit, not the merge commit.
- Who (or what) triggered the run.
- On failure, the failed jobs and steps, with their error messages taken from the job's error annotations (anything a step reports with `::error::`, and most test reporters and linters).

To keep the payload bounded, an alert lists at most five failed jobs, five error messages per job and 1,000 characters per message. Whenever a limit cuts something, the metadata says so with the totals and a `truncated` flag.

The commit and failure details come from the GitHub API, using the job's `GITHUB_TOKEN`. If your workflow sets `permissions`, grant these:

```yaml
permissions:
  contents: read # the commit
  actions: read # failed jobs and steps
  checks: read # error messages
```

Without them the alert still sends, falling back to what the event payload carries (the commit on `push` and `workflow_run` events) and logging a notice for what it could not read.

## Usage

### Alert on failure, resolve on recovery

Add this as the **last step** of the job you want to watch:

```yaml
- uses: samstarling/incident-io-action@v1
  if: ${{ !cancelled() }}
  with:
    alert-source-config-id: 01ABCDEF...
    token: ${{ secrets.INCIDENT_IO_ALERT_TOKEN }}
    status: ${{ job.status }}
```

A failed job fires an alert, and the next successful run of the same workflow, job and branch resolves it. Repeat failures in between are deduplicated into one alert.

### Alert on failure only

```yaml
- uses: samstarling/incident-io-action@v1
  if: failure()
  with:
    alert-source-config-id: 01ABCDEF...
    token: ${{ secrets.INCIDENT_IO_ALERT_TOKEN }}
```

### Watch a whole workflow from outside it

To watch another workflow without editing it, or to get one alert per workflow rather than per job, use `workflow_run`. The action then describes the run that triggered it, and lists every failed job in that run:

```yaml
on:
  workflow_run:
    workflows: [Deploy]
    types: [completed]
    branches: [main]

jobs:
  alert:
    runs-on: ubuntu-latest
    if: github.event.workflow_run.conclusion == 'failure' || github.event.workflow_run.conclusion == 'success'
    steps:
      - uses: samstarling/incident-io-action@v1
        with:
          alert-source-config-id: 01ABCDEF...
          token: ${{ secrets.INCIDENT_IO_ALERT_TOKEN }}
          status: ${{ github.event.workflow_run.conclusion }}
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `alert-source-config-id` | (required) | ID of the incident.io HTTP alert source. |
| `token` | (required) | The alert source's secret token. |
| `status` | `firing` | `firing` or `resolved`, or a job status: `failure` fires, `success` resolves, `cancelled` and `skipped` send nothing. |
| `title` | `<workflow> failed on <branch> in <repo>` | Alert title. |
| `description` | None | Markdown description. The run details are all in the metadata, so this is only for extra context. |
| `deduplication-key` | `<repo>/<workflow>/<job>/<ref>`, or `<repo>/<workflow>/<branch>` under `workflow_run` | Groups repeat failures into one alert and pairs a resolve with its firing. |
| `metadata` | `{}` | JSON object merged over the default metadata. |
| `source-url` | The workflow run | Link shown on the alert. |
| `github-token` | `${{ github.token }}` | Token for the commit and failure lookups. Empty to skip them. |
| `api-url` | `https://api.incident.io` | API base URL. |
| `fail-on-error` | `false` | Fail the step if incident.io rejects the event, rather than logging a warning. |

## Outputs

| Output | Description |
| --- | --- |
| `sent-status` | `firing` or `resolved`, or empty if nothing was sent. |
| `deduplication-key` | The deduplication key used. |

## Metadata

Every event carries this metadata, which you can use in alert source attribute expressions, routes and filters in incident.io:

| Key | Description |
| --- | --- |
| `repository`, `workflow`, `job`, `branch` | Where the run happened. `job` is empty under `workflow_run`. |
| `sha`, `commit_url`, `commit_message` | The commit. |
| `commit_author_name`, `commit_author_email`, `commit_author_login` | The commit's author. `commit_author_email` can map the alert to an incident.io user. |
| `commit_details` | Where the commit fields came from: `api`, `event` (the event payload, which has no author login) or `unavailable` (all commit fields but `commit_url` are null). |
| `actor`, `event_name` | Who or what triggered the run. |
| `run_id`, `run_attempt`, `run_url` | The workflow run. |
| `failure_details` | `included`, `not_applicable` (a resolve) or `unavailable` (no token, or the API refused it). The three fields below are null unless this is `included`. |
| `failed_jobs` | The failed jobs, as described below. An empty list means the lookup worked and found no failed jobs. |
| `failed_jobs_total`, `failed_jobs_truncated` | How many jobs failed, and whether `failed_jobs` lists fewer than that. |

Each entry in `failed_jobs` looks like this:

```json
{
  "name": "test (ios-18)",
  "url": "https://github.com/acme/app/actions/runs/1/job/12",
  "failed_steps": ["Run tests"],
  "errors": [
    {
      "message": "AssertionError: expected 2 to equal 3",
      "message_truncated": false,
      "path": "tests/login.test.ts",
      "line": 40
    }
  ],
  "errors_total": 1,
  "errors_truncated": false
}
```

`errors`, `errors_total` and `errors_truncated` are null when the job's error messages could not be read. `path` and `line` are null for errors that do not point at a file.

Keys in the `metadata` input are added to these, and override them on a clash.

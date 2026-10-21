# incident.io alert action

Send a failing GitHub Actions job to an [incident.io](https://incident.io)
HTTP alert source, and resolve the alert when the job next succeeds.

No build step and no dependencies beyond `bash`, `curl` and `jq`, which every
GitHub-hosted runner has.

## Setup

1. In incident.io, go to **Alerts → Sources → New alert source → HTTP**.
2. Copy the alert source config ID (the last segment of the URL it gives you)
   and the secret token.
3. Add the token as a repository or organisation secret, e.g.
   `INCIDENT_IO_ALERT_TOKEN`.

## Usage

### Alert on failure, resolve on recovery

Add this as the **last step** of the job you want to watch:

```yaml
- uses: semaloop/incident-io-alert@v1
  if: ${{ !cancelled() }}
  with:
    alert-source-config-id: 01ABCDEF...
    token: ${{ secrets.INCIDENT_IO_ALERT_TOKEN }}
    status: ${{ job.status }}
```

A failed job fires an alert; the next successful run of the same workflow,
job and branch resolves it. Repeat failures in between are deduplicated into
the one alert.

### Alert on failure only

```yaml
- uses: semaloop/incident-io-alert@v1
  if: failure()
  with:
    alert-source-config-id: 01ABCDEF...
    token: ${{ secrets.INCIDENT_IO_ALERT_TOKEN }}
```

### Watch a whole workflow from outside it

To watch another workflow without editing it, or to get one alert per
workflow rather than per job, use `workflow_run`:

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
      - uses: semaloop/incident-io-alert@v1
        with:
          alert-source-config-id: 01ABCDEF...
          token: ${{ secrets.INCIDENT_IO_ALERT_TOKEN }}
          status: ${{ github.event.workflow_run.conclusion }}
          title: ${{ github.event.workflow_run.name }} failed on ${{ github.event.workflow_run.head_branch }}
          deduplication-key: ${{ github.repository }}/${{ github.event.workflow_run.name }}/${{ github.event.workflow_run.head_branch }}
          source-url: ${{ github.event.workflow_run.html_url }}
```

## Inputs

| Input                    | Default                                | Description                                                                                                           |
| ------------------------ | -------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `alert-source-config-id` | (required)                             | ID of the incident.io HTTP alert source.                                                                              |
| `token`                  | (required)                             | The alert source's secret token.                                                                                      |
| `status`                 | `firing`                               | `firing` or `resolved`, or a job status: `failure` fires, `success` resolves, `cancelled` and `skipped` send nothing. |
| `title`                  | `<workflow> failed on <ref> in <repo>` | Alert title.                                                                                                          |
| `description`            | Run summary                            | Markdown description: workflow, job, ref, commit, actor and a link to the run.                                        |
| `deduplication-key`      | `<repo>/<workflow>/<job>/<ref>`        | Groups repeat failures into one alert and pairs a resolve with its firing.                                            |
| `metadata`               | `{}`                                   | JSON object merged over the default metadata.                                                                         |
| `source-url`             | The workflow run                       | Link shown on the alert.                                                                                              |
| `api-url`                | `https://api.incident.io`              | API base URL.                                                                                                         |
| `fail-on-error`          | `false`                                | Fail the step if incident.io rejects the event, rather than logging a warning.                                        |

## Outputs

| Output              | Description                                           |
| ------------------- | ----------------------------------------------------- |
| `sent-status`       | `firing` or `resolved`, or empty if nothing was sent. |
| `deduplication-key` | The deduplication key used.                           |

## Metadata

Every event carries this metadata, which you can use in alert source
attribute expressions, routes and filters in incident.io:

`repository`, `workflow`, `job`, `ref`, `sha`, `actor`, `event_name`,
`run_id`, `run_attempt`, `run_url`

Keys in the `metadata` input are added to these, and override them on a clash.

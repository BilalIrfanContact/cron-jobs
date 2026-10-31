#!/usr/bin/env bash
# One attempt at grabbing the Always Free A1 server: applies the saved Resource Manager
# stack and reports the outcome. Called every 15 minutes by .github/workflows/job.yml.
#   - server exists or gets created -> push notification, workflow disables itself, exit 3
#   - out of capacity / throttled   -> exit 0 quietly, the next attempt tries again
#   - anything else                 -> push notification, workflow disables itself, exit 1
# Needs: oci CLI configured, gh CLI with GH_TOKEN, STACK_ID, OCI_TENANCY, NTFY_TOPIC.
set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

notify() { # title, message, priority, ntfy emoji tags
  curl -fsS -H "Title: $1" -H "Priority: ${3:-default}" -H "Tags: ${4:-}" -d "$2" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null
}
stop_hunting() { gh workflow disable job.yml; }

report_server() { # instance id
  ip=$(oci compute instance list-vnics --instance-id "$1" --query 'data[0]."public-ip"' --raw-output)
  echo "A1 server is up: $ip"
  notify "A1 server secured!" "Your free Oracle server (2 OCPU / 12 GB) is live and it's yours to keep.
IP: $ip
Connect: ssh -i ~/.ssh/oracle_vps ubuntu@$ip
The hunt has stopped." urgent tada
  stop_hunting
}

# Never create a second server: if one already exists, report it and stop.
existing=$(oci compute instance list -c "$OCI_TENANCY" --all \
  --query "data[?shape=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id" \
  --raw-output)
if [ -n "$existing" ]; then report_server "$existing"; exit 3; fi

out=$(oci --no-retry resource-manager job create-apply-job --stack-id "$STACK_ID" \
  --execution-plan-strategy AUTO_APPROVED \
  --wait-for-state SUCCEEDED --wait-for-state FAILED --max-wait-seconds 1200 2>&1)
job=$(grep -o 'ocid1.ormjob[A-Za-z0-9._-]*' <<<"$out" | head -1)

if grep -q '"lifecycle-state": "SUCCEEDED"' <<<"$out"; then
  id=$(oci compute instance list -c "$OCI_TENANCY" --all \
    --query "data[?shape=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED'] | [0].id" --raw-output)
  report_server "$id"; exit 3
fi

# Errors that just mean "try again later" (rate limit, a job already running, Oracle hiccup).
retryable='TooManyRequests|"status": 429|Conflict|"status": 409|InternalError|"status": 5[0-9][0-9]'
if [ -z "$job" ]; then
  if grep -qE "$retryable" <<<"$out"; then echo "Couldn't start a job (throttled or busy), retrying next run"; exit 0; fi
  echo "$out"
  notify "Server hunt paused" "Oracle rejected the request for a new reason, so I stopped retrying. Check the latest GitHub run.
$(tail -c 300 <<<"$out")" high warning
  stop_hunting; exit 1
fi

state=$(oci resource-manager job get --job-id "$job" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
if [ "$state" != "FAILED" ]; then echo "Job $job still $state, checking again next run"; exit 0; fi

logs=$(oci --no-retry resource-manager job get-job-logs-content --job-id "$job" 2>&1)
if grep -qiE 'out of (host )?capacity' <<<"$logs"; then echo "Out of capacity, retrying next run"; exit 0; fi
if grep -qE "$retryable" <<<"$logs"; then echo "Transient Oracle error, retrying next run"; exit 0; fi

echo "$logs" | grep -iE 'error' | head -20
notify "Server hunt paused" "The attempt failed for a reason other than capacity, so I stopped retrying. Check the latest GitHub run. Job: $job" high warning
stop_hunting; exit 1

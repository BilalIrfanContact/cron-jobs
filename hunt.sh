#!/usr/bin/env bash
# One attempt at grabbing the Always Free A1 server: applies the saved Resource Manager
# stack and reports the outcome. Run by .github/workflows/hunt.yml every 15 minutes.
#   - server exists or gets created -> push notification, workflow disables itself
#   - out of capacity / throttled   -> exit quietly, next run tries again
#   - anything else                 -> push notification, workflow disables itself
# Needs: oci CLI configured, gh CLI with GH_TOKEN, STACK_ID, OCI_TENANCY, NTFY_TOPIC.
set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

notify() { # title, message, priority
  curl -fsS -H "Title: $1" -H "Priority: ${3:-default}" -d "$2" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null
}
stop_hunting() { gh workflow disable hunt.yml; }

report_server() { # instance id
  ip=$(oci compute instance list-vnics --instance-id "$1" --query 'data[0]."public-ip"' --raw-output)
  echo "A1 server is up: $ip"
  notify "Oracle A1 server is yours" "IP $ip — ssh -i ~/.ssh/oracle_vps ubuntu@$ip" urgent
  stop_hunting
}

# Never create a second server: if one already exists, report it and stop.
existing=$(oci compute instance list -c "$OCI_TENANCY" --all \
  --query "data[?shape=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id" \
  --raw-output)
if [ -n "$existing" ]; then report_server "$existing"; exit 0; fi

out=$(oci --no-retry resource-manager job create-apply-job --stack-id "$STACK_ID" \
  --execution-plan-strategy AUTO_APPROVED \
  --wait-for-state SUCCEEDED --wait-for-state FAILED --max-wait-seconds 1200 2>&1)
job=$(grep -o 'ocid1.ormjob[A-Za-z0-9._-]*' <<<"$out" | head -1)

if grep -q '"lifecycle-state": "SUCCEEDED"' <<<"$out"; then
  id=$(oci compute instance list -c "$OCI_TENANCY" --all \
    --query "data[?shape=='VM.Standard.A1.Flex' && \"lifecycle-state\"!='TERMINATED'] | [0].id" --raw-output)
  report_server "$id"; exit 0
fi

# Errors that just mean "try again later" (rate limit, a job already running, Oracle hiccup).
retryable='TooManyRequests|"status": 429|Conflict|"status": 409|InternalError|"status": 5[0-9][0-9]'
if [ -z "$job" ]; then
  if grep -qE "$retryable" <<<"$out"; then echo "Couldn't start a job (throttled or busy), retrying next run"; exit 0; fi
  echo "$out"
  notify "A1 hunter stopped" "Couldn't start the Apply job: $(tail -c 300 <<<"$out")" high
  stop_hunting; exit 1
fi

state=$(oci resource-manager job get --job-id "$job" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
if [ "$state" != "FAILED" ]; then echo "Job $job still $state, checking again next run"; exit 0; fi

logs=$(oci --no-retry resource-manager job get-job-logs-content --job-id "$job" 2>&1)
if grep -qiE 'out of (host )?capacity' <<<"$logs"; then echo "Out of capacity, retrying next run"; exit 0; fi
if grep -qE "$retryable" <<<"$logs"; then echo "Transient Oracle error, retrying next run"; exit 0; fi

echo "$logs" | grep -iE 'error' | head -20
notify "A1 hunter stopped" "Apply failed for a new reason, check the GitHub run. Job: $job" high
stop_hunting; exit 1

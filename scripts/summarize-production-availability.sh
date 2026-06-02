#!/usr/bin/env bash
set -euo pipefail

log=${1:?usage: summarize-production-availability.sh <liveness-log> [interval-seconds] [minimum-days]}
interval_seconds=${2:-300}
minimum_days=${3:-14}

if [[ ! -s $log ]]; then
  printf 'availability log is missing or empty: %s\n' "$log" >&2
  exit 2
fi
if [[ ! $interval_seconds =~ ^[1-9][0-9]*$ || ! $minimum_days =~ ^[0-9]+$ ]]; then
  printf 'interval-seconds must be positive and minimum-days must be a non-negative integer.\n' >&2
  exit 2
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

awk -F '\t' '
  {
    url = ""
    status = ""
    for (i = 2; i <= NF; i++) {
      if ($i ~ /^url=/) {
        url = substr($i, 5)
      }
      if ($i ~ /^status=/) {
        status = substr($i, 8)
      }
    }
    if ($1 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ || url == "" || status == "") {
      printf "malformed availability row %d\n", NR > "/dev/stderr"
      exit 2
    }
    print $1 "\t" url "\t" status
  }
' "$log" > "$tmp"

first_timestamp=
last_timestamp=
first_epoch=
last_epoch=
previous_epoch=
url=
rows=0
healthy_rows=0
unhealthy_rows=0
url_mismatch_rows=0
gap_violations=0
max_gap_seconds=0
max_gap_allowed=$((interval_seconds * 2))

while IFS=$'\t' read -r timestamp row_url status; do
  epoch=$(date -u -d "$timestamp" +%s)
  if [[ -z $first_timestamp ]]; then
    first_timestamp=$timestamp
    first_epoch=$epoch
    url=$row_url
  fi
  if [[ $row_url != "$url" ]]; then
    url_mismatch_rows=$((url_mismatch_rows + 1))
  fi
  if [[ $status == healthy ]]; then
    healthy_rows=$((healthy_rows + 1))
  else
    unhealthy_rows=$((unhealthy_rows + 1))
  fi
  if [[ -n $previous_epoch ]]; then
    gap=$((epoch - previous_epoch))
    if (( gap <= 0 )); then
      printf 'availability timestamps must increase strictly: %s\n' "$timestamp" >&2
      exit 2
    fi
    (( gap > max_gap_seconds )) && max_gap_seconds=$gap
    (( gap > max_gap_allowed )) && gap_violations=$((gap_violations + 1))
  fi
  previous_epoch=$epoch
  last_epoch=$epoch
  last_timestamp=$timestamp
  rows=$((rows + 1))
done < "$tmp"

elapsed_seconds=$((last_epoch - first_epoch))
required_seconds=$((minimum_days * 86400))
status=accepted
if (( elapsed_seconds < required_seconds || unhealthy_rows > 0 || url_mismatch_rows > 0 || gap_violations > 0 )); then
  status=rejected
fi

printf 'url=%s\n' "$url"
printf 'first=%s\nlast=%s\n' "$first_timestamp" "$last_timestamp"
printf 'rows=%d\nhealthy_rows=%d\nunhealthy_rows=%d\n' "$rows" "$healthy_rows" "$unhealthy_rows"
printf 'elapsed_seconds=%d\nrequired_seconds=%d\n' "$elapsed_seconds" "$required_seconds"
printf 'max_gap_seconds=%d\nmax_gap_allowed=%d\ngap_violations=%d\n' "$max_gap_seconds" "$max_gap_allowed" "$gap_violations"
printf 'url_mismatch_rows=%d\nstatus=%s\n' "$url_mismatch_rows" "$status"

[[ $status == accepted ]]

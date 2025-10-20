#!/usr/bin/env bash
set -euo pipefail

# This script updates DNS A records at adm.tools to the current public IP.
# Configuration is read from settings.json located in the same directory as this script.
# settings.json schema (based on settings.example.json):
# {
#   "api_key": "<adm.tools API token>",
#   "domains": {
#     "<record_id>": "optional note",
#     "<record_id2>": "optional note"
#   },
#   "monitor_interval": 3600
# }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/settings.json"

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "ERROR: Settings file not found: $SETTINGS_FILE" >&2
  echo "Create it based on settings.example.json" >&2
  exit 1
fi

# Read api_key
api_key="$(jq -r '.api_key' "$SETTINGS_FILE")"
if [[ -z "$api_key" || "$api_key" == "null" || "$api_key" == "key_is_required" ]]; then
  echo "ERROR: Invalid api_key in $SETTINGS_FILE" >&2
  exit 1
fi

# Read record_ids from domains object keys
mapfile -t record_ids < <(jq -r '.domains | keys[]?' "$SETTINGS_FILE")
if [[ ${#record_ids[@]} -eq 0 ]]; then
  echo "ERROR: No domains/record_id entries found in $SETTINGS_FILE (domains object is empty)." >&2
  exit 1
fi

# Read monitor_interval (seconds). If missing/invalid, default to 3600 and persist to settings.json
monitor_interval="$(jq -r '.monitor_interval // empty' "$SETTINGS_FILE")"
if ! [[ "$monitor_interval" =~ ^[0-9]+$ ]] || [[ "$monitor_interval" -le 0 ]]; then
  monitor_interval=3600
  tmpfile=$(mktemp)
  jq --argjson mi "$monitor_interval" '.monitor_interval = $mi' "$SETTINGS_FILE" > "$tmpfile" && mv "$tmpfile" "$SETTINGS_FILE"
  echo "INFO: monitor_interval not set or invalid. Defaulted to $monitor_interval seconds and saved to $SETTINGS_FILE"
fi

get_public_ip() {
  # Using api.myip.com for a simple JSON response
  curl -s https://api.myip.com/ | jq -r '.ip'
}

update_records() {
  local ip="$1"
  for record_id in "${record_ids[@]}"; do
    # Perform the update call; suppress output but handle HTTP errors via curl's exit code if needed later
    # See https://adm.tools/user/api/#/tab-sandbox/dns/record_edit
    curl -s -X POST \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -H "Authorization: Bearer $api_key" \
      -d "data=$ip&subdomain_id=$record_id&priority=0" \
      "https://adm.tools/action/dns/record_edit" >/dev/null || true
  done
}

public_ip="$(get_public_ip)"
if [[ -z "$public_ip" || "$public_ip" == "null" ]]; then
  echo "ERROR: Failed to determine public IP." >&2
  exit 1
fi

update_records "$public_ip"
echo "Initial update complete for ${#record_ids[@]} record(s) to IP $public_ip"

# Monitor for public IP changes using monitor_interval
while true; do
  new_ip="$(get_public_ip)"
  if [[ -z "$new_ip" || "$new_ip" == "null" ]]; then
    # Skip this round if we couldn't get IP
    :
  else
    if [[ "$new_ip" != "$public_ip" ]]; then
      public_ip="$new_ip"
      # Reload settings in case settings.json changed while we were running
      new_api_key="$(jq -r '.api_key' "$SETTINGS_FILE")"
      if [[ -n "$new_api_key" && "$new_api_key" != "null" && "$new_api_key" != "key_is_required" && "$new_api_key" != "$api_key" ]]; then
        api_key="$new_api_key"
      fi
      # Refresh record_ids from the current settings before updating
      mapfile -t record_ids < <(jq -r '.domains | keys[]?' "$SETTINGS_FILE")
      if [[ ${#record_ids[@]} -eq 0 ]]; then
        echo "WARNING: No domains/record_id entries in $SETTINGS_FILE; skipping updates for this cycle." >&2
      else
        update_records "$public_ip"
        echo "IP changed. Updated ${#record_ids[@]} record(s) to $public_ip"
      fi
    fi
  fi
  # Reload monitor_interval before sleeping, if valid
  maybe_interval="$(jq -r '.monitor_interval // empty' "$SETTINGS_FILE")"
  if [[ "$maybe_interval" =~ ^[0-9]+$ ]] && [[ "$maybe_interval" -gt 0 ]]; then
    monitor_interval="$maybe_interval"
  fi
  sleep "$monitor_interval"
done

#!/usr/bin/env bash
set -euo pipefail

# Interactive setup helper for dynamicDNS
# - Prompts for adm.tools API token and saves it to settings.json
# - Lets you choose a domain, then select A records to manage
# - Writes selected record IDs to settings.json under the "domains" object as { "<id>": "<record>" }
# - Loop continues so you can add records from multiple domains
#
# Requirements: curl, jq

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$SCRIPT_DIR/settings.json"
SETTINGS_EXAMPLE="$SCRIPT_DIR/settings.example.json"

# --- Helpers ---
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required. Please install it." >&2; exit 1; }
}

ensure_settings_file() {
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    if [[ -f "$SETTINGS_EXAMPLE" ]]; then
      cp "$SETTINGS_EXAMPLE" "$SETTINGS_FILE"
    else
      printf '{"api_key":"key_is_required","domains":{}}\n' > "$SETTINGS_FILE"
    fi
    echo "Created $SETTINGS_FILE"
  fi
}

get_api_key() {
  jq -r '.api_key // ""' "$SETTINGS_FILE"
}

set_api_key() {
  local key="$1"
  tmpfile=$(mktemp)
  jq --arg k "$key" '.api_key = $k' "$SETTINGS_FILE" > "$tmpfile" && mv "$tmpfile" "$SETTINGS_FILE"
}

get_monitor_interval() {
  jq -r '.monitor_interval // ""' "$SETTINGS_FILE"
}

set_monitor_interval() {
  local mi="$1"
  tmpfile=$(mktemp)
  jq --argjson v "$mi" '.monitor_interval = $v' "$SETTINGS_FILE" > "$tmpfile" && mv "$tmpfile" "$SETTINGS_FILE"
}

# Configure monitor_interval with optional provided value; includes rate-limit advisory
configure_monitor_interval() {
  local provided_mi="${1:-}"
  echo
  echo "=== Monitor interval configuration ==="
  # Count selected records currently in settings.json (may be 0 before selections)
  local rec_count
  rec_count=$(jq -r '(.domains | keys | length) // 0' "$SETTINGS_FILE")
  echo "You currently have $rec_count managed A record(s) in settings.json."

  local mi
  if [[ -n "$provided_mi" && "$provided_mi" =~ ^[0-9]+$ ]] && [[ "$provided_mi" -gt 0 ]]; then
    mi="$provided_mi"
  else
    # Get current value (if any)
    local current_mi
    current_mi="$(get_monitor_interval)"
    if [[ -n "$current_mi" && "$current_mi" =~ ^[0-9]+$ && "$current_mi" -gt 0 ]]; then
      echo "A monitor_interval is already set to $current_mi seconds."
      local ans
      ans=$(prompt "Do you want to keep it? [Y/n]: ")
      if [[ "${ans,,}" == "n" || "${ans,,}" == "no" ]]; then
        while :; do
          mi=$(prompt "Enter monitor interval in seconds (default 3600): ")
          [[ -z "$mi" ]] && mi=3600
          if [[ "$mi" =~ ^[0-9]+$ ]] && [[ "$mi" -gt 0 ]]; then
            break
          else
            echo "Please enter a positive integer."
          fi
        done
      else
        mi=$current_mi
      fi
    else
      while :; do
        mi=$(prompt "Enter monitor interval in seconds (default 3600): ")
        [[ -z "$mi" ]] && mi=3600
        if [[ "$mi" =~ ^[0-9]+$ ]] && [[ "$mi" -gt 0 ]]; then
          break
        else
          echo "Please enter a positive integer."
        fi
      done
    fi
  fi

  # Rate limit advisory (worst-case: IP changes every check)
  # adm.tools limits: 3600/hour, 28800/day. We warn at >50%: 1800/hour, 14400/day.
  if [[ "$rec_count" =~ ^[0-9]+$ ]] && [[ "$rec_count" -gt 0 ]]; then
    local calls_per_hour calls_per_day
    calls_per_hour=$(awk -v r="$rec_count" -v m="$mi" 'BEGIN{ printf "%.2f", (3600.0/m)*r }')
    calls_per_day=$(awk -v r="$rec_count" -v m="$mi" 'BEGIN{ printf "%.2f", (86400.0/m)*r }')
    local over_hour over_day suggested min_hour min_day
    over_hour=$(awk -v c="$calls_per_hour" 'BEGIN{ print (c>1800)?1:0 }')
    over_day=$(awk -v c="$calls_per_day" 'BEGIN{ print (c>14400)?1:0 }')
    if [[ "$over_hour" -eq 1 || "$over_day" -eq 1 ]]; then
      echo
      echo "WARNING: With the current configuration (interval: ${mi}s, records: ${rec_count}), worst-case adm.tools API usage exceeds 50% of rate limits."
      echo "- Calls per hour (worst-case): ${calls_per_hour} (limit@50%: 1800)"
      echo "- Calls per day  (worst-case): ${calls_per_day} (limit@50%: 14400)"
      min_hour=$(((3600*rec_count + 1800 - 1) / 1800))
      min_day=$(((86400*rec_count + 14400 - 1) / 14400))
      if (( min_day > min_hour )); then suggested=$min_day; else suggested=$min_hour; fi
      if (( suggested < 3600 )); then suggested=3600; fi
      echo "Suggested monitor_interval to stay within 50%: ${suggested} seconds."
      local ans
      ans=$(prompt "Apply suggested value now? [Y/n]: ")
      if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" || -z "$ans" ]]; then
        mi=$suggested
        echo "monitor_interval set to $mi seconds."
      else
        ans=$(prompt "Enter a different interval in seconds, or press Enter to keep ${mi}: ")
        if [[ -n "$ans" && "$ans" =~ ^[0-9]+$ && "$ans" -gt 0 ]]; then
          mi=$ans
        fi
      fi
    fi
  fi

  set_monitor_interval "$mi"
  echo "monitor_interval saved to $SETTINGS_FILE as $mi second(s)."
}

merge_domains_object_from_file() {
  # $1: path to a JSON file containing an object with id=>record pairs
  local add_file="$1"
  tmpfile=$(mktemp)
  jq --slurpfile add "$add_file" '.domains = (.domains // {}) | .domains += $add[0]' "$SETTINGS_FILE" > "$tmpfile" && mv "$tmpfile" "$SETTINGS_FILE"
}

prompt() {
  # $1 message
  read -r -p "$1" REPLY
  echo "$REPLY"
}

press_enter() {
  read -r -p "Press Enter to continue..." _
}

# --- API ---
api_domains_list() {
  local token="$1"
  curl -sS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "by=asc&domains_search_request=&p=1&page=1&sort=name&tag_free=&tag_id=" \
    "https://adm.tools/action/dns/list/"
}

api_records_list() {
  local token="$1" domain_id="$2"
  curl -sS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "domain_id=$domain_id" \
    "https://adm.tools/action/dns/records_list/"
}

# Parse domain list JSON -> tab-separated lines: domain_id\tname
parse_domains() {
  jq -r 'select(.result == true) | .response.list | to_entries[] | "\(.value.domain_id)\t\(.key)"'
}

# Parse A records -> tab-separated lines: id\trecord\tdata
parse_a_records() {
  jq -r 'select(.result == true) | .response.list // [] | map(select(.type == "A")) | .[] | "\(.id)\t\(.record)\t\(.data)"'
}

# --- Main flow ---
main() {
  need_cmd curl
  need_cmd jq
  ensure_settings_file

  # Simple CLI: --set-interval [seconds]
  if [[ ${1:-} == "--set-interval" ]]; then
    shift || true
    local provided_mi="${1:-}"
    configure_monitor_interval "$provided_mi"
    echo "Setup complete. You can now run: bash dyndns.sh"
    return 0
  fi

  local current_key
  current_key="$(get_api_key)"

  echo "=== dynamicDNS setup ==="
  if [[ -n "$current_key" && "$current_key" != "key_is_required" ]]; then
    echo "An API token is already set in settings.json."
    local ans
    ans=$(prompt "Do you want to keep it? [Y/n]: ")
    if [[ "${ans,,}" == "n" || "${ans,,}" == "no" ]]; then
      while :; do
        local new_key
        new_key=$(prompt "Enter new adm.tools API token (from https://adm.tools/user/api/): ")
        if [[ -n "$new_key" ]]; then
          set_api_key "$new_key"
          current_key="$new_key"
          echo "API token updated in $SETTINGS_FILE"
          break
        else
          echo "Token cannot be empty."
        fi
      done
    else
      echo "Keeping existing token."
    fi
  else
    echo "No API token configured."
    while :; do
      local new_key
      new_key=$(prompt "Enter adm.tools API token (from https://adm.tools/user/api/): ")
      if [[ -n "$new_key" ]]; then
        set_api_key "$new_key"
        current_key="$new_key"
        echo "API token saved to $SETTINGS_FILE"
        break
      else
        echo "Token cannot be empty."
      fi
    done
  fi

  # --- monitor_interval configuration and rate-limit advisory (moved before domain loop) ---
  configure_monitor_interval ""

  # Domain/record selection loop
  while :; do
    echo
    echo "=== Domain selection ==="
    echo "Fetching your domains..."
    local djson
    if ! djson=$(api_domains_list "$current_key"); then
      echo "ERROR: Failed to fetch domains. Check your network." >&2
      press_enter; continue
    fi
    local domains
    if ! domains=$(echo "$djson" | parse_domains); then
      echo "ERROR: Unable to parse domain list." >&2
      press_enter; continue
    fi

    if [[ -z "$domains" ]]; then
      # Could be invalid token or no domains
      if [[ "$(echo "$djson" | jq -r '.result // false')" != "true" ]]; then
        echo "ERROR: API returned an error. Is your token valid?"
        echo "$djson" | jq -r '.messages // empty | @json' || true
      else
        echo "No domains found for this account."
      fi
      press_enter; break
    fi

    # Show numbered list
    mapfile -t dom_lines < <(echo "$domains")
    for i in "${!dom_lines[@]}"; do
      did="${dom_lines[$i]%$'\t'*}"          # domain_id
      dname="${dom_lines[$i]#*$'\t'}"       # domain name
      printf "[%d] %s (domain_id: %s)\n" "$((i+1))" "$dname" "$did"
    done
    echo "[0] Exit"

    local choice
    choice=$(prompt "Select a domain by number (or 0 to exit): ")
    if [[ "$choice" == "0" ]]; then
      echo "Exiting setup."
      break
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#dom_lines[@]} )); then
      echo "Invalid choice."
      continue
    fi

    local sel_index=$((choice-1))
    local sel_line="${dom_lines[$sel_index]}"
    local domain_id="${sel_line%$'\t'*}"
    local domain_name="${sel_line#*$'\t'}"

    echo
    echo "=== A records for $domain_name (domain_id $domain_id) ==="
    local rjson
    if ! rjson=$(api_records_list "$current_key" "$domain_id"); then
      echo "ERROR: Failed to fetch records."
      press_enter; continue
    fi

    local records
    records=$(echo "$rjson" | parse_a_records || true)
    if [[ -z "$records" ]]; then
      echo "No A records found for this domain or API returned error."
      press_enter; continue
    fi

    mapfile -t rec_lines < <(echo "$records")
    for i in "${!rec_lines[@]}"; do
      IFS=$'\t' read -r rid rname rdata <<< "${rec_lines[$i]}"
      printf "[%d] %s (id: %s, current: %s)\n" "$((i+1))" "$rname" "$rid" "$rdata"
    done
    echo "Enter record numbers to add (comma/space-separated), or 0 to cancel."
    local sel
    sel=$(prompt "> ")
    if [[ "$sel" == "0" ]]; then
      continue
    fi

    # Normalize separators -> spaces
    sel=${sel//,/ }
    # Build selection set
    declare -A pick=()
    for tok in $sel; do
      [[ -z "$tok" ]] && continue
      if [[ "$tok" =~ ^[0-9]+$ ]]; then
        idx=$((tok-1))
        if (( idx >=0 && idx < ${#rec_lines[@]} )); then
          IFS=$'\t' read -r rid rname rdata <<< "${rec_lines[$idx]}"
          pick["$rid"]="$rname"
        fi
      fi
    done

    if (( ${#pick[@]} == 0 )); then
      echo "Nothing selected."
      continue
    fi

    # Prepare JSON object to merge
    tmpadd=$(mktemp)
    {
      echo '{'
      first=1
      for rid in "${!pick[@]}"; do
        [[ $first -eq 0 ]] && echo ',' || true
        first=0
        printf '"%s":"%s"' "$rid" "${pick[$rid]}"
      done
      echo '}'
    } > "$tmpadd"

    merge_domains_object_from_file "$tmpadd"
    rm -f "$tmpadd"

    echo "Added ${#pick[@]} record(s) to settings.json under .domains"

    # Ask to continue or exit
    ans=$(prompt "Do you want to select another domain? [Y/n]: ")
    if [[ "${ans,,}" == "n" || "${ans,,}" == "no" ]]; then
      echo "Setup complete. You can now run: bash dyndns.sh"
      break
    fi
  done

}

main "$@"

# Dynamic DNS updater for ukraine.com.ua-managed domains

A simple utility that keeps selected DNS A records pointing to your current public IP address using the adm.tools API provided by the ukraine.com.ua domain provider.

> Note
> - This is a community project, not an official tool from ukraine.com.ua or adm.tools.
> - Use at your own discretion. Review the code and the API permissions you grant.

## What it does
- Reads your adm.tools API token and a list of DNS record IDs from `settings.json`.
- Updates those A records to your current public IP address.
- Continues running and checks every 60 minutes by default; if your IP changes, it updates the records again.

## Requirements
- Ubuntu (tested on recent Ubuntu with GNOME)
- `curl` and `jq` installed

## Installation (Ubuntu)
1. Clone the repository or download the ZIP archive.
2. Prepare `settings.json` (choose one):
   - Recommended: interactive helper
     ```bash
     bash setup.sh
     ```
     Then:
     - Paste your adm.tools API token (get it from https://adm.tools/user/api/).
     - Select your domain and then select one or more A records to manage.
     - The script writes the chosen record IDs into `settings.json` under the `"domains"` object.

   - Manual setup (advanced)
     ```bash
     cp settings.example.json settings.json
     ```
     Edit `settings.json` and set:
     ```json
     {
       "api_key": "<your_adm.tools_api_token>",
       "domains": {
         "<record_id_1>": "optional note",
         "<record_id_2>": "optional note"
       }
     }
     ```
     The keys in the `domains` object are the `record_id` values of the A records you want to keep in sync.

3. Configure Startup Applications (run on login)
   - Ensure the script is executable:
     ```bash
     chmod +x dyndns.sh
     ```
   - Open Startup Applications Preferences (on Ubuntu GNOME):
     - Press the Super key and search for "Startup Applications" (you may need to install `gnome-startup-applications` if not present).
     - Click "Add" and fill in:
       - Name: Dynamic DNS Updater
       - Command:
         ```bash
         /bin/bash -lc "/full/path/to/dynamicDNS/dyndns.sh"
         ```
       - Comment: Keep A records in sync with my public IP
     - Replace `/full/path/to/dynamicDNS` with your actual path.

4. Run once manually (first run)
   - In the repository directory, run:
     ```bash
     bash dyndns.sh
     ```
   - This performs the initial update immediately. On subsequent logins, it will start automatically via Startup Applications.

## Notes
- The script uses https://api.myip.com/ to detect your public IP.
- If you change `settings.json` while the updater is running, it will apply the new `api_key` and record IDs on the next IP change cycle.
- You can re-run `bash setup.sh` anytime to adjust the configuration.
- To adjust the monitoring interval quickly, you can run:
  ```bash
  bash setup.sh --set-interval
  # or provide a value directly
  bash setup.sh --set-interval 600
  ```

## Files
- `dyndns.sh` — the background updater.
- `setup.sh` — interactive configuration helper (supports `--set-interval` to set `monitor_interval`).
- `settings.example.json` — template for manual configuration.
- `settings.json` — your local configuration (not tracked by VCS, usually).

## License
This project is licensed under the terms of the LICENSE file included in this repository.

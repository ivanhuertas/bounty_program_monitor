#!/bin/bash

# --- Configuration ---
H1_HANDLES_FILE="/root/programs/automation/h1_scan_handles.txt"
H1_ASSETS_FILE="/root/programs/automation/h1_scan_assets.txt"
FRESH_TARGETS_FILE="/root/programs/automation/h1_scan_fresh_targets.txt"
SCAN_BASE_DIR="/root/programs/automation/scans" # Base directory to store program scan files
WILDCARDS_FILENAME="wildcards"                 # Filename for wildcard domains per program
# Replace with your actual H1 token
H1_TOKEN="<TU_TOKEN>"
# Replace with your actual H1 username (often just your token is enough, but included as per your script)
H1_USERNAME="<TU_HANDLE>"

# --- Your Scan Command Configuration ---
# Replace this with your actual scan command.
# The variable ${scan_file} will contain the path to the file
# containing the base domains for the program, one per line.
# Example using subfinder: SCAN_CMD_TEMPLATE='subfinder -dL ${scan_file} -o ${scan_file}.subs'
# Example using massdns: SCAN_CMD_TEMPLATE='massdns -r /path/to/resolvers.txt -w ${scan_file}.massdns ${scan_file} -t A'
# Example using httpx: SCAN_CMD_TEMPLATE='httpx -l ${scan_file} -o ${scan_file}.httpx'
# Example using a custom script: SCAN_CMD_TEMPLATE='/path/to/your/scan_script.sh ${scan_file}'

# --- !!! REPLACE THIS WITH YOUR ACTUAL SCAN COMMAND TEMPLATE !!! ---
# This is a placeholder that just echoes the command it would run
SCAN_CMD_TEMPLATE='echo dummy_command'

# Temporary file to store paths of updated wildcard files in this run
# Using $$ to create a unique file name for this specific script instance
UPDATED_WILDCARD_FILES_TEMP="/tmp/updated_wildcard_files_$$.txt"

# --- Script Start ---
echo "INFO: Starting HackerOne asset fetch and processing at $(date)"

# Clean up old files
echo "INFO: Cleaning up old files..."
rm -f "${H1_HANDLES_FILE}" "${H1_ASSETS_FILE}"

# Fetch handles
echo "INFO: Fetching program handles..."
i=0
# Increased loop count slightly just in case, adjust as needed based on total programs
while [ $i -lt 10 ]; do # Fetch up to 1000 programs (10 pages * 100)
    echo "INFO: Fetching page $i of handles..."
    curl "https://api.hackerone.com/v1/hackers/programs?page\[size\]=100&page\[number\]=$i" -X GET -u "${H1_USERNAME}:${H1_TOKEN}" -H 'Accept: application/json' --silent | jq -r '.data[].attributes.handle' >> "${H1_HANDLES_FILE}"
    # Check if jq found any handles on this page. If not, we're probably at the end.
    if [ $? -ne 0 ] || [ ! -s "${H1_HANDLES_FILE}" ] && [ $i -gt 0 ]; then
       # If jq failed (exit status != 0), or if the file is empty after the first page, break
       echo "INFO: No more handles found or fetch error on page $i. Breaking."
       break
    fi
    ((i = i + 1))
    sleep 0.5 # Be polite to the API
done
echo "INFO: Finished retrieving handles."

# Fetch assets for each handle
echo "INFO: Fetching assets for handles..."
# Check if handle file exists and has content before reading
if [ -s "${H1_HANDLES_FILE}" ]; then
    while read -r linea; do
        # Skip empty lines
        if [ -z "$linea" ]; then
            continue
        fi
        echo "INFO: Retrieving assets for program: $linea"
        curl "https://api.hackerone.com/v1/hackers/programs/$linea" -X GET -u "${H1_USERNAME}:${H1_TOKEN}" -H 'Accept: application/json' --silent \
        | jq -r '.relationships.structured_scopes.data[] | [.attributes.asset_type, .attributes.asset_identifier, .attributes.created_at, .attributes.eligible_for_submission, .attributes.eligible_for_bounty] | @csv' \
        | awk -v linea="$linea" -F',' '{print linea "," $0}' >> "${H1_ASSETS_FILE}"
        sleep 0.2 # Be polite to the API
    done < "${H1_HANDLES_FILE}"
else
    echo "ERROR: No handles found in ${H1_HANDLES_FILE}. Cannot fetch assets."
    exit 1
fi

echo "INFO: Finished retrieving assets."

# --- Process assets: find new, filter wildcards, update files, launch scans ---

# Add header to fresh targets file (optional, but matches original)
echo "###### Run $(date +'%Y-%m-%d %H:%M:%S') #######" >> "${FRESH_TARGETS_FILE}"

echo "INFO: Processing assets for new targets and wildcards..."

# The core pipeline:
# 1. Filter h1_assets.txt for today's date and active/in-scope ('true,true')
# 2. Use anew to find lines that are *new* to h1_fresh_targets.txt
# 3. Use tee to send the output of anew to TWO places:
#    a. The original 'notify' command (using process substitution >(notify))
#    b. The rest of the pipeline (stdout of tee) for wildcard processing
# 4. Use awk to filter for WILDCARD types, extract program and cleaned domain, print "program|domain"
# 5. Use a while loop to read the "program|domain" lines
# 6. Inside the while loop: create program directory, check if domain exists, append if new, record updated file path
grep "$(date +"%Y-%m-%d")" "${H1_ASSETS_FILE}" | grep 'true,true' | anew "${FRESH_TARGETS_FILE}" | tee >(notify) | awk -F',' '   # Set field separator to comma
  # Only process lines where the second field (asset type) is exactly "WILDCARD" (quoted)
  $2 == "\"WILDCARD\"" {
      # Field 1 is the program name (added by awk earlier)
      program = $1;

      # Field 3 is the asset value (the domain string, quoted) from the original CSV
      # Note: Awk added the program name at the start, shifting fields. The original asset_type is $2, asset_identifier is $3 etc.
      # So the asset identifier is actually the *third* field relative to the *original* jq output.
      # Since we added the program name, the fields are now: 1=program, 2=asset_type, 3=asset_identifier...
      asset = $3;

      # Remove surrounding quotes from the asset value
      gsub(/"/, "", asset);

      # Remove leading "*. " or "https://*. " from the asset value
      # This regex matches optional "https://" followed by optional "*/" then optional "*" followed by optional "." at the start
      # It effectively cleans up "*.domain.com" and "https://*.domain.com" to "domain.com"
      sub(/^(https:\/\/)?\*\.?/, "", asset);

      # Print the program and the cleaned domain, separated by a pipe (|)
      print program "|" asset;
  }' \
| while IFS='|' read -r program domain; do
    # Check if program or domain is empty before proceeding
    if [ -z "$program" ] || [ -z "$domain" ]; then
        echo "WARNING: Skipped processing due to empty program or domain (program='$program', domain='$domain')"
        continue
    fi

    # Construct the full path for the wildcards file for this program
    program_wildcards_file="${SCAN_BASE_DIR}/${program}/${WILDCARDS_FILENAME}";

    # Create the program directory if it doesn't exist (-p does not error if exists)
    mkdir -p "$(dirname "${program_wildcards_file}")";

    # Append the extracted base domain to the wildcards file
    # Using grep -q to check if domain already exists in file to avoid duplicates
    # The -- makes grep treat '-something.com' as a pattern, not an option
    if ! grep -qxF -- "${domain}" "${program_wildcards_file}" 2>/dev/null; then
        echo "${domain}" >> "${program_wildcards_file}";
#        echo "INFO: Added new wildcard domain '${domain}' for program '${program}' to ${program_wildcards_file}";
        # Record the path of the file that was updated
        # Using sort and uniq later ensures we only scan each file once per run
        echo "${program_wildcards_file}" >> "${UPDATED_WILDCARD_FILES_TEMP}"
    else
        # echo "INFO: Wildcard domain '${domain}' for program '${program}' already exists in ${program_wildcards_file}. Skipping append."
        : # Do nothing, keep output clean if no new wildcards added to existing files
    fi
  done



echo "INFO: Finished processing new targets and wildcards."

# --- Launch Scans for Files that were just updated ---
# Read the list of updated files from the temporary file
# Using sort -u to get a unique list of files to scan in this run
if [ -s "${UPDATED_WILDCARD_FILES_TEMP}" ]; then # Check if the temp file exists and has content
    echo "INFO: Launching scans for updated wildcard files..."
    sort -u "${UPDATED_WILDCARD_FILES_TEMP}" | while read -r scan_file; do
        if [ -f "${scan_file}" ]; then # Double check file exists before attempting scan
            program_name=$(basename "$(dirname "${scan_file}")");
            program_scan_dir=$(dirname "${scan_file}") # Get the directory for this program's scans

            echo "INFO: Initiating scan process for program '${program_name}' using targets in ${scan_file}";

            # Define the full command template for the pipeline
            # Using single quotes to prevent immediate shell expansion
            # Using literal variable names like ${program_scan_dir}
            #full_scan_pipeline_template='axiom-scan "${program_scan_dir}"/wildcards -m subfinder -o "${program_scan_dir}"/results_subfinder;'
            # Substitute the program_scan_dir variable into the template
            # Simple replacement of the literal ${program_scan_dir} string

            #command_to_run="${full_scan_pipeline_template//\${program_scan_dir}/${program_scan_dir}}"

            echo "DEBUG: Command to run: $command_to_run" # Optional: for debugging

            # Define the temporary script file name within the program's directory
            # Using $$ for a unique name (safer if parallel execution is possible)
            # Or without $$ if you are certain of single instance
            #SCAN_SCRIPT_FILE="${program_scan_dir}/scan_script_${program_name}_$$.sh" # With $$
            SCAN_SCRIPT_FILE="${program_scan_dir}/scan_script_${program_name}.sh" # Without $$

            echo "INFO: Writing scan command to script: ${SCAN_SCRIPT_FILE}"

            # Write the FULLY SUBSTITUTED command_to_run string to the temporary script file
            #echo "#!/bin/bash" > "${SCAN_SCRIPT_FILE}" # Add shebang
            #echo "# Generated scan script for program ${program_name} at $(date)" >> "${SCAN_SCRIPT_FILE}"
            #echo "$command_to_run" >> "${SCAN_SCRIPT_FILE}" # THIS IS THE KEY CHANGE

cat > "${SCAN_SCRIPT_FILE}" << EOF
axiom-scan "${program_scan_dir}/wildcards" -m subfinder -o "${program_scan_dir}/subdomains" 
axiom-scan "${program_scan_dir}/subdomains" -m puredns-resolve -o "${program_scan_dir}/domains_without_wildcards" 
axiom-scan "${program_scan_dir}/domains_without_wildcards" -m httpx -sc -fr -td -title -o "${program_scan_dir}/results_httpx" 
awk '{print \$1}' "${program_scan_dir}/results_httpx" > "${program_scan_dir}/hosts" 
axiom-scan "${program_scan_dir}/hosts" -m nuclei -exclude-tags ssl  -severity info -o "${program_scan_dir}/nuclei_info" 
axiom-scan "${program_scan_dir}/domains_without_wildcards" -m naabu  -top-ports 1000 -exclude-ports 80,443,21,22,25 -o "${program_scan_dir}/naabu_not_default" 
axiom-scan "${program_scan_dir}/naabu_not_default" -m httpx -o "${program_scan_dir}/httpx_naabu_not_default" ; axiom-scan "${program_scan_dir}/httpx_naabu_not_default" -m nuclei -exclude-tags ssl  -o nuclei_not_default 
echo 'Finished "${program_scan_dir}/httpx_naabu_not_default"' | notify
EOF

            # Make the script executable
            chmod +x "${SCAN_SCRIPT_FILE}"

            echo "INFO: Executing generated scan script: ${SCAN_SCRIPT_FILE}"

            # Execute the generated script in the background
            "${SCAN_SCRIPT_FILE}" &
            scan_pid=$! # Get PID of the background script
            echo "INFO: Scan command launched for ${program_name} with PID ${scan_pid} via script ${SCAN_SCRIPT_FILE}."
        else
            echo "WARNING: Scan file not found during scan phase: ${scan_file}"
        fi
        # No sleep here, letting scans potentially run concurrently if SCAN_CMD_TEMPLATE ends with &
    done

    # Optional: Wait for background scans to finish
    # echo "INFO: Waiting for background scans to complete..."
    # wait
    # echo "INFO: All background scans finished."

else
    echo "INFO: No new wildcard targets found or processed in this run. No scans initiated for wildcards."
fi

# --- Clean up the temporary file ---
echo "INFO: Cleaning up temporary file ${UPDATED_WILDCARD_FILES_TEMP}"
rm -f "${UPDATED_WILDCARD_FILES_TEMP}"

echo "INFO: Script finished at $(date)."

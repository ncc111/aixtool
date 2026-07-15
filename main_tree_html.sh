#!/usr/bin/ksh

# ==============================================================================
# Script Name: main_tree_html.sh
# Description: Orchestrates the execution of vnic, vscsi, and npiv tree scripts
#              with strict error checking and logging. (KSH88 Compatible)
# ==============================================================================

# Define log file with a timestamp in the name for uniqueness
LOG_FILE="/tmp/main_tree_html_$(date +%Y%m%d_%H%M%S).log"

# Define the scripts to be executed in order (Standard KSH88 Array Assignment)
SCRIPTS[0]="/home/padmin/vnic_tree_html_diagram.sh"
SCRIPTS[1]="/home/padmin/vscsi_tree_html_diagram.sh"
SCRIPTS[2]="/home/padmin/npiv_tree_html_diagram.sh"

# Function to log messages to both the console and the log file
log_message() {
    print "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOG_FILE}"
}

# --- Initialization ---
touch "${LOG_FILE}"
if [[ $? -ne 0 ]]; then
    print "Error: Cannot write to log directory /tmp/" >&2
    exit 1
fi

log_message "INFO: Starting orchestration script execution."
START_TIME=$(date +%s)

# --- Pre-execution Checks ---
log_message "INFO: Performing pre-execution checks on target scripts..."

# Loop through the array indexes manually for KSH88 compatibility
i=0
while [[ $i -lt 3 ]]; do
    script="${SCRIPTS[$i]}"
    
    # Check if file exists
    if [[ ! -f "${script}" ]]; then
        log_message "ERROR: Script file does not exist: ${script}"
        log_message "STATUS: Execution aborted due to pre-check failure."
        exit 1
    fi

    # Check if file is executable
    if [[ ! -x "${script}" ]]; then
        log_message "ERROR: Script is not executable (permissions issue): ${script}"
        log_message "STATUS: Execution aborted due to pre-check failure."
        exit 1
    fi
    
    i=$((i + 1))
done

log_message "INFO: All pre-checks passed successfully."

# --- Script Execution ---
i=0
while [[ $i -lt 3 ]]; do
    script="${SCRIPTS[$i]}"
    log_message "INFO: Running ${script}..."
    
    # Run the script, capturing all stdout and stderr to the log file
    "${script}" >> "${LOG_FILE}" 2>&1
    RC=$?

    if [[ ${RC} -ne 0 ]]; then
        log_message "ERROR: ${script} failed with exit code ${RC}."
        log_message "STATUS: Execution halted due to an error."
        exit ${RC}
    fi
    
    log_message "INFO: Successfully completed ${script}."
    i=$((i + 1))
done

# --- Finalization ---
END_TIME=$(date +%s)
ELAPSED_TIME=$(( END_TIME - START_TIME ))

log_message "INFO: All scripts executed successfully."
log_message "INFO: Total elapsed time: ${ELAPSED_TIME} seconds."
log_message "STATUS: Execution completed. Log saved to: ${LOG_FILE}"

exit 0

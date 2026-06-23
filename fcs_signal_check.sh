#!/bin/ksh
#
# Script: fcs_signal_check.ksh
# Purpose: List all FCS ports and their signal levels on VIOS
# Output: /tmp/fcsignal/fcs_signal_report_<timestamp>.txt
#

# Set output directory
OUTPUT_DIR="/tmp/fcsignal"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/fcs_signal_report_${TIMESTAMP}.txt"

# Create output directory if it doesn't exist
if [[ ! -d ${OUTPUT_DIR} ]]; then
    mkdir -p ${OUTPUT_DIR}
    if [[ $? -ne 0 ]]; then
        print "ERROR: Failed to create directory ${OUTPUT_DIR}"
        exit 1
    fi
fi

# Initialize output file with header
print "FCS Port Signal Level Report" > ${OUTPUT_FILE}
print "Generated: $(date)" >> ${OUTPUT_FILE}
print "Hostname: $(hostname)" >> ${OUTPUT_FILE}
print "=" | awk '{for(i=1;i<=80;i++)printf "="}' >> ${OUTPUT_FILE}
print "" >> ${OUTPUT_FILE}

# Get list of all FCS adapters using lscfg
print "Scanning for FCS adapters..."
FCS_LIST=$(lscfg | grep -i fcs | awk '{print $2}')

if [[ -z ${FCS_LIST} ]]; then
    print "WARNING: No FCS adapters found on this system" | tee -a ${OUTPUT_FILE}
    exit 0
fi

# Counter for adapters
ADAPTER_COUNT=0
ERROR_COUNT=0

# Loop through each FCS adapter
for FCS in ${FCS_LIST}; do
    ADAPTER_COUNT=$((ADAPTER_COUNT + 1))
    
    print "\nProcessing ${FCS}..."
    print "\n" >> ${OUTPUT_FILE}
    print "FCS Adapter: ${FCS}" >> ${OUTPUT_FILE}
    print "-" | awk '{for(i=1;i<=80;i++)printf "-"}' >> ${OUTPUT_FILE}
    print "" >> ${OUTPUT_FILE}
    
    # Check if adapter is available
    ADAPTER_STATE=$(lsdev -l ${FCS} -F status 2>/dev/null)
    if [[ -n ${ADAPTER_STATE} ]]; then
        print "Status: ${ADAPTER_STATE}" >> ${OUTPUT_FILE}
    fi
    
    if [[ "${ADAPTER_STATE}" != "Available" && -n ${ADAPTER_STATE} ]]; then
        print "WARNING: Adapter ${FCS} is not in Available state" >> ${OUTPUT_FILE}
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    
    # Get fcstat -e output for the adapter
    print "\nSignal Level Information:" >> ${OUTPUT_FILE}
    fcstat -e ${FCS} >> ${OUTPUT_FILE} 2>&1
    
    if [[ $? -ne 0 ]]; then
        print "ERROR: Failed to retrieve fcstat information for ${FCS}" >> ${OUTPUT_FILE}
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    print "" >> ${OUTPUT_FILE}
done

# Summary
print "\n" >> ${OUTPUT_FILE}
print "=" | awk '{for(i=1;i<=80;i++)printf "="}' >> ${OUTPUT_FILE}
print "" >> ${OUTPUT_FILE}
print "Summary:" >> ${OUTPUT_FILE}
print "  Total FCS adapters found: ${ADAPTER_COUNT}" >> ${OUTPUT_FILE}
print "  Errors encountered: ${ERROR_COUNT}" >> ${OUTPUT_FILE}
print "  Report saved to: ${OUTPUT_FILE}" >> ${OUTPUT_FILE}
print "" >> ${OUTPUT_FILE}

# Display completion message
print "\n=========================================="
print "FCS Signal Level Check Complete"
print "=========================================="
print "Total FCS adapters processed: ${ADAPTER_COUNT}"
print "Errors encountered: ${ERROR_COUNT}"
print "Report saved to: ${OUTPUT_FILE}"
print "==========================================\n"

exit 0

# Made with Bob

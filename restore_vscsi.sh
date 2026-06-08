#!/usr/bin/ksh
# IBM VIOS VSCSI Configuration Restore Script
# Utilizes Location Codes for accurate vhost mapping

INPUT_FILE=$1

# Safety feature: Set to 0 to execute the mkvdev commands. 
# Left as 1, it will only print what it intends to do.
DRY_RUN=1 

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
    echo "Usage: $0 <path_to_vscsi_config.txt>"
    exit 1
fi

echo "========================================================="
echo " Starting VSCSI Restoration Verification"
echo " Input File: $INPUT_FILE"
[[ $DRY_RUN -eq 1 ]] && echo " *** DRY RUN MODE: No configuration changes will be made ***"
echo "========================================================="

# Process lines, skipping headers and comments
grep -v '^#' "$INPUT_FILE" | grep -v '^---' | grep ':' | while IFS=":" read -r physloc clientid vtd backing; do
    
    # Strip whitespace to ensure exact matches
    physloc=$(echo "$physloc" | tr -d ' ')
    vtd=$(echo "$vtd" | tr -d ' ')
    backing=$(echo "$backing" | tr -d ' ')
    
    # Skip malformed lines
    if [[ -z "$physloc" || -z "$backing" ]]; then
        continue
    fi

    # Lookup the CURRENT vhost logical name based on the location code
    curr_vhost=$(/usr/ios/cli/ioscli lsdev -field name physloc | grep -w "$physloc" | awk '{print $1}')
    
    if [[ -z "$curr_vhost" ]]; then
        echo "[ERROR] No virtual adapter found at Physloc: $physloc (Client ID: $clientid)"
        continue
    fi
    
    # Verify the backing device (hdisk, lv, etc.) exists on the target VIOS
    /usr/ios/cli/ioscli lsdev -dev "$backing" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] Backing device $backing does not exist. Ensure LUNs are mapped or LVs are created first."
        continue
    fi
    
    # Verify the Virtual Target Device (VTD) name isn't already in use
    /usr/ios/cli/ioscli lsdev -dev "$vtd" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo "[WARNING] VTD name $vtd already exists on the system. Skipping..."
        continue
    fi

    # Execution Block
    echo "Mapping intended for Client ID $clientid:"
    echo "  Command: mkvdev -vdev $backing -vadapter $curr_vhost -dev $vtd"
    
    if [[ $DRY_RUN -eq 0 ]]; then
        mkvdev -vdev "$backing" -vadapter "$curr_vhost" -dev "$vtd"
        if [[ $? -eq 0 ]]; then
            echo "  [SUCCESS] Mapped $backing to $curr_vhost"
        else
            echo "  [FAILED] Error mapping VSCSI. Check VIOS errpt."
        fi
    fi
    echo "---------------------------------------------------------"

done

echo "VSCSI Restoration script completed."

#!/usr/bin/ksh
# IBM VIOS NPIV Restore Script
# Maps virtual adapters using VIO Virtual loc and Phys FC name.
# Updated to ensure compatibility with the restricted padmin shell.

INPUT_FILE=$1

# Safety feature: Set to 0 to execute the vfcmap commands. 
# Left as 1, it will only print the intended operations.
DRY_RUN=1 

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
    echo "Usage: $0 <path_to_backup_file.txt>"
    exit 1
fi

echo "========================================================="
echo " Starting NPIV Restoration Verification"
echo " Input File: $INPUT_FILE"
[[ $DRY_RUN -eq 1 ]] && echo " *** DRY RUN MODE: No changes will be made ***"
echo "========================================================="

# Process lines starting with 'vfchost'
grep -E '^vfchost' "$INPUT_FILE" | while IFS=":" read -r name vio_virt_loc clntid clntname phys_fc_name rest; do
    
    # Strip whitespace to ensure clean variable assignment
    vio_virt_loc=$(echo "$vio_virt_loc" | tr -d ' ')
    phys_fc_name=$(echo "$phys_fc_name" | tr -d ' ')
    clntid=$(echo "$clntid" | tr -d ' ')

    # Skip lines where the physical FC name is blank
    if [[ -z "$phys_fc_name" ]]; then
        continue
    fi

    # NEW LOOKUP METHOD: Avoid -field flags. 
    # Iterate through all vfchost devices and match the location code using lscfg.
    curr_vfchost=""
    for dev in $(lsdev | grep -i vfchost | awk '/vfchost/{print $1}'); do
        if lscfg -vl "$dev" | grep -w "$vio_virt_loc" > /dev/null 2>&1; then
            curr_vfchost="$dev"
            break # Stop searching once we find the matching adapter
        fi
    done

    if [[ -z "$curr_vfchost" ]]; then
        echo "[ERROR] No virtual adapter found at VIO Virtual loc: $vio_virt_loc (Client ID: $clntid)"
        continue
    fi

    # Verify the logical physical FC port exists on this VIOS partition
    /usr/ios/cli/ioscli lsdev -dev "$phys_fc_name" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] Physical FC port $phys_fc_name does not exist on this system."
        continue
    fi

    # Execution Block
    echo "Mapping intended for Client ID $clntid (Virtual Loc: $vio_virt_loc):"
    echo "  Command: vfcmap -vadapter $curr_vfchost -fcp $phys_fc_name"
    
    if [[ $DRY_RUN -eq 0 ]]; then
        /usr/ios/cli/ioscli vfcmap -vadapter "$curr_vfchost" -fcp "$phys_fc_name"
        if [[ $? -eq 0 ]]; then
            echo "  [SUCCESS] Mapped $curr_vfchost -> $phys_fc_name"
        else
            echo "  [FAILED] Error mapping $curr_vfchost -> $phys_fc_name. Check errpt."
        fi
    fi
    echo "---------------------------------------------------------"

done

echo "NPIV Restoration script completed."

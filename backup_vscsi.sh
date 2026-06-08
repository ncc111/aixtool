#!/usr/bin/ksh
# VSCSI Configuration Backup Script for VIOS
# Extracts Physloc, ClientID, VTD, and Backing Device

BACKUP_DIR="/home/padmin/vscsi_backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/vscsi_config_${DATE}.txt"
RAW_FILE="${BACKUP_DIR}/vscsi_raw_${DATE}.txt"

# Ensure backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
fi

echo "Starting VSCSI configuration backup..." | tee -a "$BACKUP_FILE"

# 1. Capture full raw output for reference/auditing
/usr/ios/cli/ioscli lsmap -all > "$RAW_FILE"

# 2. Generate formatted mapping file for the restore script
echo "--- Formatted VSCSI Mappings ---" >> "$BACKUP_FILE"
echo "Physloc : ClientID : VTD_Name : Backing_Device" >> "$BACKUP_FILE"

# Iterate over all vhost adapters
for vhost in $(/usr/ios/cli/ioscli lsdev -type adapter | awk '/vhost/{print $1}'); do
    # Parse lsmap output carefully to bypass unsupported -field flags
    /usr/ios/cli/ioscli lsmap -vadapter "$vhost" | awk '
    /^SVSA/ { getline; getline; physloc=$2; client=$3 }
    /^VTD/ { vtd=$2 }
    /^Backing device/ { 
        backing=$3; 
        if (vtd != "NO" && backing != "") {
            printf "%s:%s:%s:%s\n", physloc, client, vtd, backing
        }
    }' >> "$BACKUP_FILE"
done

# 3. Backup device info
echo "--- Backup device info ---" >> "$BACKUP_FILE"
lspv >> "$RAW_FILE"
lsdev >> "$RAW_FILE"
lscfg >> "$RAW_FILE"
prtconf >> "$RAW_FILE"

echo "Formatted backup completed: ${BACKUP_FILE}"
echo "Raw reference completed: ${RAW_FILE}"

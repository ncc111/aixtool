#!/bin/ksh
# NPIV Configuration Backup Script for VIOS
# Date: 2026-06-05

BACKUP_DIR="/home/padmin/npiv_backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/npiv_config_${DATE}.txt"
BACKUP_INLINE="${BACKUP_DIR}/npiv_config_line_${DATE}.txt"

# Ensure backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
fi

echo "Starting NPIV configuration backup..." | tee -a "${BACKUP_FILE}"
echo "------------------------------------------" >> "${BACKUP_FILE}"

# 1. Capture Virtual Fibre Channel (VFC) mappings
echo "--- VFC Mappings (lsmap -all -npiv) ---" >> "${BACKUP_FILE}"
/usr/ios/cli/ioscli lsmap -all -npiv >> "${BACKUP_FILE}" 2>&1



echo "--- VFC MAP in line ---"  >> "${BACKUP_FILE}"
echo "'name' 'VIO Virtual loc' 'ClntID' 'ClntName' 'Phys FC name' 'FC loc code' 'VFC client name' 'VFC client DRC' 'Status'" >> "${BACKUP_INLINE}" 2>&1
/usr/ios/cli/ioscli lsmap -all -npiv -fmt : -field 'name' 'Physloc' 'ClntID' 'ClntName' 'FC name' 'FC loc code' 'VFC client name' 'VFC client DRC' 'Status' >> "${BACKUP_INLINE}" 2>&1


# 2. Capture Physical Fibre Channel details
echo "\n--- Physical Fibre Channel Details (lsdev -type fc) ---" >> "${BACKUP_FILE}"
lsdev -C -c adapter -F 'name class location physloc' | grep -i fcs >> "${BACKUP_FILE}" 2>&1


# 3. Capture specific WWPN information for physical ports
echo -e "\n--- WWPN Information (lscfg -vl) ---" >> "${BACKUP_FILE}"
for port in $( lsdev -C -c adapter -F 'name class location physloc' | grep -i fcs | awk '{print $1}'); do
    echo "Port: $port" >> "${BACKUP_FILE}"
    lscfg -vl "$port" | grep -i "Network Address" >> "${BACKUP_FILE}"
done

echo "------------------------------------------" >> "${BACKUP_FILE}"
echo "Backup completed: ${BACKUP_FILE}"

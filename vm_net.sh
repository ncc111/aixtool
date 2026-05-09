#!/bin/bash

# Ensure root privileges for virsh and hardware paths
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root (sudo ./net_map_final.sh)"
  exit 1
fi

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "         RHEL NETWORK TOPOLOGY: FULL HARDWARE MAP           "
echo -e "${CYAN}============================================================${NC}"

# 1. Map vnet interfaces to VM names using XML parsing (more reliable)
declare -A VM_MAP
for vm in $(virsh list --name --state-running); do
    # Extract all target devs (vnet#) from the VM's XML
    for vnet in $(virsh dumpxml "$vm" | xmllint --xpath "//interface/target/@dev" - 2>/dev/null | grep -o 'vnet[0-9]*'); do
        VM_MAP["$vnet"]="$vm"
    done
done

# 2. Track which physical interfaces are in use
declare -A PHYS_IN_USE

# 3. Identify and Display Bridges and their Slaves
bridges=$(ls /sys/class/net | grep -E 'br|virbr|privbr')

for br in $bridges; do
    if [ -d "/sys/class/net/$br/bridge" ]; then
        STATE=$(cat /sys/class/net/$br/operstate)
        printf "${BLUE}BRIDGE: %-15s${NC} [%s]\n" "$br" "$STATE"
        
        members=$(ls /sys/class/net/$br/brif 2>/dev/null)
        
        if [ -z "$members" ]; then
            echo "  └── [ No interfaces attached ]"
        else
            for member in $members; do
                # Check if physical
                if [ -d "/sys/class/net/$member/device" ]; then
                    PHYS_IN_USE["$member"]=1
                    printf "  ├── ${GREEN}%-12s${NC} (PHYSICAL) [%s]\n" "$member" "$(cat /sys/class/net/$member/operstate)"
                # Check if it's a VM interface
                elif [[ -n "${VM_MAP[$member]}" ]]; then
                    printf "  ├── ${YELLOW}%-12s${NC} (VM: ${CYAN}%s${NC}) [%s]\n" "$member" "${VM_MAP[$member]}" "$(cat /sys/class/net/$member/operstate)"
                # System/Management Taps
                else
                    printf "  ├── %-12s (SYSTEM/TAP) [%s]\n" "$member" "$(cat /sys/class/net/$member/operstate)"
                fi
            done
        fi
        echo -e "  │\n"
    fi
done

# 4. Display Standalone / Orphaned Physical Adapters
echo -e "${CYAN}ORPHANED / STANDALONE PHYSICAL ADAPTERS${NC}"
echo -e "------------------------------------------------------------"

# Look for everything in /sys/class/net that has a 'device' link but isn't in a bridge
found_orphan=false
for iface in $(ls /sys/class/net | grep -v lo); do
    # If it's a physical device and NOT marked as in use by a bridge
    if [ -d "/sys/class/net/$iface/device" ] && [ -z "${PHYS_IN_USE[$iface]}" ]; then
        # Double check it doesn't have a master (like a bond)
        if [ ! -e "/sys/class/net/$iface/master" ]; then
            STATE=$(cat /sys/class/net/$iface/operstate)
            # Get driver info for extra detail
            DRIVER=$(basename $(readlink /sys/class/net/$iface/device/driver))
            printf "${GREEN}%-15s${NC} (Standalone) [%s] Driver: %s\n" "$iface" "$STATE" "$DRIVER"
            found_orphan=true
        fi
    fi
done

if [ "$found_orphan" = false ]; then
    echo "No standalone physical adapters found."
fi

echo -e "${CYAN}============================================================${NC}"

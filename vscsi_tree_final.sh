#!/bin/ksh
#
# vscsi_tree_final.sh - Generate Tree-Style vSCSI Configuration Diagram
# Description: Creates tree-style diagrams showing complete vSCSI mappings
# Author: Bob
# Date: 2026-06-22
# Version: 4.0 - Simplified Parser
#

# Configuration
OUTPUT_DIR="/tmp/vscsi_diagrams"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/vscsi_tree_${TIMESTAMP}.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_msg() {
    echo "${1}${2}${NC}"
}

check_root() {
    if [[ $(id -u) -ne 0 ]]; then
        print_msg "${RED}" "ERROR: Must run as root"
        exit 1
    fi
}

create_output_dir() {
    mkdir -p "${OUTPUT_DIR}" 2>/dev/null
    chmod 755 "${OUTPUT_DIR}" 2>/dev/null
}

get_physical_disk() {
    local lv=$1
    lslv -l "${lv}" 2>/dev/null | grep "^hdisk" | awk '{print $1}' | head -1
}

get_vg() {
    local lv=$1
    lslv "${lv}" 2>/dev/null | awk '/VOLUME GROUP:/ {print $3}'
}

generate_tree() {
    print_msg "${BLUE}" "Generating tree diagram..."
    
    cat > "${OUTPUT_FILE}" << EOF
================================================================================
                    vSCSI CONFIGURATION TREE DIAGRAM
================================================================================

System: $(hostname)
Date: $(date)
VIOS Level: $(/usr/ios/cli/ioscli ioslevel)
System Type: VIOS

=================================================================================

$(hostname) [VIOS System]
│
EOF
    
    # Parse lsmap -all output
    /usr/ios/cli/ioscli lsmap -all 2>/dev/null | awk '
    BEGIN {
        adapter_count = 0
    }
    
    # Match adapter line (vhost with location and client ID)
    /^vhost[0-9]+/ && NF == 3 {
        if (adapter_count > 0) {
            print "│"
        }
        adapter_count++
        adapter = $1
        location = $2
        client_id = $3
        
        # Store for later
        adapters[adapter_count,"name"] = adapter
        adapters[adapter_count,"location"] = location
        adapters[adapter_count,"client"] = client_id
        current_adapter = adapter_count
        vtd_count[current_adapter] = 0
        next
    }
    
    # Match VTD line
    /^VTD/ && NF == 2 {
        vtd_count[current_adapter]++
        vtd_num = vtd_count[current_adapter]
        vtds[current_adapter,vtd_num,"name"] = $2
        in_vtd = 1
        next
    }
    
    # Match Status
    /^Status/ && in_vtd {
        vtds[current_adapter,vtd_count[current_adapter],"status"] = $2
        next
    }
    
    # Match LUN
    /^LUN/ && in_vtd {
        vtds[current_adapter,vtd_count[current_adapter],"lun"] = $2
        next
    }
    
    # Match Backing device
    /^Backing device/ && in_vtd {
        vtds[current_adapter,vtd_count[current_adapter],"backing"] = $3
        in_vtd = 0
        next
    }
    
    END {
        # Output the tree
        for (i = 1; i <= adapter_count; i++) {
            # Determine branch character
            if (i == adapter_count) {
                branch = "└──"
                cont = "    "
            } else {
                branch = "├──"
                cont = "│   "
            }
            
            # Print adapter
            printf "%s %s [Available] → Client: %s\n", branch, adapters[i,"name"], adapters[i,"client"]
            printf "%s   Location: %s\n", cont, adapters[i,"location"]
            
            # Print VTDs
            total_vtds = vtd_count[i]
            if (total_vtds > 0) {
                for (v = 1; v <= total_vtds; v++) {
                    if (v == total_vtds) {
                        vtd_branch = cont "   └──"
                        vtd_cont = cont "       "
                    } else {
                        vtd_branch = cont "   ├──"
                        vtd_cont = cont "   │   "
                    }
                    
                    printf "%s %s [VTD - %s]\n", vtd_branch, vtds[i,v,"name"], vtds[i,v,"status"]
                    printf "%s   LUN: %s\n", vtd_cont, vtds[i,v,"lun"]
                    printf "%s   Backing: %s\n", vtd_cont, vtds[i,v,"backing"]
                    
                    # Print backing device path for script to process
                    print "BACKING:" adapters[i,"name"] ":" vtds[i,v,"backing"]
                    
                    if (v < total_vtds) {
                        printf "%s\n", vtd_cont
                    }
                }
            } else {
                printf "%s   └── (No devices)\n", cont
            }
        }
        
        print ""
        print "================================================================================="
        printf "SUMMARY: %d vSCSI adapter(s) found\n", adapter_count
        print "================================================================================="
    }
    ' > /tmp/tree_base_$$.txt
    
    # Read the base tree and add physical disk info
    while IFS= read -r line; do
        if [[ "${line}" == BACKING:* ]]; then
            # Extract backing device
            backing=$(echo "${line}" | cut -d: -f3)
            
            # Check if it's a logical volume
            if lslv "${backing}" >/dev/null 2>&1; then
                vg=$(get_vg "${backing}")
                pdisk=$(get_physical_disk "${backing}")
                
                if [[ -n "${vg}" ]]; then
                    echo "                   │" >> "${OUTPUT_FILE}"
                    echo "                   ├── Volume Group: ${vg}" >> "${OUTPUT_FILE}"
                fi
                
                if [[ -n "${pdisk}" ]]; then
                    size=$(bootinfo -s "${pdisk}" 2>/dev/null || echo "N/A")
                    echo "                   └── Physical Disk: ${pdisk} (${size} MB)" >> "${OUTPUT_FILE}"
                fi
            fi
        else
            echo "${line}" >> "${OUTPUT_FILE}"
        fi
    done < /tmp/tree_base_$$.txt
    
    rm -f /tmp/tree_base_$$.txt
    
    print_msg "${GREEN}" "Tree diagram created: ${OUTPUT_FILE}"
}

display_results() {
    echo ""
    print_msg "${BLUE}" "=========================================="
    print_msg "${BLUE}" "Tree Diagram Complete"
    print_msg "${BLUE}" "=========================================="
    echo ""
    print_msg "${CYAN}" "  ${OUTPUT_FILE}"
    echo ""
    print_msg "${YELLOW}" "View with: cat ${OUTPUT_FILE}"
    echo ""
}

main() {
    check_root
    create_output_dir
    
    print_msg "${BLUE}" "=========================================="
    print_msg "${BLUE}" "vSCSI Tree Diagram Generator"
    print_msg "${BLUE}" "=========================================="
    echo ""
    
    generate_tree
    display_results
}

main "$@"

# Made with Bob

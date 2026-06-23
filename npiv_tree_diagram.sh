#!/bin/ksh
#
# npiv_tree_diagram.sh - Generate Tree-Style NPIV Configuration Diagram
# Description: Creates tree-style diagrams showing NPIV (N_Port ID Virtualization) mappings
# Author: Bob
# Date: 2026-06-22
# Version: 1.0
#

# Configuration
OUTPUT_DIR="/tmp/npiv_diagrams"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/npiv_tree_${TIMESTAMP}.txt"

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

generate_tree() {
    print_msg "${BLUE}" "Generating NPIV tree diagram..."
    
    cat > "${OUTPUT_FILE}" << EOF
================================================================================
                    NPIV CONFIGURATION TREE DIAGRAM
================================================================================

System: $(hostname)
Date: $(date)
VIOS Level: $(/usr/ios/cli/ioscli ioslevel)
System Type: VIOS

=================================================================================

$(hostname) [VIOS System]
│
EOF
    
    # Get physical FC adapters first
    print_msg "${YELLOW}" "Scanning physical FC adapters..."
    
    /usr/ios/cli/ioscli lsnports 2>/dev/null | awk '
    NR > 1 {
        print "PHYSICAL_FC:" $1 ":" $2 ":" $3 ":" $4 ":" $5 ":" $6 ":" $7
    }'  > /tmp/physical_fc_$$.txt
    
    # Parse lsmap -all -npiv output
    print_msg "${YELLOW}" "Scanning NPIV mappings..."
    
    /usr/ios/cli/ioscli lsmap -all -npiv 2>/dev/null | awk '
    BEGIN {
        vfc_count = 0
    }
    
    # Match vfchost line
    /^vfchost[0-9]+/ {
        vfc_count++
        vfcs[vfc_count,"name"] = $1
        vfcs[vfc_count,"location"] = $2
        vfcs[vfc_count,"client_id"] = $3
        vfcs[vfc_count,"client_name"] = $4
        vfcs[vfc_count,"client_os"] = $5
        current_vfc = vfc_count
        next
    }
    
    # Match Status
    /^Status:/ {
        vfcs[current_vfc,"status"] = substr($0, index($0, ":")+1)
        next
    }
    
    # Match FC name and location code
    /^FC name:/ {
        # Extract FC name and location code
        # Format: FC name:fcs1                    FC loc code:U78D2.001.WZS06UF-P1-C10-T2
        line = $0
        
        # Extract FC name
        sub(/^FC name:/, "", line)
        sub(/[ \t]+FC loc code:.*$/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        vfcs[current_vfc,"fc_name"] = line
        
        # Extract FC loc code
        line = $0
        sub(/^.*FC loc code:/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        vfcs[current_vfc,"fc_loc_code"] = line
        next
    }
    
    # Match Ports logged in
    /^Ports logged in:/ {
        vfcs[current_vfc,"ports"] = $NF
        next
    }
    
    # Match VFC client name and DRC
    /^VFC client name:/ {
        # Extract VFC client name and DRC
        # Format: VFC client name:fcs0            VFC client DRC:U9009.42A.782D930-V106-C4
        line = $0
        
        # Extract VFC client name
        sub(/^VFC client name:/, "", line)
        sub(/[ \t]+VFC client DRC:.*$/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        vfcs[current_vfc,"vfc_client"] = line
        
        # Extract VFC client DRC
        line = $0
        sub(/^.*VFC client DRC:/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        vfcs[current_vfc,"vfc_client_drc"] = line
        next
    }
    
    END {
        # Group by physical FC adapter
        for (i = 1; i <= vfc_count; i++) {
            fc = vfcs[i,"fc_name"]
            if (fc_first[fc] == "") {
                fc_list[++fc_list_count] = fc
                fc_first[fc] = i
            }
            fc_vfcs[fc,++fc_vfc_count[fc]] = i
        }
        
        # Output tree structure
        for (f = 1; f <= fc_list_count; f++) {
            fc = fc_list[f]
            
            # Branch character for FC adapter
            if (f == fc_list_count) {
                fc_branch = "└──"
                fc_cont = "    "
            } else {
                fc_branch = "├──"
                fc_cont = "│   "
            }
            
            # Get FC adapter details from first vfc
            first_vfc = fc_first[fc]
            fc_loc_code = vfcs[first_vfc,"fc_loc_code"]
            
            # Print physical FC adapter
            print fc_branch " " fc " [Physical FC Adapter]"
            print fc_cont "   FC Location Code: " fc_loc_code
            print "PHYSICAL_FC_INFO:" fc
            
            # Print virtual FC hosts under this physical adapter
            total_vfcs = fc_vfc_count[fc]
            for (v = 1; v <= total_vfcs; v++) {
                vfc_idx = fc_vfcs[fc,v]
                
                if (v == total_vfcs) {
                    vfc_branch = fc_cont "   └──"
                    vfc_cont = fc_cont "       "
                } else {
                    vfc_branch = fc_cont "   ├──"
                    vfc_cont = fc_cont "   │   "
                }
                
                # Print vfchost with physical location
                print vfc_branch " " vfcs[vfc_idx,"name"] " " vfcs[vfc_idx,"location"]
                print vfc_cont "   Client ID: " vfcs[vfc_idx,"client_id"]
                print vfc_cont "   Client Name: " vfcs[vfc_idx,"client_name"] " (" vfcs[vfc_idx,"client_os"] ")"
                print vfc_cont "   Status:" vfcs[vfc_idx,"status"]
                print vfc_cont "   Ports Logged In: " vfcs[vfc_idx,"ports"]
                print vfc_cont "   │"
                print vfc_cont "   └── Client Adapter: " vfcs[vfc_idx,"vfc_client"]
                print vfc_cont "       VFC Client DRC: " vfcs[vfc_idx,"vfc_client_drc"]
                
                if (v < total_vfcs) {
                    print vfc_cont
                }
            }
            
            if (f < fc_list_count) {
                print "│"
            }
        }
        
        print ""
        print "================================================================================="
        print "SUMMARY:"
        print "  Physical FC Adapters: " fc_list_count
        print "  Virtual FC Hosts: " vfc_count
        print "================================================================================="
    }
    ' > /tmp/npiv_base_$$.txt
    
    # Read the base tree and add physical FC adapter details
    while IFS= read -r line; do
        if [[ "${line}" == PHYSICAL_FC_INFO:* ]]; then
            fc_name=$(echo "${line}" | cut -d: -f2)
            
            # Get physical FC adapter details
            fc_info=$(grep "^PHYSICAL_FC:${fc_name}:" /tmp/physical_fc_$$.txt)
            if [[ -n "${fc_info}" ]]; then
                fabric=$(echo "${fc_info}" | cut -d: -f4)
                tports=$(echo "${fc_info}" | cut -d: -f5)
                aports=$(echo "${fc_info}" | cut -d: -f6)
                swwpns=$(echo "${fc_info}" | cut -d: -f7)
                awwpns=$(echo "${fc_info}" | cut -d: -f8)
                
                echo "    │   Fabric: ${fabric}, Total Ports: ${tports}, Available Ports: ${aports}" >> "${OUTPUT_FILE}"
                echo "    │   Switch WWPNs: ${swwpns}, Available WWPNs: ${awwpns}" >> "${OUTPUT_FILE}"
            fi
        else
            echo "${line}" >> "${OUTPUT_FILE}"
        fi
    done < /tmp/npiv_base_$$.txt
    
    rm -f /tmp/npiv_base_$$.txt /tmp/physical_fc_$$.txt
    
    print_msg "${GREEN}" "NPIV tree diagram created: ${OUTPUT_FILE}"
}

display_results() {
    echo ""
    print_msg "${BLUE}" "=========================================="
    print_msg "${BLUE}" "NPIV Tree Diagram Complete"
    print_msg "${BLUE}" "=========================================="
    echo ""
    print_msg "${CYAN}" "  ${OUTPUT_FILE}"
    echo ""
    print_msg "${YELLOW}" "View with: cat ${OUTPUT_FILE}"
    echo ""
}

usage() {
    cat << EOF
Usage: $0

Generate tree-style diagram of NPIV configuration on VIOS systems.

OUTPUT LOCATION:
    ${OUTPUT_DIR}/npiv_tree_YYYYMMDD_HHMMSS.txt

EXAMPLE:
    $0

REQUIREMENTS:
    - Root privileges
    - VIOS system with NPIV configuration

EOF
}

main() {
    check_root
    create_output_dir
    
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_msg "${BLUE}" "=========================================="
            print_msg "${BLUE}" "NPIV Tree Diagram Generator"
            print_msg "${BLUE}" "=========================================="
            echo ""
            
            generate_tree
            display_results
            ;;
    esac
}

main "$@"

# Made with Bob

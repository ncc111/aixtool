#!/bin/ksh
# =============================================================================
# collect_powerha_config.sh
# PowerHA SystemMirror Configuration Collection Script
#
# Description : Collects a full snapshot of all PowerHA cluster configuration
#               objects and runtime state, and saves the output to a
#               timestamped report file.
#
# Cluster     : CL_101102
# Nodes       : DSB_AIX101 (192.168.141.101)
#               DSB_AIX102 (192.168.141.102)
# Version     : PowerHA SystemMirror 7.2.8.4
#
# Usage       : Run as root on either cluster node
#                 ksh collect_powerha_config.sh
#               Output file is written to OUTPUT_DIR (default: /tmp)
#
# Author      : Generated script — review before production use
# =============================================================================

# --------------------------------------------------------------------------- #
# Configuration                                                                #
# --------------------------------------------------------------------------- #
OUTPUT_DIR="/tmp"
SCRIPT_VERSION="1.0"
CLMGR="/usr/es/sbin/cluster/utilities/clmgr"
CLTOPINFO="/usr/es/sbin/cluster/utilities/cltopinfo"
CLSTAT="/usr/es/sbin/cluster/sbin/clstat"
CLDISP="/usr/es/sbin/cluster/utilities/cldisp"

# --------------------------------------------------------------------------- #
# Preflight checks                                                             #
# --------------------------------------------------------------------------- #
if [ "$(id -u)" -ne 0 ]; then
    print "ERROR: This script must be run as root." >&2
    exit 1
fi

if [ ! -x "${CLMGR}" ]; then
    print "ERROR: clmgr not found at ${CLMGR}. Is PowerHA installed?" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Output file setup                                                            #
# --------------------------------------------------------------------------- #
HOSTNAME=$(hostname)
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
OUTPUT_FILE="${OUTPUT_DIR}/powerha_config_${HOSTNAME}_${TIMESTAMP}.txt"

# --------------------------------------------------------------------------- #
# Helper functions                                                             #
# --------------------------------------------------------------------------- #
section() {
    typeset title="$1"
    print ""
    print "############################################################"
    printf  "# %-56s #\n" "${title}"
    print "############################################################"
}

subsection() {
    typeset title="$1"
    print ""
    print "------------------------------------------------------------"
    print "  ${title}"
    print "------------------------------------------------------------"
}

run_cmd() {
    typeset label="$1"
    shift
    subsection "${label}"
    "$@" 2>&1 || print "  [command returned non-zero exit: $?]"
}

# --------------------------------------------------------------------------- #
# Begin collection — redirect everything to the output file                   #
# --------------------------------------------------------------------------- #
{

print "============================================================"
print "  PowerHA SystemMirror Configuration Report"
print "  Generated  : $(date)"
print "  Hostname   : ${HOSTNAME}"
print "  Script ver : ${SCRIPT_VERSION}"
print "============================================================"

# =========================================================================== #
section "1. CLUSTER OVERVIEW"
# =========================================================================== #

run_cmd "1.1  Cluster topology (cltopinfo)" \
    ${CLTOPINFO}

run_cmd "1.2  Cluster attributes (clmgr query cluster)" \
    ${CLMGR} query cluster

run_cmd "1.3  Cluster status (clstat -a)" \
    ${CLSTAT} -a

# =========================================================================== #
section "2. NODES"
# =========================================================================== #

subsection "2.1  Node list"
${CLMGR} query node 2>&1

# Query each node individually
for NODE in $(${CLMGR} query node 2>/dev/null); do
    run_cmd "2.2  Node detail: ${NODE}" \
        ${CLMGR} query node "${NODE}"
done

# =========================================================================== #
section "3. NETWORKS"
# =========================================================================== #

subsection "3.1  Network list"
${CLMGR} query network 2>&1

for NET in $(${CLMGR} query network 2>/dev/null); do
    run_cmd "3.2  Network detail: ${NET}" \
        ${CLMGR} query network "${NET}"
done

# =========================================================================== #
section "4. INTERFACES (IP LABELS)"
# =========================================================================== #

subsection "4.1  Interface list"
${CLMGR} query interface 2>&1

for IFACE in $(${CLMGR} query interface 2>/dev/null); do
    run_cmd "4.2  Interface detail: ${IFACE}" \
        ${CLMGR} query interface "${IFACE}"
done

# =========================================================================== #
section "5. SERVICE IP LABELS"
# =========================================================================== #

subsection "5.1  Service IP list"
${CLMGR} query service_ip 2>&1

for SVC in $(${CLMGR} query service_ip 2>/dev/null); do
    run_cmd "5.2  Service IP detail: ${SVC}" \
        ${CLMGR} query service_ip "${SVC}"
done

# =========================================================================== #
section "6. RESOURCE GROUPS"
# =========================================================================== #

subsection "6.1  Resource group list"
${CLMGR} query resource_group 2>&1

for RG in $(${CLMGR} query resource_group 2>/dev/null); do
    run_cmd "6.2  Resource group detail: ${RG}" \
        ${CLMGR} query resource_group "${RG}"
done

# =========================================================================== #
section "7. APPLICATION CONTROLLERS"
# =========================================================================== #

subsection "7.1  Application controller list"
${CLMGR} query application 2>&1

for APP in $(${CLMGR} query application 2>/dev/null); do
    run_cmd "7.2  Application controller detail: ${APP}" \
        ${CLMGR} query application "${APP}"
done

# =========================================================================== #
section "8. VOLUME GROUPS"
# =========================================================================== #

subsection "8.1  Volume group list"
${CLMGR} query volume_group 2>&1

for VG in $(${CLMGR} query volume_group 2>/dev/null); do
    run_cmd "8.2  Volume group detail: ${VG}" \
        ${CLMGR} query volume_group "${VG}"

    subsection "8.3  LVM detail for VG: ${VG} (lsvg)"
    lsvg "${VG}" 2>&1

    subsection "8.4  Logical volumes in VG: ${VG} (lsvg -l)"
    lsvg -l "${VG}" 2>&1

    subsection "8.5  Physical volumes in VG: ${VG} (lsvg -p)"
    lsvg -p "${VG}" 2>&1
done

# =========================================================================== #
section "9. FILE SYSTEMS"
# =========================================================================== #

subsection "9.1  File system list"
${CLMGR} query file_system 2>&1

for FS in $(${CLMGR} query file_system 2>/dev/null); do
    run_cmd "9.2  File system detail: ${FS}" \
        ${CLMGR} query file_system "${FS}"
done

# =========================================================================== #
section "10. DISK HEARTBEAT DISKS"
# =========================================================================== #

subsection "10.1  Disk heartbeat disk list"
${CLMGR} query disk 2>&1

for DISK in $(${CLMGR} query disk 2>/dev/null | awk '{print $1}'); do
    run_cmd "10.2  Disk heartbeat detail: ${DISK}" \
        ${CLMGR} query disk "${DISK}"
done

# =========================================================================== #
section "11. CAA REPOSITORY DISK"
# =========================================================================== #

run_cmd "11.1  Repository disk (clmgr query repository)" \
    ${CLMGR} query repository

subsection "11.2  CAA disk state (lsattr -El hdisk for repo disk)"
REPO_DISK=$(${CLMGR} query repository 2>/dev/null | awk '{print $1}')
if [ -n "${REPO_DISK}" ]; then
    lsattr -El "${REPO_DISK}" 2>&1
else
    print "  [unable to determine repository disk name]"
fi

subsection "11.3  CAA subsystem status (lsdev -Cc cluster)"
lsdev -Cc cluster 2>&1

subsection "11.4  caatool disk listing"
caatool -l 2>/dev/null || print "  [caatool not available or no output]"

# =========================================================================== #
section "12. SITES (METRO/GLVM — if configured)"
# =========================================================================== #

run_cmd "12.1  Site list" \
    ${CLMGR} query site

# =========================================================================== #
section "13. HARDWARE (CAA / RDMA)"
# =========================================================================== #

subsection "13.1  lsdev -Cc adapter (cluster adapters)"
lsdev -Cc adapter 2>&1 | grep -i -E "cluster|caa|rdma" || print "  [no cluster adapters found]"

subsection "13.2  lsattr -El sys0 (system attributes)"
lsattr -El sys0 2>&1

# =========================================================================== #
section "14. RUNTIME STATE"
# =========================================================================== #

run_cmd "14.1  Cluster status summary (cldisp)" \
    ${CLDISP}

subsection "14.2  Active cluster processes (lssrc -g cluster)"
lssrc -g cluster 2>&1

subsection "14.3  Resource group online status (clRGinfo)"
/usr/es/sbin/cluster/utilities/clRGinfo 2>&1

subsection "14.4  Mounted file systems (df -g)"
df -g 2>&1

subsection "14.5  Active volume groups (lsvg -o)"
lsvg -o 2>&1

subsection "14.6  IP address configuration (ifconfig -a)"
ifconfig -a 2>&1

# =========================================================================== #
section "15. EVENT LOGS & HISTORY"
# =========================================================================== #

subsection "15.1  Recent cluster events (/var/ha/log/hacmp.out — last 200 lines)"
if [ -f /var/ha/log/hacmp.out ]; then
    tail -200 /var/ha/log/hacmp.out 2>&1
else
    print "  [/var/ha/log/hacmp.out not found]"
fi

subsection "15.2  Recent cluster error log (/var/ha/log/haem.log — last 100 lines)"
if [ -f /var/ha/log/haem.log ]; then
    tail -100 /var/ha/log/haem.log 2>&1
else
    print "  [/var/ha/log/haem.log not found]"
fi

subsection "15.3  AIX error log — cluster related (errpt | head -50)"
errpt 2>/dev/null | head -50

# =========================================================================== #
section "16. ODM BACKUP (clmgr backup cluster)"
# =========================================================================== #

subsection "16.1  HACMPcluster ODM class"
odmget HACMPcluster 2>&1

subsection "16.2  HACMPnode ODM class"
odmget HACMPnode 2>&1

subsection "16.3  HACMPnetwork ODM class"
odmget HACMPnetwork 2>&1

subsection "16.4  HACMPadapter ODM class"
odmget HACMPadapter 2>&1

subsection "16.5  HACMPresource ODM class"
odmget HACMPresource 2>&1

subsection "16.6  HACMPgroup ODM class"
odmget HACMPgroup 2>&1

subsection "16.7  HACMPvolumegroup ODM class"
odmget HACMPvolumegroup 2>&1

subsection "16.8  HACMPoemvolumegroup ODM class"
odmget HACMPoemvolumegroup 2>&1

subsection "16.9  HACMPoemfilesystem ODM class"
odmget HACMPoemfilesystem 2>&1

subsection "16.10 HACMPdisksubsys ODM class"
odmget HACMPdisksubsys 2>&1

subsection "16.11 HACMPmonitor ODM class"
odmget HACMPmonitor 2>&1

subsection "16.12 HACMPevent ODM class"
odmget HACMPevent 2>&1

subsection "16.13 HACMPsite ODM class"
odmget HACMPsite 2>&1

subsection "16.14 HACMPtimer ODM class"
odmget HACMPtimer 2>&1

subsection "16.15 HACMPrgdependency ODM class"
odmget HACMPrgdependency 2>&1

subsection "16.16 HACMPsecurity ODM class"
odmget HACMPsecurity 2>&1

# =========================================================================== #
section "17. INSTALLED POWERHA FILESETS"
# =========================================================================== #

run_cmd "17.1  Installed PowerHA filesets (lslpp -l cluster.*)" \
    lslpp -l "cluster.*"

# =========================================================================== #
section "18. SYSTEM INFORMATION"
# =========================================================================== #

subsection "18.1  AIX version"
oslevel -s 2>&1

subsection "18.2  Hardware model"
prtconf | head -10 2>&1

subsection "18.3  System uptime"
uptime 2>&1

# =========================================================================== #
section "END OF REPORT"
# =========================================================================== #
print ""
print "Report complete."
print "  Output file : ${OUTPUT_FILE}"
print "  Generated   : $(date)"

} 2>&1 | tee "${OUTPUT_FILE}"

# --------------------------------------------------------------------------- #
# Final summary to console                                                     #
# --------------------------------------------------------------------------- #
print ""
print "========================================"
print "  Collection complete."
print "  Output saved to: ${OUTPUT_FILE}"
print "  File size: $(ls -l ${OUTPUT_FILE} | awk '{print $5}') bytes"
print "========================================"

exit 0

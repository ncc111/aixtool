#!/usr/bin/ksh
# =============================================================================
# aix_mem_check.ksh - Comprehensive AIX Memory Analysis Tool
# Version  : 2.0
# Platform : IBM AIX (tested on AIX 7.x / POWER)
# Author   : AIX Integration Architect
# Purpose  : Detailed memory analysis, anomaly detection, HTML + text reports
# Run as   : root (required for full svmon/vmo access)
# =============================================================================

# ---------------------------------------------------------------------------
# Globals & timestamps
# ---------------------------------------------------------------------------
SCRIPT_VERSION="2.0"
START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
START_EPOCH=$(date '+%s' 2>/dev/null || perl -e 'print time()' 2>/dev/null || echo 0)
HOSTNAME=$(hostname)
OSLEVEL=$(oslevel -s 2>/dev/null || oslevel 2>/dev/null || echo "unknown")
PAGESIZE_BYTES=$(pagesize 2>/dev/null || echo 4096)

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_DIR="/tmp"
LOGFILE="${LOG_DIR}/aix_mem_check_${TIMESTAMP}.log"
TXT_REPORT="${LOG_DIR}/aix_mem_report_${TIMESTAMP}.txt"
HTML_REPORT="${LOG_DIR}/aix_mem_report_${TIMESTAMP}.html"

# ---------------------------------------------------------------------------
# Colour codes for terminal output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Warning thresholds
WARN_MEM_USED_PCT=85        # warn if used% >= this
CRIT_MEM_USED_PCT=90        # critical if used% >= this
WARN_PGSP_USED_PCT=50       # warn if paging space used% >= this
CRIT_PGSP_USED_PCT=80       # critical if paging space used% >= this
WARN_PIN_PCT=80             # warn if pinned% of total >= this
WARN_PROC_MB=300            # warn if single process inuse >= this MB
HEALTHY_FREE_PCT=25         # "healthy" = at least this % free

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }
info() { echo "${CYAN}[INFO]${RESET}  $*"; log "[INFO]  $*"; }
warn() { echo "${YELLOW}[WARN]${RESET}  $*"; log "[WARN]  $*"; }
crit() { echo "${RED}[CRIT]${RESET}  $*"; log "[CRIT]  $*"; }
ok()   { echo "${GREEN}[OK]${RESET}    $*"; log "[OK]    $*"; }
hdr()  { echo "${BOLD}$*${RESET}"; log "$*"; }

# Initialise log file
{
  echo "============================================================"
  echo " AIX Memory Check Log  v${SCRIPT_VERSION}"
  echo " Host    : ${HOSTNAME}"
  echo " OS Level: ${OSLEVEL}"
  echo " Started : ${START_TIME}"
  echo "============================================================"
} > "$LOGFILE"

# ---------------------------------------------------------------------------
# Utility: integer-safe awk arithmetic
# ---------------------------------------------------------------------------
calc() { awk "BEGIN { printf \"%.2f\", $* }"; }
calc_int() { awk "BEGIN { printf \"%d\", $* }"; }
pct()  { awk "BEGIN { if ($2==0) print \"0.00\"; else printf \"%.1f\", ($1/$2)*100 }"; }

# ---------------------------------------------------------------------------
# Section 1 – Hardware / System info
# ---------------------------------------------------------------------------
collect_system_info() {
  SYS_MODEL=$(lsconf 2>/dev/null | awk '/System Model/{print $NF}')
  SYS_SERIAL=$(lsconf 2>/dev/null | awk '/Machine Serial/{print $NF}')
  SYS_CPU_TYPE=$(lsconf 2>/dev/null | awk '/Processor Type/{for(i=3;i<=NF;i++) printf $i" "; print ""}')
  SYS_NCPU=$(lsconf 2>/dev/null | awk '/Number Of Processors/{print $NF}')
  SYS_LPAR=$(lsconf 2>/dev/null | awk '/LPAR Info/{print substr($0, index($0,$3))}')
  SYS_MEM_MB=$(lsconf 2>/dev/null | awk '/^Memory Size:/{print $3}')
  SYS_MEM_MB=${SYS_MEM_MB:-$(svmon -G -O unit=MB 2>/dev/null | awk '/^memory/{printf "%d", $2}')}
}

# ---------------------------------------------------------------------------
# Section 2 – Global memory snapshot via svmon -G
# ---------------------------------------------------------------------------
collect_global_memory() {
  SVMON_RAW=$(svmon -G 2>/dev/null)

  # Pages (4K base)
  G_SIZE_PG=$(  echo "$SVMON_RAW" | awk '/^memory/{print $2}')
  G_INUSE_PG=$( echo "$SVMON_RAW" | awk '/^memory/{print $3}')
  G_FREE_PG=$(  echo "$SVMON_RAW" | awk '/^memory/{print $4}')
  G_PIN_PG=$(   echo "$SVMON_RAW" | awk '/^memory/{print $5}')
  G_VIRTUAL_PG=$(echo "$SVMON_RAW" | awk '/^memory/{print $6}')
  G_PGSP_SIZE=$( echo "$SVMON_RAW" | awk '/^pg space/{print $3}')
  G_PGSP_INUSE=$(echo "$SVMON_RAW" | awk '/^pg space/{print $4}')

  # Work / pers / clnt breakdown
  G_PIN_WORK=$(  echo "$SVMON_RAW" | awk '/^pin/{print $2}')
  G_PIN_PERS=$(  echo "$SVMON_RAW" | awk '/^pin/{print $3}')
  G_PIN_CLNT=$(  echo "$SVMON_RAW" | awk '/^pin/{print $4}')
  G_PIN_OTHER=$( echo "$SVMON_RAW" | awk '/^pin/{print $5}')
  G_INUSE_WORK=$(echo "$SVMON_RAW" | awk '/^in use/{print $3}')
  G_INUSE_PERS=$(echo "$SVMON_RAW" | awk '/^in use/{print $4}')
  G_INUSE_CLNT=$(echo "$SVMON_RAW" | awk '/^in use/{print $5}')

  # Convert to MB  (pages * pagesize / 1048576)
  PG2MB="* ${PAGESIZE_BYTES} / 1048576"
  G_TOTAL_MB=$( calc "$G_SIZE_PG   $PG2MB")
  G_INUSE_MB=$( calc "$G_INUSE_PG  $PG2MB")
  G_FREE_MB=$(  calc "$G_FREE_PG   $PG2MB")
  G_PIN_MB=$(   calc "$G_PIN_PG    $PG2MB")
  G_VIRTUAL_MB=$(calc "$G_VIRTUAL_PG $PG2MB")
  G_PGSP_SIZE_MB=$( calc "$G_PGSP_SIZE  $PG2MB")
  G_PGSP_INUSE_MB=$(calc "$G_PGSP_INUSE $PG2MB")

  G_INUSE_WORK_MB=$( calc "$G_INUSE_WORK  $PG2MB")
  G_INUSE_CLNT_MB=$( calc "$G_INUSE_CLNT  $PG2MB")
  G_PIN_WORK_MB=$(   calc "$G_PIN_WORK   $PG2MB")
  G_PIN_OTHER_MB=$(  calc "$G_PIN_OTHER  $PG2MB")

  # Percentages
  G_USED_PCT=$(  pct "$G_INUSE_PG" "$G_SIZE_PG")
  G_FREE_PCT=$(  pct "$G_FREE_PG"  "$G_SIZE_PG")
  G_PIN_PCT=$(   pct "$G_PIN_PG"   "$G_SIZE_PG")
  G_PGSP_PCT=$(  pct "$G_PGSP_INUSE" "$G_PGSP_SIZE")

  # Available for application  = free + client (file cache, reclaimable)
  G_AVAIL_MB=$(calc "$G_FREE_MB + $G_INUSE_CLNT_MB")
  G_AVAIL_PCT=$(pct "$(calc_int "($G_FREE_PG + $G_INUSE_CLNT)")" "$G_SIZE_PG")

  # vmo tunables
  VMO_ALL=$(vmo -a 2>/dev/null)
  VMO_MAXPIN=$(   echo "$VMO_ALL" | awk -F'=' '/maxpin[^%]/{gsub(/ /,"",$2); print $2; exit}')
  VMO_MINPERM=$(  echo "$VMO_ALL" | awk -F'=' '/minperm[^%]/{gsub(/ /,"",$2); print $2; exit}')
  VMO_MAXPERM=$(  echo "$VMO_ALL" | awk -F'=' '/maxperm[^%]/{gsub(/ /,"",$2); print $2; exit}')
  VMO_MAXPINPCT=$(echo "$VMO_ALL" | awk -F'=' '/maxpin%/{gsub(/ /,"",$2); print $2; exit}')
  VMO_MINFREE=$(  echo "$VMO_ALL" | awk -F'=' '/minfree[^_]/{gsub(/ /,"",$2); print $2; exit}')
  VMO_MAXFREE=$(  echo "$VMO_ALL" | awk -F'=' '/maxfree[^_]/{gsub(/ /,"",$2); print $2; exit}')
  VMO_NPSKILL=$(  echo "$VMO_ALL" | awk -F'=' '/npskill/{gsub(/ /,"",$2); print $2; exit}')
  VMO_NPSWARN=$(  echo "$VMO_ALL" | awk -F'=' '/npswarn/{gsub(/ /,"",$2); print $2; exit}')
  VMO_KLOCK=$(    echo "$VMO_ALL" | awk -F'=' '/vmm_klock_mode/{gsub(/ /,"",$2); print $2; exit}')

  VMO_MAXPIN=${VMO_MAXPIN:-"N/A"}
  VMO_MAXPINPCT=${VMO_MAXPINPCT:-"90"}
  VMO_MINFREE=${VMO_MINFREE:-"N/A"}
  VMO_MAXFREE=${VMO_MAXFREE:-"N/A"}
  VMO_NPSKILL=${VMO_NPSKILL:-"N/A"}
  VMO_NPSWARN=${VMO_NPSWARN:-"N/A"}
  VMO_KLOCK=${VMO_KLOCK:-"N/A"}
}

# ---------------------------------------------------------------------------
# Section 3 – vmstat snapshot
# ---------------------------------------------------------------------------
collect_vmstat() {
  # Run vmstat 1 3: first data row is cumulative-since-boot (unreliable for sr).
  # On this AIX build, vmstat 1 3 outputs a leading blank line then:
  #   "System configuration:..." / blank / kthr headers / dashes / col labels /
  #   data-row-1 (boot cumulative) / data-row-2 (1-sec) / data-row-3 (1-sec)
  # We skip the cumulative row and take the SECOND numeric data row.
  VMSTAT_ALL=$(vmstat 1 3 2>/dev/null)
  VMSTAT_RAW=$(echo "$VMSTAT_ALL" | awk '/^ *[0-9]/{c++; if(c==2){print; exit}}')
  # Fallback: if interval run produced no usable row, take last numeric row of plain vmstat
  if [ -z "$(echo "$VMSTAT_RAW" | tr -d ' ')" ]; then
    VMSTAT_RAW=$(vmstat 2>/dev/null | awk '/^ *[0-9]/{last=$0} END{print last}')
  fi
  # vmstat data row columns (verified against AIX 7.2 output):
  # $1=r $2=b $3=avm $4=fre $5=re $6=pi $7=po $8=fr $9=sr $10=cy
  # $11=in $12=sy $13=cs $14=us $15=sy $16=id $17=wa $18=pc $19=ec
  VM_AVM=$(echo "$VMSTAT_RAW" | awk '{print $3}')
  VM_FRE=$(echo "$VMSTAT_RAW" | awk '{print $4}')
  VM_PI=$( echo "$VMSTAT_RAW" | awk '{print $6}')
  VM_PO=$( echo "$VMSTAT_RAW" | awk '{print $7}')
  VM_FR=$( echo "$VMSTAT_RAW" | awk '{print $8}')
  VM_SR=$( echo "$VMSTAT_RAW" | awk '{print $9}')
  VM_CPU_US=$(echo "$VMSTAT_RAW" | awk '{print $14}')
  VM_CPU_SY=$(echo "$VMSTAT_RAW" | awk '{print $15}')
  VM_CPU_ID=$(echo "$VMSTAT_RAW" | awk '{print $16}')
  VM_CPU_WA=$(echo "$VMSTAT_RAW" | awk '{print $17}')
  VM_AVM=${VM_AVM:-0}; VM_FRE=${VM_FRE:-0}
  VM_PI=${VM_PI:-0};   VM_PO=${VM_PO:-0}
  VM_FR=${VM_FR:-0};   VM_SR=${VM_SR:-0}
}

# ---------------------------------------------------------------------------
# Section 4 – Paging space
# ---------------------------------------------------------------------------
collect_pgsp() {
  PGSP_RAW=$(lsps -a 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Section 5 – Top 10 processes by memory (svmon -P)
# ---------------------------------------------------------------------------
collect_top_procs() {
  # Get top 15 from svmon (we trim to 10 after filtering header lines)
  SVMON_PROC_RAW=$(svmon -P -t 15 -O unit=MB,sortentity=inuse 2>/dev/null)
  # Build summary line: PID | CMD | INUSE | PIN | PGSP | VIRTUAL
  TOP_PROCS=$(echo "$SVMON_PROC_RAW" | awk '
    /^---/ { skip=0; next }
    /Vsid/ { skip=1 }
    skip   { next }
    /^ *[0-9]/ && NF>=5 {
      printf "%s|%s|%s|%s|%s|%s\n", $1,$2,$3,$4,$5,$6
    }
  ' | head -10)
}

# ---------------------------------------------------------------------------
# Section 6 – Detailed svmon segment view per top process
# ---------------------------------------------------------------------------
collect_top_procs_detail() {
  # Full svmon -P with segment breakdown, top 10
  SVMON_PROC_DETAIL=$(svmon -P -t 10 -O unit=MB,sortentity=inuse,segment=on 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Section 6b – Per-process segment category summary
# Parses SVMON_PROC_DETAIL and produces pipe-delimited records:
#   PID|CMD|TOTAL_INUSE|PRIVATE|SHARED_LIB_TEXT|SHARED_LIB_DATA|
#   KERNEL_SEG|WORKING_STOR|CLIENT_FILE|SHARED_MEM|MMAP|OTHER|PIN|PGSP|VIRTUAL
# ---------------------------------------------------------------------------
build_seg_summary() {
  SEG_SUMMARY=$(echo "$SVMON_PROC_DETAIL" | awk '
  BEGIN {
    pid=""; cmd=""; tot_inuse=0; tot_pin=0; tot_pgsp=0; tot_virt=0
    priv=0; slt=0; sld=0; kern=0; wkstor=0; clnt=0; shmem=0; mmap_=0; other=0
  }

  # New process header line: "  PID  Command  Inuse  Pin  Pgsp  Virtual"
  /^ *[0-9]+ [A-Za-z_\/\.\-]/ && NF==6 && $3~/^[0-9]/ {
    # flush previous
    if (pid != "") {
      printf "%s|%s|%s|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%s|%s|%s\n",
        pid, cmd, tot_inuse, priv, slt, sld, kern, wkstor, clnt, shmem, mmap_, other,
        tot_pin, tot_pgsp, tot_virt
    }
    pid=$1; cmd=$2; tot_inuse=$3; tot_pin=$4; tot_pgsp=$5; tot_virt=$6
    priv=0; slt=0; sld=0; kern=0; wkstor=0; clnt=0; shmem=0; mmap_=0; other=0
    next
  }

  # Segment detail line – needs Vsid+Esid+Type+Description fields
  # Fields: Vsid Esid Type Description PSize Inuse Pin Pgsp Virtual
  pid=="" { next }
  NF < 6  { next }
  /Vsid/  { next }
  /^---/  { next }
  /^Unit/ { next }
  /^Page/ { next }

  {
    # Rebuild description by joining fields 4..NF-4 (last 4: PSize Inuse Pin Pgsp/Virtual)
    # Layout: $1=Vsid $2=Esid $3=Type $4..$(NF-4)=Desc $(NF-3)=PSize $(NF-2)=Inuse $(NF-1)=Pin $NF=Pgsp/Virt
    # Simpler: just classify by recognisable keywords in the line
    inuse_val = $(NF-2)+0

    # Classify by description content
    if ($0 ~ /process private/)          priv    += inuse_val
    else if ($0 ~ /shared library text/) slt     += inuse_val
    else if ($0 ~ /shared library data/) sld     += inuse_val
    else if ($0 ~ /kernel segment/)      kern    += inuse_val
    else if ($0 ~ /System Segment/)      kern    += inuse_val
    else if ($0 ~ /working storage/)     wkstor  += inuse_val
    else if ($0 ~ /clnt /)               clnt    += inuse_val
    else if ($0 ~ /shared memory/)       shmem   += inuse_val
    else if ($0 ~ /mmap /)               mmap_   += inuse_val
    else                                  other   += inuse_val
  }

  END {
    if (pid != "") {
      printf "%s|%s|%s|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%s|%s|%s\n",
        pid, cmd, tot_inuse, priv, slt, sld, kern, wkstor, clnt, shmem, mmap_, other,
        tot_pin, tot_pgsp, tot_virt
    }
  }
  ')
}

# ---------------------------------------------------------------------------
# Section 7 – ps-based process snapshot (RSS, VSZ, %MEM)
# ---------------------------------------------------------------------------
collect_ps_info() {
  # AIX ps gvww column layout (1-based):
  #  1=PID 2=TTY 3=STAT 4=TIME 5=PGIN 6=SIZE 7=RSS 8=LIM 9=TSIZ 10=TRS 11=%CPU 12=%MEM 13=COMMAND
  # %MEM is col 12; LIM is col 8 (can be "xx" for unlimited — skip those rows
  # for %MEM, but still show all processes; replace "xx" LIM with "unlim").
  PS_RAW=$(ps gvww 2>/dev/null | awk '
    NR==1{print; next}
    /^ *[0-9]/ && $7+0 > 0 { print }
  ' | awk 'NR==1{print; next} {print | "sort -rn +6 -7"}' | head -16)
}

# ---------------------------------------------------------------------------
# Section 8 – User-level memory breakdown
# ---------------------------------------------------------------------------
collect_user_mem() {
  USER_MEM_RAW=$(svmon -U -O unit=MB,sortentity=inuse 2>/dev/null | awk '
    /^User/{header=1}
    header && /^[a-z_]/ && $2 > 0 {
      printf "%s|%s|%s|%s|%s\n", $1,$2,$3,$4,$5
    }
  ')
}

# ---------------------------------------------------------------------------
# Section 9 – lparstat
# ---------------------------------------------------------------------------
collect_lparstat() {
  LPAR_CONF=$(lparstat 2>/dev/null | head -4)
  LPAR_STAT=$(lparstat 2>/dev/null | tail -2)
}

# ---------------------------------------------------------------------------
# Section 10 – Anomaly / warning detection
# ---------------------------------------------------------------------------
WARNINGS=""
CRITICALS=""

detect_anomalies() {
  # --- Used memory percentage ---
  USED_PCT_INT=$(calc_int "$G_USED_PCT")
  if [ "$USED_PCT_INT" -ge "$CRIT_MEM_USED_PCT" ]; then
    CRITICALS="${CRITICALS}CRITICAL: Memory used ${G_USED_PCT}% (>= ${CRIT_MEM_USED_PCT}% threshold). Risk of page stealing.\n"
  elif [ "$USED_PCT_INT" -ge "$WARN_MEM_USED_PCT" ]; then
    WARNINGS="${WARNINGS}WARNING: Memory used ${G_USED_PCT}% (>= ${WARN_MEM_USED_PCT}% threshold).\n"
  fi

  # --- Paging space ---
  PGSP_PCT_INT=$(calc_int "$G_PGSP_PCT")
  if [ "$PGSP_PCT_INT" -ge "$CRIT_PGSP_USED_PCT" ]; then
    CRITICALS="${CRITICALS}CRITICAL: Paging space used ${G_PGSP_PCT}% (>= ${CRIT_PGSP_USED_PCT}%). System may thrash.\n"
  elif [ "$PGSP_PCT_INT" -ge "$WARN_PGSP_USED_PCT" ]; then
    WARNINGS="${WARNINGS}WARNING: Paging space used ${G_PGSP_PCT}% (>= ${WARN_PGSP_USED_PCT}%).\n"
  fi

  # --- Pinned memory ---
  PIN_PCT_INT=$(calc_int "$G_PIN_PCT")
  if [ "$PIN_PCT_INT" -ge "$WARN_PIN_PCT" ]; then
    WARNINGS="${WARNINGS}WARNING: Pinned memory is ${G_PIN_PCT}% of total (>= ${WARN_PIN_PCT}% threshold). Kernel/DMA pin pressure.\n"
  fi

  # --- Active paging (page-in/page-out) ---
  if [ "${VM_PI:-0}" -gt 0 ] || [ "${VM_PO:-0}" -gt 0 ]; then
    WARNINGS="${WARNINGS}WARNING: Active paging detected (page-ins=${VM_PI}, page-outs=${VM_PO}). Memory may be under pressure.\n"
  fi

  # --- Scan rate (memory pressure indicator) ---
  # SR > 0 on a live 1-second interval means VMM is actively stealing pages.
  # A value of 0 is normal and healthy.
  if [ "${VM_SR:-0}" -gt 200 ]; then
    WARNINGS="${WARNINGS}WARNING: Page scan rate=${VM_SR} pages/sec (1-sec interval). VMM is under significant memory pressure – consider freeing memory.\n"
  elif [ "${VM_SR:-0}" -gt 0 ]; then
    WARNINGS="${WARNINGS}INFO: Page scan rate=${VM_SR} pages/sec (1-sec interval). VMM is reclaiming file-cache pages. Normal when file cache is large; watch for increase.\n"
  fi

  # --- vmm_klock_mode (spin lock monitoring) ---
  if [ "${VMO_KLOCK:-0}" = "2" ]; then
    ok "vmm_klock_mode=2 (Adaptive spin locks – normal)"
  elif [ "${VMO_KLOCK:-0}" = "0" ]; then
    WARNINGS="${WARNINGS}WARNING: vmm_klock_mode=0 (spin locks disabled). VMM locking is not adaptive – potential contention.\n"
  fi

  # --- Large pinned 'other' memory (kernel/DMA) ---
  PIN_OTHER_PCT=$(pct "$G_PIN_OTHER" "$G_SIZE_PG" 2>/dev/null || echo 0)
  PIN_OTHER_INT=$(calc_int "$PIN_OTHER_PCT")
  if [ "$PIN_OTHER_INT" -ge 20 ]; then
    WARNINGS="${WARNINGS}WARNING: Kernel/DMA pinned-other is ${G_PIN_OTHER_MB}MB (${PIN_OTHER_PCT}% of RAM). Possible large kernel structure or device DMA lock.\n"
  fi

  # --- Low free memory ---
  FREE_PCT_INT=$(calc_int "$G_FREE_PCT")
  if [ "$FREE_PCT_INT" -lt 5 ]; then
    CRITICALS="${CRITICALS}CRITICAL: Free memory is only ${G_FREE_MB}MB (${G_FREE_PCT}%). Immediate risk of OOM / page-stealing.\n"
  elif [ "$FREE_PCT_INT" -lt 10 ]; then
    WARNINGS="${WARNINGS}WARNING: Free memory is low: ${G_FREE_MB}MB (${G_FREE_PCT}%).\n"
  fi

  # --- npskill threshold (paging space kill) ---
  if [ "${VMO_NPSKILL:-0}" != "N/A" ] && [ "${G_PGSP_INUSE:-0}" -gt 0 ]; then
    NPSKILL_PCT=$(pct "${G_PGSP_INUSE:-0}" "${G_PGSP_SIZE:-1}")
    NPS_INT=$(calc_int "$NPSKILL_PCT")
    if [ "$NPS_INT" -ge 80 ]; then
      CRITICALS="${CRITICALS}CRITICAL: Paging space ${NPSKILL_PCT}% used. npskill=${VMO_NPSKILL} pages – system will start killing processes soon.\n"
    fi
  fi

  # --- Top process memory ---
  echo "$TOP_PROCS" | while IFS='|' read pid cmd inuse pin pgsp virt; do
    INUSE_INT=$(calc_int "${inuse:-0}")
    if [ "$INUSE_INT" -ge "$WARN_PROC_MB" ]; then
      log "[WARN]  Process PID=${pid} CMD=${cmd} is using ${inuse}MB RAM (>= ${WARN_PROC_MB}MB threshold)"
    fi
  done
}

# ---------------------------------------------------------------------------
# Section 11 – Recommendation engine
# ---------------------------------------------------------------------------
compute_recommendation() {
  FREE_PCT_INT=$(calc_int "$G_FREE_PCT")
  AVAIL_PCT_INT=$(calc_int "$G_AVAIL_PCT")

  if [ "$FREE_PCT_INT" -ge "$HEALTHY_FREE_PCT" ]; then
    AVAIL_FOR_APP_MB=$(calc "$G_TOTAL_MB * 0.70 - $G_INUSE_WORK_MB")
    REC_STATUS="HEALTHY"
    REC_COLOR="#27ae60"
    REC_ICON="✔"
    REC_MSG="System memory is healthy. Estimated safe headroom for new applications: ~${AVAIL_FOR_APP_MB} MB (targeting 70% utilisation ceiling)."
  elif [ "$FREE_PCT_INT" -ge 15 ]; then
    AVAIL_FOR_APP_MB=$(calc "$G_FREE_MB + $G_INUSE_CLNT_MB * 0.5")
    REC_STATUS="CAUTION"
    REC_COLOR="#e67e22"
    REC_ICON="⚠"
    REC_MSG="Memory is moderately used. Available for new hosting: ~${AVAIL_FOR_APP_MB} MB (free + 50% of reclaimable file cache). Monitor paging space."
  elif [ "$FREE_PCT_INT" -ge 5 ]; then
    AVAIL_FOR_APP_MB="$G_FREE_MB"
    REC_STATUS="WARNING"
    REC_COLOR="#c0392b"
    REC_ICON="⚠"
    REC_MSG="Memory is running low. Only ~${AVAIL_FOR_APP_MB} MB genuinely free. Do NOT start large workloads. Investigate top consumers and consider adding memory or offloading workloads."
  else
    AVAIL_FOR_APP_MB="0"
    REC_STATUS="CRITICAL"
    REC_COLOR="#8e1a1a"
    REC_ICON="✖"
    REC_MSG="CRITICAL: System is memory-starved. Free=${G_FREE_MB}MB. Immediate action required: kill or migrate workloads, check for memory leaks."
  fi
}

# ---------------------------------------------------------------------------
# Collect everything
# ---------------------------------------------------------------------------
info "Collecting system information..."
collect_system_info

info "Collecting global memory stats (svmon -G)..."
collect_global_memory

info "Collecting vmstat snapshot..."
collect_vmstat

info "Collecting paging space info..."
collect_pgsp

info "Collecting top processes (svmon -P top 15)..."
collect_top_procs

info "Collecting per-process segment detail (svmon -P top 10)..."
collect_top_procs_detail

info "Building per-process segment category summary..."
build_seg_summary

info "Collecting ps process snapshot..."
collect_ps_info

info "Collecting per-user memory breakdown..."
collect_user_mem

info "Collecting LPAR statistics..."
collect_lparstat

info "Running anomaly detection..."
detect_anomalies

info "Computing recommendations..."
compute_recommendation

END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
END_EPOCH=$(date '+%s' 2>/dev/null || perl -e 'print time()' 2>/dev/null || echo 0)
ELAPSED=$(( END_EPOCH - START_EPOCH ))

# =============================================================================
# TEXT REPORT
# =============================================================================
generate_text_report() {
  {
    echo "============================================================"
    echo "  AIX MEMORY ANALYSIS REPORT  v${SCRIPT_VERSION}"
    echo "  Host      : ${HOSTNAME}  (${SYS_MODEL:-unknown})"
    echo "  OS Level  : ${OSLEVEL}"
    echo "  LPAR      : ${SYS_LPAR:-N/A}"
    echo "  Started   : ${START_TIME}"
    echo "  Completed : ${END_TIME}  (elapsed: ${ELAPSED}s)"
    echo "============================================================"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [1] SYSTEM HARDWARE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Model        : ${SYS_MODEL:-N/A}"
    echo "  Serial       : ${SYS_SERIAL:-N/A}"
    echo "  CPU Type     : ${SYS_CPU_TYPE:-N/A}"
    echo "  vCPUs        : ${SYS_NCPU:-N/A}"
    echo "  Total Memory : ${G_TOTAL_MB} MB"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [2] GLOBAL MEMORY SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-22s %10s  %8s\n" "Category" "MB" "Percent"
    printf "  %-22s %10s  %8s\n" "──────────────────────" "──────────" "────────"
    printf "  %-22s %10s  %7s%%\n" "Total RAM"       "$G_TOTAL_MB"   "100.0"
    printf "  %-22s %10s  %7s%%\n" "In Use (total)"  "$G_INUSE_MB"   "$G_USED_PCT"
    printf "  %-22s %10s  %7s%%\n" "  Work (active)" "$G_INUSE_WORK_MB" "$(pct "$G_INUSE_WORK" "$G_SIZE_PG")"
    printf "  %-22s %10s  %7s%%\n" "  Client (cache)" "$G_INUSE_CLNT_MB" "$(pct "$G_INUSE_CLNT" "$G_SIZE_PG")"
    printf "  %-22s %10s  %7s%%\n" "Free"            "$G_FREE_MB"    "$G_FREE_PCT"
    printf "  %-22s %10s  %7s%%\n" "Available*"      "$G_AVAIL_MB"   "$G_AVAIL_PCT"
    printf "  %-22s %10s  %7s%%\n" "Pinned (total)"  "$G_PIN_MB"     "$G_PIN_PCT"
    printf "  %-22s %10s\n"        "  Pin Work"      "$G_PIN_WORK_MB"
    printf "  %-22s %10s\n"        "  Pin Other(kern)" "$G_PIN_OTHER_MB"
    printf "  %-22s %10s  %7s%%\n" "Virtual (AVM)"   "$G_VIRTUAL_MB" "$(pct "$G_VIRTUAL_PG" "$G_SIZE_PG")"
    echo ""
    echo "  * Available = Free + Client(file cache reclaimable)"
    echo ""
    printf "  %-22s %10s  %7s%%\n" "Paging Space"    "$G_PGSP_SIZE_MB"  "100.0"
    printf "  %-22s %10s  %7s%%\n" "  PgSp Used"     "$G_PGSP_INUSE_MB" "$G_PGSP_PCT"
    printf "  %-22s %10s\n"        "  PgSp Free"     "$(calc "$G_PGSP_SIZE_MB - $G_PGSP_INUSE_MB")"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [3] MEMORY BY CATEGORY (Work / Persistent / Client)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Raw svmon -G output:"
    echo "$SVMON_RAW"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [4] VMSTAT SNAPSHOT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    vmstat 2>/dev/null
    echo ""
    echo "  AVM (active virtual memory pages) : ${VM_AVM}"
    echo "  Free frames                        : ${VM_FRE}"
    echo "  Page-ins  (pi)                     : ${VM_PI}"
    echo "  Page-outs (po)                     : ${VM_PO}"
    echo "  Page frees (fr)                    : ${VM_FR}"
    echo "  Scan rate  (sr)                    : ${VM_SR}  (1-sec interval; 0=healthy)"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [5] PAGING SPACE DETAILS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    lsps -a 2>/dev/null
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [6] VMO MEMORY TUNABLES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-30s %s\n" "maxpin% (pinnable ceiling)"  "${VMO_MAXPINPCT}%"
    printf "  %-30s %s\n" "maxpin (pages)"               "${VMO_MAXPIN}"
    printf "  %-30s %s\n" "minperm (pages)"              "${VMO_MINPERM:-N/A}"
    printf "  %-30s %s\n" "maxperm (pages)"              "${VMO_MAXPERM:-N/A}"
    printf "  %-30s %s\n" "minfree (pages)"              "${VMO_MINFREE}"
    printf "  %-30s %s\n" "maxfree (pages)"              "${VMO_MAXFREE}"
    printf "  %-30s %s\n" "npskill (paging kill thresh)" "${VMO_NPSKILL}"
    printf "  %-30s %s\n" "npswarn (paging warn thresh)" "${VMO_NPSWARN}"
    printf "  %-30s %s\n" "vmm_klock_mode (spin lock)"   "${VMO_KLOCK}"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [7] TOP 10 MEMORY CONSUMING PROCESSES (svmon)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-12s %-18s %10s %10s %10s %10s\n" \
      "PID" "Command" "Inuse(MB)" "Pin(MB)" "Pgsp(MB)" "Virtual(MB)"
    printf "  %-12s %-18s %10s %10s %10s %10s\n" \
      "────────────" "──────────────────" "──────────" "──────────" "──────────" "──────────"
    RANK=1
    echo "$TOP_PROCS" | while IFS='|' read pid cmd inuse pin pgsp virt; do
      printf "  #%-11s %-18s %10s %10s %10s %10s\n" \
        "${RANK}:${pid}" "$cmd" "$inuse" "$pin" "$pgsp" "$virt"
      RANK=$(( RANK + 1 ))
    done
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [8] TOP 10 PROCESSES - DETAILED SEGMENT BREAKDOWN"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  [8a] Segment Category Summary per Process"
    echo "  ─────────────────────────────────────────────────────────"
    printf "  %-12s %-16s %8s %8s %8s %8s %8s %8s %8s %8s %8s %8s\n" \
      "PID" "Command" "Total" "Private" "ShrLibTx" "ShrLibDt" "Kernel" "WorkStor" "ClientFS" "SharedMem" "Mmap" "Pin"
    printf "  %-12s %-16s %8s %8s %8s %8s %8s %8s %8s %8s %8s %8s\n" \
      "────────────" "────────────────" "────────" "────────" "────────" "────────" "────────" "────────" "────────" "─────────" "────────" "────────"
    echo "$SEG_SUMMARY" | while IFS='|' read spid scmd stot spriv sslt ssld skern swks sclnt sshm smmap soth spin spgsp svirt; do
      printf "  %-12s %-16s %8s %8s %8s %8s %8s %8s %8s %9s %8s %8s\n" \
        "$spid" "$scmd" "$stot" "$spriv" "$sslt" "$ssld" "$skern" "$swks" "$sclnt" "$sshm" "$smmap" "$spin"
    done
    echo ""
    echo "  Columns (all MB): Total=process inuse, Private=process private heap/stack,"
    echo "  ShrLibTx=shared lib text, ShrLibDt=shared lib data, Kernel=kernel+system segs,"
    echo "  WorkStor=working storage, ClientFS=client/file-cache pages, SharedMem=SHM,"
    echo "  Mmap=memory-mapped files, Pin=pinned pages"
    echo ""
    echo "  [8b] Full Segment Detail (svmon -P)"
    echo "  ─────────────────────────────────────────────────────────"
    echo "$SVMON_PROC_DETAIL"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [9] TOP 15 PROCESSES - ps gvww (RSS/VSZ/%MEM)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$PS_RAW"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [10] MEMORY USAGE BY USER (svmon -U)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-20s %10s %10s %10s %10s\n" "User" "Inuse(MB)" "Pin(MB)" "Pgsp(MB)" "Virtual(MB)"
    printf "  %-20s %10s %10s %10s %10s\n" "────────────────────" "──────────" "──────────" "──────────" "──────────"
    echo "$USER_MEM_RAW" | while IFS='|' read usr inuse pin pgsp virt; do
      printf "  %-20s %10s %10s %10s %10s\n" "$usr" "$inuse" "$pin" "$pgsp" "$virt"
    done
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [11] LPAR STATISTICS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    lparstat 2>/dev/null
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [12] ANOMALY DETECTION RESULTS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -n "$CRITICALS" ]; then
      echo "  !! CRITICAL ALERTS !!"
      printf "$CRITICALS" | sed 's/^/  /'
    fi
    if [ -n "$WARNINGS" ]; then
      echo "  -- WARNINGS --"
      printf "$WARNINGS" | sed 's/^/  /'
    fi
    if [ -z "$CRITICALS" ] && [ -z "$WARNINGS" ]; then
      echo "  All checks PASSED. No anomalies detected."
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " [13] RECOMMENDATION – AVAILABLE MEMORY FOR APPLICATIONS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Status  : ${REC_STATUS}"
    echo "  Message : ${REC_MSG}"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " REPORT FILES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Log  : ${LOGFILE}"
    echo "  Text : ${TXT_REPORT}"
    echo "  HTML : ${HTML_REPORT}"
    echo ""
    echo "  Report generated by aix_mem_check.ksh v${SCRIPT_VERSION}"
    echo "============================================================"
  } > "$TXT_REPORT"
}

# =============================================================================
# HTML REPORT
# =============================================================================
generate_html_report() {
  # Build coloured badge for status
  case "$REC_STATUS" in
    HEALTHY)  BADGE_BG="#27ae60"; BADGE_TEXT="white" ;;
    CAUTION)  BADGE_BG="#e67e22"; BADGE_TEXT="white" ;;
    WARNING)  BADGE_BG="#c0392b"; BADGE_TEXT="white" ;;
    CRITICAL) BADGE_BG="#6c0000"; BADGE_TEXT="white" ;;
    *)        BADGE_BG="#555";    BADGE_TEXT="white" ;;
  esac

  # Compute bar widths
  USED_BAR=$(calc_int "$G_USED_PCT")
  FREE_BAR=$(calc_int "$G_FREE_PCT")
  PGSP_BAR=$(calc_int "$G_PGSP_PCT")
  PIN_BAR=$(calc_int "$G_PIN_PCT")

  # Build process table rows
  PROC_ROWS=""
  RANK=1
  echo "$TOP_PROCS" | while IFS='|' read pid cmd inuse pin pgsp virt; do
    INUSE_INT=$(calc_int "${inuse:-0}")
    if [ "$INUSE_INT" -ge "$WARN_PROC_MB" ]; then
      ROWCLASS=" class=\"warn-row\""
    else
      ROWCLASS=""
    fi
    echo "<tr${ROWCLASS}><td>#${RANK}</td><td>${pid}</td><td><strong>${cmd}</strong></td><td>${inuse}</td><td>${pin}</td><td>${pgsp}</td><td>${virt}</td></tr>"
    RANK=$(( RANK + 1 ))
  done > /tmp/.aix_proc_rows_$$
  PROC_ROWS=$(cat /tmp/.aix_proc_rows_$$ 2>/dev/null)
  rm -f /tmp/.aix_proc_rows_$$

  # Build segment summary rows for HTML
  echo "$SEG_SUMMARY" | while IFS='|' read spid scmd stot spriv sslt ssld skern swks sclnt sshm smmap soth spin spgsp svirt; do
    echo "<tr><td>${spid}</td><td><strong>${scmd}</strong></td><td>${stot}</td><td>${spriv}</td><td>${sslt}</td><td>${ssld}</td><td>${skern}</td><td>${swks}</td><td>${sclnt}</td><td>${sshm}</td><td>${smmap}</td><td>${spin}</td></tr>"
  done > /tmp/.aix_seg_rows_$$
  SEG_SUMMARY_ROWS=$(cat /tmp/.aix_seg_rows_$$ 2>/dev/null)
  rm -f /tmp/.aix_seg_rows_$$

  # Build user memory rows
  USER_ROWS=""
  echo "$USER_MEM_RAW" | while IFS='|' read usr inuse pin pgsp virt; do
    echo "<tr><td>${usr}</td><td>${inuse}</td><td>${pin}</td><td>${pgsp}</td><td>${virt}</td></tr>"
  done > /tmp/.aix_user_rows_$$
  USER_ROWS=$(cat /tmp/.aix_user_rows_$$ 2>/dev/null)
  rm -f /tmp/.aix_user_rows_$$

  # Build ps rows
  # Columns: 1=PID 2=TTY 3=STAT 4=TIME 5=PGIN 6=SIZE(VSZ) 7=RSS 8=LIM 9=TSIZ 10=TRS 11=%CPU 12=%MEM 13=CMD
  PS_ROWS=$(echo "$PS_RAW" | tail -n +2 | awk '{
    pmem = ($12 == "xx" || $12+0 == 0) ? "n/a" : $12"%"
    cmd  = $13
    for (i=14; i<=NF; i++) cmd = cmd " " $i
    printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n",
      $1,$2,$3,$6,$7,pmem,cmd
  }')

  # Anomaly HTML
  ANOMALY_HTML=""
  if [ -n "$CRITICALS" ]; then
    ANOMALY_HTML="${ANOMALY_HTML}<div class='alert crit'><strong>CRITICAL</strong><br>$(printf "$CRITICALS" | sed 's/^CRITICAL: //' | sed 's/$/<br>/')</div>"
  fi
  if [ -n "$WARNINGS" ]; then
    ANOMALY_HTML="${ANOMALY_HTML}<div class='alert warn'><strong>WARNING</strong><br>$(printf "$WARNINGS" | sed 's/^WARNING: //' | sed 's/$/<br>/')</div>"
  fi
  if [ -z "$CRITICALS" ] && [ -z "$WARNINGS" ]; then
    ANOMALY_HTML="<div class='alert ok'><strong>All checks PASSED.</strong> No anomalies detected.</div>"
  fi

  # svmon detail – pre-formatted
  SVMON_DETAIL_HTML=$(echo "$SVMON_PROC_DETAIL" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

  cat > "$HTML_REPORT" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>AIX Memory Report - ${HOSTNAME} - ${START_TIME}</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,"Segoe UI",system-ui,sans-serif;font-size:14px;line-height:1.6;background:#f7f8fa;color:#1f2328}
  .container{max-width:960px;margin:0 auto;padding:20px}
  h1{font-size:20px;margin-bottom:4px}
  h2{font-size:15px;margin:24px 0 8px;padding:6px 10px;background:#1f2328;color:#fff;border-radius:4px}
  h3{font-size:13px;margin:16px 0 6px;color:#57606a}
  .meta{font-size:12px;color:#57606a;margin-bottom:20px}
  .badge{display:inline-block;padding:4px 14px;border-radius:12px;font-weight:700;font-size:13px;color:${BADGE_TEXT};background:${BADGE_BG};vertical-align:middle}
  .card{background:#fff;border:1px solid #e5e7eb;border-radius:6px;padding:16px;margin-bottom:16px}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}
  .grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
  .stat-box{background:#fff;border:1px solid #e5e7eb;border-radius:6px;padding:12px;text-align:center}
  .stat-box .val{font-size:22px;font-weight:700;color:#3b82d4}
  .stat-box .lbl{font-size:11px;color:#57606a;margin-top:2px}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th{background:#f0f2f5;text-align:left;padding:7px 10px;border-bottom:2px solid #e5e7eb;white-space:nowrap}
  td{padding:6px 10px;border-bottom:1px solid #f0f2f5;font-family:monospace}
  tr:hover td{background:#f7f8fa}
  .warn-row td{background:#fff8e1}
  .bar-wrap{background:#e5e7eb;border-radius:4px;height:16px;margin:4px 0;overflow:hidden}
  .bar{height:100%;border-radius:4px;display:flex;align-items:center;justify-content:flex-end;padding-right:4px;font-size:11px;font-weight:600;color:#fff;min-width:20px}
  .bar-used{background:#3b82d4}
  .bar-free{background:#27ae60}
  .bar-pin{background:#7c5cd8}
  .bar-pgsp{background:#e67e22}
  .bar-warn{background:#c0392b}
  .alert{padding:10px 14px;border-radius:4px;margin:6px 0;font-size:13px}
  .alert.crit{background:#fdecea;border-left:4px solid #c0392b;color:#7b1e1e}
  .alert.warn{background:#fff8e1;border-left:4px solid #e67e22;color:#7a4200}
  .alert.ok  {background:#e8f5e9;border-left:4px solid #27ae60;color:#1a5c2a}
  .rec-box{padding:14px 18px;border-radius:6px;border:2px solid ${BADGE_BG};background:#fff;margin-top:8px}
  pre{font-size:12px;font-family:monospace;white-space:pre;overflow-x:auto;background:#f7f8fa;padding:12px;border-radius:4px;border:1px solid #e5e7eb}
  .footer{text-align:center;font-size:11px;color:#57606a;border-top:1px solid #e5e7eb;margin-top:30px;padding-top:10px}
  .section-note{font-size:11px;color:#57606a;margin-top:4px}
</style>
</head>
<body>
<div class="container">
  <h1>AIX Memory Analysis Report &nbsp; <span class="badge">${REC_STATUS}</span></h1>
  <div class="meta">
    Host: <strong>${HOSTNAME}</strong> &nbsp;|&nbsp;
    Model: <strong>${SYS_MODEL:-N/A}</strong> &nbsp;|&nbsp;
    OS: <strong>${OSLEVEL}</strong> &nbsp;|&nbsp;
    LPAR: <strong>${SYS_LPAR:-N/A}</strong><br>
    Started: <strong>${START_TIME}</strong> &nbsp;|&nbsp;
    Completed: <strong>${END_TIME}</strong> &nbsp;|&nbsp;
    Elapsed: <strong>${ELAPSED}s</strong>
  </div>

  <!-- Summary boxes -->
  <div class="grid4">
    <div class="stat-box"><div class="val">${G_TOTAL_MB}</div><div class="lbl">Total RAM (MB)</div></div>
    <div class="stat-box"><div class="val">${G_INUSE_MB}</div><div class="lbl">In Use (MB) &nbsp;${G_USED_PCT}%</div></div>
    <div class="stat-box"><div class="val">${G_FREE_MB}</div><div class="lbl">Free (MB) &nbsp;${G_FREE_PCT}%</div></div>
    <div class="stat-box"><div class="val">${G_AVAIL_MB}</div><div class="lbl">Available* (MB) &nbsp;${G_AVAIL_PCT}%</div></div>
  </div>
  <p class="section-note" style="margin:6px 0 14px 2px">* Available = Free + Reclaimable File Cache (client pages)</p>

  <!-- Memory bars -->
  <div class="card">
    <h3>Memory Utilisation</h3>
    <table style="width:100%;font-size:12px">
      <tr>
        <td style="width:160px">Used (${G_USED_PCT}%)</td>
        <td><div class="bar-wrap"><div class="bar bar-used" style="width:${USED_BAR}%">${G_USED_PCT}%</div></div></td>
        <td style="width:80px;text-align:right">${G_INUSE_MB} MB</td>
      </tr>
      <tr>
        <td>Free (${G_FREE_PCT}%)</td>
        <td><div class="bar-wrap"><div class="bar bar-free" style="width:${FREE_BAR}%">${G_FREE_PCT}%</div></div></td>
        <td style="text-align:right">${G_FREE_MB} MB</td>
      </tr>
      <tr>
        <td>Pinned (${G_PIN_PCT}%)</td>
        <td><div class="bar-wrap"><div class="bar bar-pin" style="width:${PIN_BAR}%">${G_PIN_PCT}%</div></div></td>
        <td style="text-align:right">${G_PIN_MB} MB</td>
      </tr>
      <tr>
        <td>Paging Space (${G_PGSP_PCT}%)</td>
        <td><div class="bar-wrap"><div class="bar bar-pgsp" style="width:${PGSP_BAR}%">${G_PGSP_PCT}%</div></div></td>
        <td style="text-align:right">${G_PGSP_INUSE_MB}/${G_PGSP_SIZE_MB} MB</td>
      </tr>
    </table>
  </div>

  <!-- Detailed breakdown -->
  <h2>1. Global Memory Breakdown</h2>
  <div class="card">
    <table>
      <tr><th>Category</th><th>MB</th><th>Pages</th><th>% of Total</th></tr>
      <tr><td>Total RAM</td><td>${G_TOTAL_MB}</td><td>${G_SIZE_PG}</td><td>100%</td></tr>
      <tr><td><strong>In Use (total)</strong></td><td><strong>${G_INUSE_MB}</strong></td><td>${G_INUSE_PG}</td><td>${G_USED_PCT}%</td></tr>
      <tr><td>&nbsp;&nbsp;↳ Work (active application)</td><td>${G_INUSE_WORK_MB}</td><td>${G_INUSE_WORK}</td><td>$(pct "$G_INUSE_WORK" "$G_SIZE_PG")%</td></tr>
      <tr><td>&nbsp;&nbsp;↳ Client (file cache)</td><td>${G_INUSE_CLNT_MB}</td><td>${G_INUSE_CLNT}</td><td>$(pct "$G_INUSE_CLNT" "$G_SIZE_PG")%</td></tr>
      <tr><td>Free</td><td>${G_FREE_MB}</td><td>${G_FREE_PG}</td><td>${G_FREE_PCT}%</td></tr>
      <tr><td><strong>Available (Free + Cache)</strong></td><td><strong>${G_AVAIL_MB}</strong></td><td>—</td><td>${G_AVAIL_PCT}%</td></tr>
      <tr><td>Pinned (total)</td><td>${G_PIN_MB}</td><td>${G_PIN_PG}</td><td>${G_PIN_PCT}%</td></tr>
      <tr><td>&nbsp;&nbsp;↳ Pin Work (kernel pinned)</td><td>${G_PIN_WORK_MB}</td><td>${G_PIN_WORK}</td><td>$(pct "$G_PIN_WORK" "$G_SIZE_PG")%</td></tr>
      <tr><td>&nbsp;&nbsp;↳ Pin Other (DMA/kernel struct)</td><td>${G_PIN_OTHER_MB}</td><td>${G_PIN_OTHER}</td><td>$(pct "$G_PIN_OTHER" "$G_SIZE_PG")%</td></tr>
      <tr><td>Virtual (AVM)</td><td>${G_VIRTUAL_MB}</td><td>${G_VIRTUAL_PG}</td><td>$(pct "$G_VIRTUAL_PG" "$G_SIZE_PG")%</td></tr>
      <tr><td>Paging Space (total)</td><td>${G_PGSP_SIZE_MB}</td><td>${G_PGSP_SIZE}</td><td>—</td></tr>
      <tr><td>&nbsp;&nbsp;↳ Paging Space Used</td><td>${G_PGSP_INUSE_MB}</td><td>${G_PGSP_INUSE}</td><td>${G_PGSP_PCT}%</td></tr>
    </table>
  </div>

  <h2>2. VMO Kernel Memory Tunables</h2>
  <div class="card">
    <table>
      <tr><th>Parameter</th><th>Value</th><th>Description</th></tr>
      <tr><td>maxpin%</td><td>${VMO_MAXPINPCT}%</td><td>Max % of RAM that can be pinned</td></tr>
      <tr><td>maxpin (pages)</td><td>${VMO_MAXPIN}</td><td>Absolute pinnable page limit</td></tr>
      <tr><td>minperm (pages)</td><td>${VMO_MINPERM:-N/A}</td><td>Min persistent pages to keep cached</td></tr>
      <tr><td>maxperm (pages)</td><td>${VMO_MAXPERM:-N/A}</td><td>Max persistent pages before stealing</td></tr>
      <tr><td>minfree (pages)</td><td>${VMO_MINFREE}</td><td>VMM starts reclaiming below this</td></tr>
      <tr><td>maxfree (pages)</td><td>${VMO_MAXFREE}</td><td>VMM stops reclaiming above this</td></tr>
      <tr><td>npskill (pages)</td><td>${VMO_NPSKILL}</td><td>Paging space threshold – kills processes</td></tr>
      <tr><td>npswarn (pages)</td><td>${VMO_NPSWARN}</td><td>Paging space threshold – warning</td></tr>
      <tr><td>vmm_klock_mode</td><td>${VMO_KLOCK}</td><td>Spin lock mode (2=adaptive, best)</td></tr>
    </table>
  </div>

  <h2>3. vmstat Snapshot</h2>
  <div class="card">
    <table>
      <tr><th>Metric</th><th>Value</th><th>Interpretation</th></tr>
      <tr><td>AVM (active virtual pages)</td><td>${VM_AVM}</td><td>$(calc "$VM_AVM * $PAGESIZE_BYTES / 1048576") MB working set</td></tr>
      <tr><td>Free frames</td><td>${VM_FRE}</td><td>$(calc "$VM_FRE * $PAGESIZE_BYTES / 1048576") MB</td></tr>
      <tr><td>Page-ins (pi)</td><td>${VM_PI}</td><td>$([ "${VM_PI:-0}" -eq 0 ] && echo "Normal – no paging" || echo "Active paging in progress")</td></tr>
      <tr><td>Page-outs (po)</td><td>${VM_PO}</td><td>$([ "${VM_PO:-0}" -eq 0 ] && echo "Normal – no paging" || echo "Pages being pushed to swap")</td></tr>
      <tr><td>Scan rate (sr) — 1-sec interval</td><td>${VM_SR}</td><td>$([ "${VM_SR:-0}" -eq 0 ] && echo "Normal – VMM idle" || { [ "${VM_SR:-0}" -gt 200 ] && echo "High – VMM under significant memory pressure" || echo "Low – VMM reclaiming file-cache pages (normal)"; })</td></tr>
      <tr><td>CPU User%</td><td>${VM_CPU_US:-N/A}%</td><td></td></tr>
      <tr><td>CPU Sys%</td><td>${VM_CPU_SY:-N/A}%</td><td></td></tr>
      <tr><td>CPU Idle%</td><td>${VM_CPU_ID:-N/A}%</td><td></td></tr>
      <tr><td>CPU iowait%</td><td>${VM_CPU_WA:-N/A}%</td><td></td></tr>
    </table>
  </div>

  <h2>4. Paging Space</h2>
  <div class="card">
    <pre>$(lsps -a 2>/dev/null)</pre>
  </div>

  <h2>5. Top 10 Memory Consuming Processes</h2>
  <div class="card">
    <table>
      <tr><th>#</th><th>PID</th><th>Command</th><th>Inuse (MB)</th><th>Pin (MB)</th><th>Pgsp (MB)</th><th>Virtual (MB)</th></tr>
      ${PROC_ROWS}
    </table>
    <p class="section-note">Rows highlighted in amber exceed ${WARN_PROC_MB}MB threshold.</p>
  </div>

  <h2>6. Top 10 Processes – Detailed Segment Breakdown (svmon)</h2>
  <div class="card">
    <h3>6a. Segment Category Summary (all values in MB)</h3>
    <table>
      <tr>
        <th>PID</th><th>Command</th>
        <th title="Total process inuse MB">Total</th>
        <th title="Process private heap / stack">Private</th>
        <th title="Shared library text (code)">ShrLib Text</th>
        <th title="Shared library data">ShrLib Data</th>
        <th title="Kernel segment + System segment">Kernel/Sys</th>
        <th title="Working storage segments">Work Stor</th>
        <th title="Client / file-cache pages">Client FS</th>
        <th title="Shared memory segments">Shared Mem</th>
        <th title="Memory-mapped files">Mmap</th>
        <th title="Total pinned pages">Pinned</th>
      </tr>
      ${SEG_SUMMARY_ROWS}
    </table>
    <p class="section-note">
      <strong>Private</strong> = heap+stack exclusive to this process &nbsp;|&nbsp;
      <strong>ShrLib Text/Data</strong> = shared libraries mapped read-only or copy-on-write &nbsp;|&nbsp;
      <strong>Kernel/Sys</strong> = kernel segment + system segment in every process's address space &nbsp;|&nbsp;
      <strong>Work Stor</strong> = additional working storage allocated by the process &nbsp;|&nbsp;
      <strong>Client FS</strong> = file-cache pages mapped into this process &nbsp;|&nbsp;
      <strong>Shared Mem</strong> = SysV / POSIX shared memory &nbsp;|&nbsp;
      <strong>Mmap</strong> = memory-mapped file regions &nbsp;|&nbsp;
      <strong>Pinned</strong> = pages locked in RAM (cannot be stolen by VMM)
    </p>
    <h3 style="margin-top:16px">6b. Full Segment Detail per Process (svmon -P output)</h3>
    <pre>${SVMON_DETAIL_HTML}</pre>
  </div>

  <h2>7. Process Memory Detail – ps gvww (RSS / VSZ / %MEM)</h2>
  <div class="card">
    <table>
      <tr><th>PID</th><th>TTY</th><th>STAT</th><th>SIZE(KB)</th><th>RSS(KB)</th><th>%MEM</th><th>COMMAND</th></tr>
      ${PS_ROWS}
    </table>
    <p class="section-note">SIZE=virtual, RSS=resident, %MEM=percent of real RAM</p>
  </div>

  <h2>8. Memory by User (svmon -U)</h2>
  <div class="card">
    <table>
      <tr><th>User</th><th>Inuse (MB)</th><th>Pin (MB)</th><th>Pgsp (MB)</th><th>Virtual (MB)</th></tr>
      ${USER_ROWS}
    </table>
  </div>

  <h2>9. LPAR / CPU Statistics</h2>
  <div class="card">
    <pre>$(lparstat 2>/dev/null)</pre>
  </div>

  <h2>10. Anomaly Detection</h2>
  <div class="card">
    ${ANOMALY_HTML}
  </div>

  <h2>11. Recommendation – Memory Available for Application Hosting</h2>
  <div class="rec-box">
    <strong>${REC_ICON} ${REC_STATUS}</strong><br>${REC_MSG}
    <br><br>
    <strong>Reference guide (healthy AIX system):</strong>
    <ul style="margin:6px 0 0 18px;font-size:13px">
      <li>Keep used memory &lt; 85% for normal operations</li>
      <li>Keep paging space &lt; 50%; &gt;80% is emergency territory</li>
      <li>Client (file cache) pages are reclaimable – they protect I/O performance</li>
      <li>Pinned pages cannot be stolen by VMM – watch if &gt;80% of RAM is pinned</li>
      <li>vmm_klock_mode=2 (adaptive spin locks) is the optimal kernel locking mode</li>
      <li>Zero page-in/page-out in vmstat = no active paging = healthy</li>
    </ul>
  </div>

  <h2>12. Raw svmon -G Output</h2>
  <div class="card">
    <pre>$(echo "$SVMON_RAW")</pre>
  </div>

  <div class="footer">
    Report generated by <strong>aix_mem_check.ksh v${SCRIPT_VERSION}</strong> &nbsp;|&nbsp;
    Log: ${LOGFILE} &nbsp;|&nbsp; Text: ${TXT_REPORT}<br>
    Made with IBM Bob
  </div>
</div>
</body>
</html>
HTMLEOF
}

# =============================================================================
# Verification
# =============================================================================
verify_output() {
  local rc=0
  log "[VERIFY] Checking report files..."

  if [ ! -f "$TXT_REPORT" ] || [ ! -s "$TXT_REPORT" ]; then
    crit "Text report missing or empty: ${TXT_REPORT}"
    rc=1
  else
    ok "Text report OK: ${TXT_REPORT} ($(wc -c < "$TXT_REPORT") bytes)"
  fi

  if [ ! -f "$HTML_REPORT" ] || [ ! -s "$HTML_REPORT" ]; then
    crit "HTML report missing or empty: ${HTML_REPORT}"
    rc=1
  else
    ok "HTML report OK: ${HTML_REPORT} ($(wc -c < "$HTML_REPORT") bytes)"
  fi

  # Sanity: total MB should be > 0
  TOTAL_INT=$(calc_int "$G_TOTAL_MB")
  if [ "$TOTAL_INT" -le 0 ]; then
    crit "VERIFY FAILED: Total memory reported as ${G_TOTAL_MB} MB – data collection error"
    rc=1
  else
    ok "Memory data verified: Total=${G_TOTAL_MB}MB Used=${G_INUSE_MB}MB Free=${G_FREE_MB}MB"
  fi

  # Sanity: used + free should roughly equal total
  SUM_CHECK=$(calc_int "$G_INUSE_MB + $G_FREE_MB")
  DIFF=$(calc_int "$G_TOTAL_MB - $SUM_CHECK")
  # Allow 5% variance (client / persistent pages)
  DIFF_PCT=$(awk "BEGIN{if($G_TOTAL_MB==0)print 100;else printf \"%d\",($DIFF/$G_TOTAL_MB)*100}")
  if [ "$DIFF_PCT" -gt 20 ] 2>/dev/null; then
    warn "VERIFY: Used+Free (${SUM_CHECK}MB) deviates from Total (${G_TOTAL_MB}MB) by ${DIFF_PCT}% – normal for large persistent cache"
  else
    ok "Memory accounting check passed (variance ${DIFF_PCT}%)"
  fi

  return $rc
}

# =============================================================================
# Main execution
# =============================================================================
hdr ""
hdr "  AIX Memory Check v${SCRIPT_VERSION} — $(date)"
hdr "  Host: ${HOSTNAME}  |  OS: ${OSLEVEL}"
hdr ""

info "Generating text report..."
generate_text_report

info "Generating HTML report..."
generate_html_report

info "Verifying output..."
verify_output
VERIFY_RC=$?

END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
END_EPOCH=$(date '+%s' 2>/dev/null || perl -e 'print time()' 2>/dev/null || echo "$START_EPOCH")
ELAPSED=$(( END_EPOCH - START_EPOCH ))

echo ""
hdr "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
hdr " EXECUTION COMPLETE"
hdr "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Start     : ${START_TIME}"
echo "  End       : ${END_TIME}"
echo "  Elapsed   : ${ELAPSED} seconds"
echo ""
echo "  Status    : ${REC_STATUS}"
echo "  Message   : ${REC_MSG}"
echo ""
if [ -n "$CRITICALS" ]; then
  printf "${RED}$CRITICALS${RESET}"
fi
if [ -n "$WARNINGS" ]; then
  printf "${YELLOW}$WARNINGS${RESET}"
fi
echo ""
echo "  Log  file : ${LOGFILE}"
echo "  Text report: ${TXT_REPORT}"
echo "  HTML report: ${HTML_REPORT}"
hdr "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log "Script completed. RC=${VERIFY_RC}"
exit $VERIFY_RC

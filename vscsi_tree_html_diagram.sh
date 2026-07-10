#!/bin/ksh
#
# vscsi_tree_html_diagram.sh - Interactive HTML vSCSI Tree Diagram
# Description: Generates a fully self-contained interactive HTML file showing
#              Virtual SCSI (vSCSI) adapter mapping tree on IBM VIOS.
#              Layout: VIOS -> vhost (SVSA) -> VTD -> Backing Device (LV/ISO/PV)
# Author: Bob
# Version: 1.1
#

OUTPUT_DIR="/home/padmin"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/vscsi_tree_${TIMESTAMP}.html"
TMP_PREFIX="/tmp/vscsi_html_$$"

# ── Helpers ───────────────────────────────────────────────────────────────────
cleanup() { rm -f "${TMP_PREFIX}"_*.tmp 2>/dev/null; }
trap cleanup EXIT

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Must run as root" >&2
        exit 1
    fi
}

# ── Data collection ───────────────────────────────────────────────────────────
collect_data() {
    VIOS_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
    VIOS_OSLEVEL=$(oslevel -s 2>/dev/null || echo "N/A")
    COLLECT_DATE=$(date)

    # ── vSCSI mappings: lsmap -all -dec -fmt : ────────────────────────────────
    # Fields: svsa:physloc:clntid(dec):vtd:status:lun:backing:physloc2:mirrored
    /usr/ios/cli/ioscli lsmap -all -dec -fmt : \
        2>/dev/null > "${TMP_PREFIX}_lsmap.tmp"

    # ── Physical disk info: lspv -fmt : ──────────────────────────────────────
    # Fields: name:pvid:vg
    /usr/ios/cli/ioscli lspv -fmt : -field name pvid vg \
        2>/dev/null > "${TMP_PREFIX}_lspv.tmp"

    # ── Physical disk sizes via lsattr ────────────────────────────────────────
    > "${TMP_PREFIX}_disksize.tmp"
    while IFS=: read -r dname dpvid dvg; do
        [ -z "$dname" ] && continue
        sz=$(lsattr -El "$dname" -a size_in_mb 2>/dev/null | awk 'NR==1 {print $2}')
        [ -z "$sz" ] && sz="N/A"
        uid=$(lsattr -El "$dname" -a unique_id 2>/dev/null | awk 'NR==1 {print $2}')
        [ -z "$uid" ] && uid="N/A"
        echo "${dname}|${sz}|${uid}" >> "${TMP_PREFIX}_disksize.tmp"
    done < "${TMP_PREFIX}_lspv.tmp"

    # ── LV details: lslv -fmt : <lvname> ─────────────────────────────────────
    # For each backing device that is an LV (not a path), collect its details.
    # lslv -fmt : output fields (position-based):
    #   1:lvname 2:vgname 3:lvid 4:permission 5:vgstate 6:lvstate
    #   7:type 8:writeverify 9:maxlps 10:ppsize 11:copies 12:schedpolicy
    #   13:lps 14:pps 15:stalepps 16:bbpolicy ...
    > "${TMP_PREFIX}_lslv.tmp"
    while IFS=: read -r svsa physloc clntid vtd status lun backing physloc2 mirrored; do
        [ -z "$backing" ] && continue
        # Skip ISO files and "N/A" entries
        case "$backing" in
            /*|N/A|"") continue ;;
        esac
        # Check if LV details already collected
        grep -q "^${backing}|" "${TMP_PREFIX}_lslv.tmp" 2>/dev/null && continue
        # Collect LV info
        lvline=$(/usr/ios/cli/ioscli lslv -fmt : "$backing" 2>/dev/null | head -1)
        if [ -n "$lvline" ]; then
            lv_vg=$(echo "$lvline" | cut -d: -f2)
            lv_id=$(echo "$lvline" | cut -d: -f3)
            lv_state=$(echo "$lvline" | cut -d: -f6)
            lv_type=$(echo "$lvline" | cut -d: -f7)
            lv_ppsize=$(echo "$lvline" | cut -d: -f10)
            lv_copies=$(echo "$lvline" | cut -d: -f11)
            lv_lps=$(echo "$lvline" | cut -d: -f13)
            lv_pps=$(echo "$lvline" | cut -d: -f14)
            # Size = LPs * PP_size_MB
            pp_mb=$(echo "$lv_ppsize" | awk '{print $1}')
            lv_size_mb=$(( lv_lps * pp_mb )) 2>/dev/null || lv_size_mb="N/A"
            echo "${backing}|${lv_vg}|${lv_id}|${lv_state}|${lv_type}|${lv_ppsize}|${lv_copies}|${lv_lps}|${lv_pps}|${lv_size_mb}" \
                >> "${TMP_PREFIX}_lslv.tmp"
        else
            echo "${backing}|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A" >> "${TMP_PREFIX}_lslv.tmp"
        fi
    done < "${TMP_PREFIX}_lsmap.tmp"

    # ── VG details: lsvg <vgname> ─────────────────────────────────────────────
    > "${TMP_PREFIX}_lsvg.tmp"
    while IFS='|' read -r lv_name lv_vg rest; do
        [ -z "$lv_vg" ] || [ "$lv_vg" = "N/A" ] && continue
        grep -q "^${lv_vg}|" "${TMP_PREFIX}_lsvg.tmp" 2>/dev/null && continue
        vginfo=$(/usr/ios/cli/ioscli lsvg "$lv_vg" 2>/dev/null)
        if [ -n "$vginfo" ]; then
            # lsvg has 2-column layout; match each keyword then grab value after ":"
            vg_state=$(echo  "$vginfo" | awk '/VG STATE:/  {match($0,/VG STATE:[[:space:]]*/); s=substr($0,RSTART+RLENGTH); sub(/[[:space:]].*/,"",s); print s; exit}')
            vg_ppsize=$(echo "$vginfo" | awk '/PP SIZE:/   {match($0,/PP SIZE:[[:space:]]*/);  s=substr($0,RSTART+RLENGTH); sub(/[[:space:]]*$/,"",s); print s; exit}')
            vg_tpps=$(echo   "$vginfo" | awk '/TOTAL PPs:/ {match($0,/TOTAL PPs:[[:space:]]*/);s=substr($0,RSTART+RLENGTH); split(s,a," "); print a[1]; exit}')
            vg_fpps=$(echo   "$vginfo" | awk '/FREE PPs:/  {match($0,/FREE PPs:[[:space:]]*/); s=substr($0,RSTART+RLENGTH); split(s,a," "); print a[1]; exit}')
            vg_upps=$(echo   "$vginfo" | awk '/USED PPs:/  {match($0,/USED PPs:[[:space:]]*/); s=substr($0,RSTART+RLENGTH); split(s,a," "); print a[1]; exit}')
            vg_pvs=$(echo    "$vginfo" | awk '/TOTAL PVs:/ {match($0,/TOTAL PVs:[[:space:]]*/);s=substr($0,RSTART+RLENGTH); split(s,a," "); print a[1]; exit}')
            vg_lvs=$(echo    "$vginfo" | awk '/^LVs:/      {match($0,/LVs:[[:space:]]*/);      s=substr($0,RSTART+RLENGTH); split(s,a," "); print a[1]; exit}')
            # Find PVs in this VG
            vg_pvlist=$(grep ":${lv_vg}$" "${TMP_PREFIX}_lspv.tmp" 2>/dev/null \
                        | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
            [ -z "$vg_pvlist" ] && vg_pvlist="N/A"
            echo "${lv_vg}|${vg_state}|${vg_ppsize}|${vg_tpps}|${vg_fpps}|${vg_upps}|${vg_pvs}|${vg_lvs}|${vg_pvlist}" \
                >> "${TMP_PREFIX}_lsvg.tmp"
        else
            echo "${lv_vg}|N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A" >> "${TMP_PREFIX}_lsvg.tmp"
        fi
    done < "${TMP_PREFIX}_lslv.tmp"
}

# ── HTML generation ───────────────────────────────────────────────────────────
generate_html() {

# ── Build JavaScript DATA array from collected data ───────────────────────────
VHOST_JS=""
while IFS=: read -r svsa physloc clntid vtd vtd_status lun backing physloc2 mirrored; do
    [ -z "$svsa" ] && continue

    # Determine backing device type and enrich with detail
    btype="lv"
    case "$backing" in
        /*) btype="iso" ;;
        N/A|"") btype="none" ;;
    esac

    # LV details
    lv_vg="N/A"; lv_id="N/A"; lv_state="N/A"; lv_type="N/A"
    lv_ppsize="N/A"; lv_copies="N/A"; lv_lps="N/A"; lv_pps="N/A"; lv_size_mb="N/A"
    if [ "$btype" = "lv" ]; then
        LVLINE=$(grep "^${backing}|" "${TMP_PREFIX}_lslv.tmp" 2>/dev/null | head -1)
        if [ -n "$LVLINE" ]; then
            lv_vg=$(echo "$LVLINE" | cut -d'|' -f2)
            lv_id=$(echo "$LVLINE" | cut -d'|' -f3)
            lv_state=$(echo "$LVLINE" | cut -d'|' -f4)
            lv_type=$(echo "$LVLINE" | cut -d'|' -f5)
            lv_ppsize=$(echo "$LVLINE" | cut -d'|' -f6)
            lv_copies=$(echo "$LVLINE" | cut -d'|' -f7)
            lv_lps=$(echo "$LVLINE" | cut -d'|' -f8)
            lv_pps=$(echo "$LVLINE" | cut -d'|' -f9)
            lv_size_mb=$(echo "$LVLINE" | cut -d'|' -f10)
        fi
    fi

    # VG details (for LV-backed VTDs)
    vg_state="N/A"; vg_ppsize="N/A"; vg_tpps="N/A"; vg_fpps="N/A"
    vg_upps="N/A"; vg_pvs="N/A"; vg_lvs="N/A"; vg_pvlist="N/A"
    if [ "$btype" = "lv" ] && [ "$lv_vg" != "N/A" ]; then
        VGLINE=$(grep "^${lv_vg}|" "${TMP_PREFIX}_lsvg.tmp" 2>/dev/null | head -1)
        if [ -n "$VGLINE" ]; then
            vg_state=$(echo "$VGLINE" | cut -d'|' -f2)
            vg_ppsize=$(echo "$VGLINE" | cut -d'|' -f3)
            vg_tpps=$(echo "$VGLINE" | cut -d'|' -f4)
            vg_fpps=$(echo "$VGLINE" | cut -d'|' -f5)
            vg_upps=$(echo "$VGLINE" | cut -d'|' -f6)
            vg_pvs=$(echo "$VGLINE" | cut -d'|' -f7)
            vg_lvs=$(echo "$VGLINE" | cut -d'|' -f8)
            vg_pvlist=$(echo "$VGLINE" | cut -d'|' -f9)
        fi
    fi

    # Format LV size in GB
    lv_size_gb="N/A"
    if echo "$lv_size_mb" | grep -q '^[0-9]'; then
        lv_size_gb=$(awk "BEGIN {printf \"%.1f GB\", ${lv_size_mb}/1024}" 2>/dev/null)
    fi

    # Decode client ID hex to decimal if needed (lsmap -dec already returns decimal)
    clntid_dec="$clntid"

    VHOST_JS="${VHOST_JS}
      {
        svsa: '${svsa}',
        physloc: '${physloc}',
        clntid: '${clntid_dec}',
        vtd: '${vtd}',
        vtd_status: '${vtd_status}',
        lun: '${lun}',
        backing: '${backing}',
        physloc2: '${physloc2}',
        mirrored: '${mirrored}',
        btype: '${btype}',
        lv_vg: '${lv_vg}',
        lv_id: '${lv_id}',
        lv_state: '${lv_state}',
        lv_type: '${lv_type}',
        lv_ppsize: '${lv_ppsize}',
        lv_copies: '${lv_copies}',
        lv_lps: '${lv_lps}',
        lv_pps: '${lv_pps}',
        lv_size_mb: '${lv_size_mb}',
        lv_size_gb: '${lv_size_gb}',
        vg_state: '${vg_state}',
        vg_ppsize: '${vg_ppsize}',
        vg_tpps: '${vg_tpps}',
        vg_fpps: '${vg_fpps}',
        vg_upps: '${vg_upps}',
        vg_pvs: '${vg_pvs}',
        vg_lvs: '${vg_lvs}',
        vg_pvlist: '${vg_pvlist}'
      },"
done < "${TMP_PREFIX}_lsmap.tmp"

# ── Build PV table JS ─────────────────────────────────────────────────────────
PV_JS=""
while IFS=: read -r dname dpvid dvg; do
    [ -z "$dname" ] && continue
    SZLINE=$(grep "^${dname}|" "${TMP_PREFIX}_disksize.tmp" 2>/dev/null | head -1)
    dsz=$(echo "$SZLINE" | cut -d'|' -f2)
    duid=$(echo "$SZLINE" | cut -d'|' -f3)
    [ -z "$dsz" ] && dsz="N/A"
    [ -z "$duid" ] && duid="N/A"
    dsz_gb="N/A"
    if echo "$dsz" | grep -q '^[0-9]'; then
        dsz_gb=$(awk "BEGIN {printf \"%.1f GB\", ${dsz}/1024}" 2>/dev/null)
    fi
    PV_JS="${PV_JS}
      { name:'${dname}', pvid:'${dpvid}', vg:'${dvg}', size_mb:'${dsz}', size_gb:'${dsz_gb}', uid:'${duid}' },"
done < "${TMP_PREFIX}_lspv.tmp"

# ── Write HTML ────────────────────────────────────────────────────────────────
cat > "${OUTPUT_FILE}" << 'HEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
HEOF

echo "<title>vSCSI Tree Diagram &mdash; ${VIOS_HOSTNAME}</title>" >> "${OUTPUT_FILE}"

cat >> "${OUTPUT_FILE}" << 'HEOF'
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'IBM Plex Mono', 'Courier New', monospace; background: #0f1117; color: #e2e8f0; min-height: 100vh; padding: 24px 28px; }
  h1 { font-family: 'IBM Plex Sans', 'Segoe UI', sans-serif; font-size: 1.45rem; font-weight: 700; color: #f0f4ff; letter-spacing: 0.01em; margin-bottom: 4px; }
  .subtitle { font-size: 0.8rem; color: #8892a4; margin-bottom: 16px; }

  /* Top bar */
  .topbar { display: flex; align-items: flex-start; justify-content: space-between; flex-wrap: wrap; gap: 14px; margin-bottom: 26px; padding-bottom: 18px; border-bottom: 1px solid #22293a; }
  .info-pills { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 6px; }
  .pill { background: #161d2e; border: 1px solid #252e45; border-radius: 4px; padding: 3px 10px; font-size: 0.73rem; color: #7a87a3; }
  .pill span { color: #c0ccdf; font-weight: 600; }

  /* Buttons */
  .btn-group { display: flex; gap: 8px; padding-top: 4px; }
  .btn { padding: 6px 16px; border: 1px solid #2e3d5e; border-radius: 4px; font-size: 0.78rem; font-family: 'IBM Plex Sans','Segoe UI',sans-serif; font-weight: 600; cursor: pointer; letter-spacing: 0.04em; background: #131b30; color: #7eaaee; transition: background 0.13s, color 0.13s; }
  .btn:hover { background: #1a2b50; color: #b8d4ff; border-color: #4060a0; }

  /* Tabs */
  .tabs { display: flex; gap: 4px; margin-bottom: 20px; border-bottom: 1px solid #22293a; }
  .tab { padding: 7px 18px; font-size: 0.8rem; font-family: 'IBM Plex Sans','Segoe UI',sans-serif; font-weight: 600; cursor: pointer; border-radius: 4px 4px 0 0; color: #5a6880; border: 1px solid transparent; border-bottom: none; transition: background 0.13s, color 0.13s; }
  .tab:hover { background: #181f33; color: #9ab0d4; }
  .tab.active { background: #111826; color: #8ab4f8; border-color: #1e2840; border-bottom-color: #111826; position: relative; top: 1px; }
  .tab-content { display: none; }
  .tab-content.active { display: block; }

  /* Tree */
  .tree { padding: 4px 0; }
  .node { margin: 1px 0; }
  .node-header { display: flex; align-items: center; gap: 8px; padding: 7px 12px 7px 6px; border-radius: 5px; cursor: pointer; user-select: none; transition: background 0.12s; border: 1px solid transparent; }
  .node-header:hover { background: #181f33; border-color: #252d45; }
  .tri { width: 14px; height: 14px; display: flex; align-items: center; justify-content: center; flex-shrink: 0; font-size: 0.62rem; color: #5a6680; transition: transform 0.18s ease; }
  .node.open > .node-header .tri { transform: rotate(90deg); }

  /* Colour-coded tags */
  .tag { display: inline-block; padding: 1px 8px; border-radius: 3px; font-size: 0.67rem; font-weight: 700; letter-spacing: 0.07em; text-transform: uppercase; flex-shrink: 0; }
  .tag-vios   { background: #0e2050; color: #6faaff; border: 1px solid #1e4aaa; }
  .tag-vhost  { background: #3a1a00; color: #f5a030; border: 1px solid #7a4000; }
  .tag-vtd    { background: #082b1a; color: #3acc70; border: 1px solid #136630; }
  .tag-lv     { background: #1a0e40; color: #a78bfa; border: 1px solid #4030a0; }
  .tag-iso    { background: #002a3a; color: #38bdf8; border: 1px solid #006080; }
  .tag-none   { background: #2a2a2a; color: #888888; border: 1px solid #444444; }
  .tag-backing { background: #1a1000; color: #e0a030; border: 1px solid #5a3a00; }

  .node-label { font-size: 0.85rem; font-weight: 600; color: #ccd4ec; }
  .node-meta  { font-size: 0.73rem; color: #5a6680; }

  /* Status badges */
  .badge { display: inline-block; padding: 1px 7px; border-radius: 3px; font-size: 0.67rem; font-weight: 700; letter-spacing: 0.05em; }
  .badge-ok  { background: #082b1a; color: #3acc70; border: 1px solid #136630; }
  .badge-bad { background: #2e0606; color: #ee5555; border: 1px solid #6e1010; }

  /* Children */
  .node-children { display: none; margin-left: 28px; border-left: 1px dashed #1e2840; padding-left: 14px; padding-top: 2px; padding-bottom: 2px; }
  .node.open > .node-children { display: block; }

  /* Detail panel */
  .panel { margin: 4px 0 8px 0; background: #111826; border: 1px solid #1e2840; border-radius: 6px; padding: 10px 16px; font-size: 0.755rem; line-height: 1.95; }
  .panel table { width: 100%; border-collapse: collapse; }
  .panel td { padding: 1px 8px 1px 0; vertical-align: top; }
  .panel td.lbl { color: #5a6880; white-space: nowrap; min-width: 220px; }
  .panel td.val { color: #bac8e0; word-break: break-all; }
  .panel .sec { font-size: 0.68rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.09em; color: #3a70c8; padding: 7px 0 2px 0; border-top: 1px solid #1e2840; }
  .panel .sec:first-child { padding-top: 0; border-top: none; }
  .panel .sec td { padding-top: 6px; }

  /* PV Table */
  .pv-table { width: 100%; border-collapse: collapse; font-size: 0.775rem; }
  .pv-table th { text-align: left; padding: 7px 12px; background: #111826; border-bottom: 2px solid #1e2840; color: #3a70c8; font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.08em; white-space: nowrap; }
  .pv-table td { padding: 6px 12px; border-bottom: 1px solid #1a2136; color: #bac8e0; vertical-align: top; }
  .pv-table tr:hover td { background: #141e30; }
  .pv-table .vg-badge { display: inline-block; padding: 1px 7px; border-radius: 3px; font-size: 0.66rem; font-weight: 700; background: #1a0e40; color: #a78bfa; border: 1px solid #4030a0; }
  .pv-table .none-badge { display: inline-block; padding: 1px 7px; border-radius: 3px; font-size: 0.66rem; font-weight: 700; background: #1e1e1e; color: #666; border: 1px solid #333; }

  /* Summary strip */
  .summary { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 20px; }
  .scard { background: #111826; border: 1px solid #1e2840; border-radius: 5px; padding: 8px 16px; min-width: 120px; }
  .scard .sv { font-size: 1.35rem; font-weight: 700; color: #c0ccdf; line-height: 1.2; }
  .scard .sl { font-size: 0.68rem; color: #5a6880; text-transform: uppercase; letter-spacing: 0.07em; }

  /* Footer */
  footer { margin-top: 36px; padding-top: 12px; border-top: 1px solid #181f33; font-size: 0.67rem; color: #323c58; text-align: center; letter-spacing: 0.04em; }
</style>
</head>
<body>
HEOF

cat >> "${OUTPUT_FILE}" << TOPBAR_EOF
<div class="topbar">
  <div>
    <h1>vSCSI Tree Diagram</h1>
    <div class="subtitle">IBM Virtual I/O Server &mdash; Virtual SCSI (vSCSI) Configuration</div>
    <div class="info-pills">
      <div class="pill">VIOS Hostname: <span>${VIOS_HOSTNAME}</span></div>
      <div class="pill">AIX OS Level: <span>${VIOS_OSLEVEL}</span></div>
      <div class="pill">Generated: <span>${COLLECT_DATE}</span></div>
    </div>
  </div>
  <div class="btn-group">
    <button class="btn" id="btn-expand">&#9660;&nbsp; Expand All</button>
    <button class="btn" id="btn-collapse">&#9654;&nbsp; Collapse All</button>
  </div>
</div>

<div class="tabs">
  <div class="tab active" id="tab-tree" onclick="switchTab('tree')">&#9700; Tree View</div>
  <div class="tab" id="tab-pv" onclick="switchTab('pv')">&#9632; Physical Disks</div>
</div>

<div class="tab-content active" id="content-tree">
  <div id="summary-strip" class="summary"></div>
  <div class="tree" id="tree-root"></div>
</div>
<div class="tab-content" id="content-pv">
  <div id="pv-content"></div>
</div>

<footer>Made with IBM Bob &nbsp;&bull;&nbsp; vSCSI Tree HTML Diagram v1.1 &nbsp;&bull;&nbsp; ${VIOS_HOSTNAME}</footer>
TOPBAR_EOF

cat >> "${OUTPUT_FILE}" << 'JEOF'
<script>
var DATA = {
JEOF

echo "  hostname: '${VIOS_HOSTNAME}'," >> "${OUTPUT_FILE}"
echo "  oslevel:  '${VIOS_OSLEVEL}',"  >> "${OUTPUT_FILE}"
echo "  vhosts: [${VHOST_JS}],"        >> "${OUTPUT_FILE}"
echo "  pvs:    [${PV_JS}]"            >> "${OUTPUT_FILE}"

cat >> "${OUTPUT_FILE}" << 'JEOF'
};

/* ── Utilities ───────────────────────────────────────────────────────────── */
function esc(s) {
  return String(s===undefined||s===null?'':s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function badge(s) {
  var ok = (s==='Available'||s==='LOGGED_IN'||s==='active'||s==='opened/syncd');
  return '<span class="badge '+(ok?'badge-ok':'badge-bad')+'">'+esc(s)+'</span>';
}
function r(l,v)  { return '<tr><td class="lbl">'+esc(l)+'</td><td class="val">'+esc(v)+'</td></tr>'; }
function rh(l,v) { return '<tr><td class="lbl">'+esc(l)+'</td><td class="val">'+v+'</td></tr>'; }
function sec(t)  { return '<tr class="sec"><td colspan="2">'+esc(t)+'</td></tr>'; }

/* ── Toggle ─────────────────────────────────────────────────────────────── */
function tog(id) { var n=document.getElementById(id); if(n) n.classList.toggle('open'); }
function expandAll()  { document.querySelectorAll('.node').forEach(function(n){n.classList.add('open');}); }
function collapseAll(){ document.querySelectorAll('.node').forEach(function(n){n.classList.remove('open');}); }

/* ── Tab switcher ────────────────────────────────────────────────────────── */
function switchTab(name) {
  ['tree','pv'].forEach(function(t) {
    document.getElementById('tab-'+t).classList.toggle('active', t===name);
    document.getElementById('content-'+t).classList.toggle('active', t===name);
  });
}

/* ── Panel builders ──────────────────────────────────────────────────────── */
function vhostPanel(v) {
  return '<div class="panel"><table>'+
    sec('Virtual SCSI Server Adapter (SVSA)')+
    r('vhost Name (SVSA)',       v.svsa)+
    r('Physical Location (DRC)', v.physloc)+
    r('Client Partition ID',     v.clntid)+
    '</table></div>';
}

function vtdPanel(v) {
  return '<div class="panel"><table>'+
    sec('Virtual Target Device (VTD)')+
    r('VTD Name',  v.vtd)+
    rh('Status',   badge(v.vtd_status))+
    r('LUN',       v.lun)+
    r('Mirrored',  v.mirrored)+
    r('Physloc',   v.physloc2||'N/A')+
    '</table></div>';
}

function backingPanel(v) {
  var h = '<div class="panel"><table>';
  if (v.btype === 'lv') {
    h += sec('Backing Logical Volume')+
    r('LV Name',                    v.backing)+
    r('Volume Group',               v.lv_vg)+
    r('LV Identifier',              v.lv_id)+
    rh('LV State',                  badge(v.lv_state))+
    r('LV Type',                    v.lv_type)+
    r('PP Size',                    v.lv_ppsize)+
    r('Logical Partitions (LPs)',   v.lv_lps)+
    r('Physical Partitions (PPs)',  v.lv_pps)+
    r('Copies',                     v.lv_copies)+
    r('Size',                       v.lv_size_gb+' ('+v.lv_size_mb+' MB)')+
    sec('Volume Group — '+v.lv_vg)+
    rh('VG State',                  badge(v.vg_state))+
    r('PP Size',                    v.vg_ppsize)+
    r('Total PPs',                  v.vg_tpps)+
    r('Used PPs',                   v.vg_upps)+
    r('Free PPs',                   v.vg_fpps)+
    r('Physical Volumes',           v.vg_pvs)+
    r('Logical Volumes',            v.vg_lvs)+
    r('PV(s)',                      v.vg_pvlist);
  } else if (v.btype === 'iso') {
    h += sec('Backing Device — ISO / File')+
    r('File Path', v.backing);
  } else {
    h += sec('Backing Device')+
    r('Device', v.backing||'N/A');
  }
  h += '</table></div>';
  return h;
}

/* ── Summary strip ───────────────────────────────────────────────────────── */
function buildSummary() {
  var vhosts = {}, vtds = 0, lvBacked = 0, isoBacked = 0;
  DATA.vhosts.forEach(function(v) { vhosts[v.svsa]=1; vtds++; if(v.btype==='lv') lvBacked++; if(v.btype==='iso') isoBacked++; });
  var html = '';
  html += card(Object.keys(vhosts).length, 'vhost Adapters');
  html += card(vtds,     'VTDs');
  html += card(lvBacked, 'LV-Backed');
  html += card(isoBacked,'ISO-Backed');
  html += card(DATA.pvs.length, 'Physical Disks');
  document.getElementById('summary-strip').innerHTML = html;
}
function card(v,l){ return '<div class="scard"><div class="sv">'+v+'</div><div class="sl">'+l+'</div></div>'; }

/* ── Tree builder ────────────────────────────────────────────────────────── */
function buildTree() {
  var h = '';

  /* VIOS root — always open */
  h += '<div class="node open" id="n-vios">';
  h += '<div class="node-header" id="hdr-vios">';
  h += '<span class="tri">&#9654;</span><span class="tag tag-vios">VIOS</span>';
  h += '<span class="node-label">&nbsp;'+esc(DATA.hostname)+'</span>';
  h += '<span class="node-meta">&nbsp;&nbsp;IBM Virtual I/O Server &nbsp;&bull;&nbsp; AIX '+esc(DATA.oslevel)+'</span>';
  h += '</div><div class="node-children">';

  /* Group VTDs by vhost */
  var vhostMap = {};
  var vhostOrder = [];
  DATA.vhosts.forEach(function(v) {
    if (!vhostMap[v.svsa]) { vhostMap[v.svsa] = []; vhostOrder.push(v.svsa); }
    vhostMap[v.svsa].push(v);
  });

  vhostOrder.forEach(function(svsa, vi) {
    var vtds = vhostMap[svsa];
    var first = vtds[0];
    var hid = 'n-vh-'+vi;

    /* vhost node */
    h += '<div class="node" id="'+hid+'">';
    h += '<div class="node-header" id="hdr-vh-'+vi+'">';
    h += '<span class="tri">&#9654;</span><span class="tag tag-vhost">vhost</span>';
    h += '<span class="node-label">&nbsp;'+esc(svsa)+'</span>';
    h += '<span class="node-meta">&nbsp;&nbsp;Client ID: '+esc(first.clntid)+'&nbsp;&nbsp;&bull;&nbsp;&nbsp;'+esc(first.physloc)+'</span>';
    h += '</div><div class="node-children">';
    h += vhostPanel(first);

    /* VTD nodes under this vhost */
    vtds.forEach(function(v, ti) {
      var tid  = 'n-vtd-'+vi+'-'+ti;
      var bid  = 'n-bk-'+vi+'-'+ti;
      var btagClass = v.btype === 'iso' ? 'tag-iso' : (v.btype === 'lv' ? 'tag-lv' : 'tag-none');
      var btagLabel = v.btype === 'iso' ? 'ISO' : (v.btype === 'lv' ? 'LV' : 'None');
      var sizeHint  = v.btype === 'lv'  ? '&nbsp;&nbsp;'+esc(v.lv_size_gb)
                    : v.btype === 'iso' ? '&nbsp;&nbsp;ISO Image' : '';
      /* short backing label shown on the VTD header row */
      var backingShort = v.btype === 'iso'
        ? esc(v.backing).replace(/.*\//,'')   /* filename only */
        : esc(v.backing);

      /* ── VTD node ── */
      h += '<div class="node" id="'+tid+'">';
      h += '<div class="node-header" id="hdr-vtd-'+vi+'-'+ti+'">';
      h += '<span class="tri">&#9654;</span><span class="tag tag-vtd">VTD</span>';
      h += '<span class="node-label">&nbsp;'+esc(v.vtd)+'</span>';
      h += '<span class="node-meta">&nbsp;&nbsp;LUN: '+esc(v.lun)+'</span>';
      h += '&nbsp;&nbsp;'+badge(v.vtd_status);
      h += '</div><div class="node-children">';
      h += vtdPanel(v);

      /* ── Backing Device child node ── */
      h += '<div class="node" id="'+bid+'">';
      h += '<div class="node-header" id="hdr-bk-'+vi+'-'+ti+'">';
      h += '<span class="tri">&#9654;</span><span class="tag tag-backing">Backing</span>';
      h += '<span class="node-label">&nbsp;'+backingShort+'</span>';
      h += '<span class="node-meta">&nbsp;&nbsp;<span class="tag '+btagClass+'">'+btagLabel+'</span>'+sizeHint+'</span>';
      h += '</div><div class="node-children">';
      h += backingPanel(v);
      h += '</div></div>'; /* close backing node */

      h += '</div></div>'; /* close VTD children + VTD node */
    });

    h += '</div></div>'; /* close vhost children + vhost node */
  });

  h += '</div></div>'; /* close VIOS children + VIOS node */
  document.getElementById('tree-root').innerHTML = h;

  /* Attach toggle listeners */
  document.querySelectorAll('.node-header').forEach(function(hdr){
    hdr.addEventListener('click', function(){ this.parentElement.classList.toggle('open'); });
  });
}

/* ── PV Table builder ────────────────────────────────────────────────────── */
function buildPVTable() {
  var h = '<table class="pv-table"><thead><tr>';
  h += '<th>Device</th><th>PVID</th><th>Volume Group</th><th>Size</th><th>Unique ID</th>';
  h += '</tr></thead><tbody>';
  DATA.pvs.forEach(function(p) {
    var vgCell = (p.vg && p.vg !== 'None')
      ? '<span class="vg-badge">'+esc(p.vg)+'</span>'
      : '<span class="none-badge">None</span>';
    h += '<tr>';
    h += '<td><strong>'+esc(p.name)+'</strong></td>';
    h += '<td>'+esc(p.pvid)+'</td>';
    h += '<td>'+vgCell+'</td>';
    h += '<td>'+esc(p.size_gb)+' ('+esc(p.size_mb)+' MB)</td>';
    h += '<td>'+esc(p.uid)+'</td>';
    h += '</tr>';
  });
  h += '</tbody></table>';
  document.getElementById('pv-content').innerHTML = h;
}

/* ── Initialise ──────────────────────────────────────────────────────────── */
document.getElementById('btn-expand').addEventListener('click', expandAll);
document.getElementById('btn-collapse').addEventListener('click', collapseAll);
buildSummary();
buildTree();
buildPVTable();
</script>
</body>
</html>
JEOF

}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    case "$1" in
        -h|--help)
            cat << EOF
Usage: $0 [--help]

Generates a self-contained interactive HTML vSCSI tree diagram for VIOS.

Output: ${OUTPUT_DIR}/vscsi_tree_YYYYMMDD_HHMMSS.html

Tree layout:
  [VIOS]  (blue)
  └── [vhost]  vhost0...N  (amber)
      │   SVSA name, DRC, Client Partition ID
      └── [VTD]  vtscsiN / ISO name  (green / blue / grey)
              VTD name, Status, LUN
              Backing: LV name, VG, LV state, PP size, size
                       VG: state, PPs total/used/free, PVs
              Or: ISO file path

Tabs:
  Tree View     — interactive expand/collapse tree
  Physical Disks — table of all hdisks with PVID, VG, size

Requires: Root access; VIOS vSCSI configuration; lsmap, lslv, lsvg, lspv
EOF
            exit 0 ;;
        *)
            check_root
            echo "Collecting vSCSI data from ${VIOS_HOSTNAME:-$(hostname)}..."
            collect_data
            echo "Generating interactive HTML diagram..."
            generate_html
            echo ""
            echo "======================================================="
            echo "  vSCSI HTML Diagram created:"
            echo "  ${OUTPUT_FILE}"
            echo "======================================================="
            echo "  Transfer with:"
            echo "    scp root@$(hostname):${OUTPUT_FILE} ."
            echo "======================================================="
            ;;
    esac
}

main "$@"

# Made with IBM Bob

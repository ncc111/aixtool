#!/bin/ksh
#
# npiv_tree_html_diagram.sh - Interactive HTML NPIV Tree Diagram
# Description: Generates a fully self-contained interactive HTML file showing
#              NPIV (N_Port ID Virtualization) configuration tree on IBM VIOS.
#              Layout (VIOS view):  VIOS -> Physical FC Adapter -> vfchost -> LPAR
#              Layout (LPAR view):  LPAR -> Virtual FC Adapter  -> vfchost -> Physical FC Port
# Author: Bob
# Version: 3.0
#

OUTPUT_DIR="/home/padmin"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/npiv_tree_${TIMESTAMP}.html"
TMP_PREFIX="/tmp/npiv_html_$$"

# ── Helpers ──────────────────────────────────────────────────────────────────
cleanup() { rm -f "${TMP_PREFIX}"_*.tmp 2>/dev/null; }
trap cleanup EXIT

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Must run as root" >&2
        exit 1
    fi
}

# ── Data collection ──────────────────────────────────────────────────────────
collect_data() {
    VIOS_HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
    VIOS_OSLEVEL=$( /usr/ios/cli/ioscli ioslevel 2>/dev/null || echo "N/A")
    COLLECT_DATE=$(date)

    # ── Physical FC adapters via lsnports ─────────────────────────────────────
    # Columns: name physloc fabric tports aports swwpns awwpns
    /usr/ios/cli/ioscli lsnports -fmt : -field name physloc fabric tports aports swwpns awwpns \
        2>/dev/null > "${TMP_PREFIX}_phys.tmp"

    # ── Physical FC adapter details via fcstat ────────────────────────────────
    # Extract: WWNN, WWPN, Port FC ID, Port Speed (running), Port Speed (supported)
    > "${TMP_PREFIX}_fcstat.tmp"
    while IFS=: read -r fcname rest; do
        [ -z "$fcname" ] && continue
        fcstat "$fcname" 2>/dev/null | awk -v fc="$fcname" '
            BEGIN { wwnn="N/A"; wwpn="N/A"; speed_run="N/A"; speed_sup="N/A"; fcid="N/A" }
            /World Wide Node Name:/ { wwnn=$NF }
            /World Wide Port Name:/ { wwpn=$NF }
            /Port Speed .supported.:/ { speed_sup=$(NF-1)" "$NF }
            /Port Speed .running.:/ { speed_run=$(NF-1)" "$NF }
            /Port FC ID:/ { fcid=$NF }
            END { print fc"|"wwnn"|"wwpn"|"speed_run"|"speed_sup"|"fcid }
        ' >> "${TMP_PREFIX}_fcstat.tmp"
    done < "${TMP_PREFIX}_phys.tmp"

    # ── NPIV mappings via lsmap -all -npiv (colon-delimited) ─────────────────
    # Fields: name:physloc:clntid:clntname:clntos:status:fcname:fcloc:ports:flags:vfc_client:vfc_client_drc
    /usr/ios/cli/ioscli lsmap -all -npiv -fmt : \
        2>/dev/null > "${TMP_PREFIX}_lsmap.tmp"
}

# ── HTML generation ───────────────────────────────────────────────────────────
generate_html() {

# ── Build JavaScript data arrays from collected data ─────────────────────────
PHYS_JS=""
while IFS=: read -r fname fphysloc ffabric ftports faports fswwpns fawwpns; do
    [ -z "$fname" ] && continue

    # Retrieve fcstat details for this physical adapter
    FCSTAT_LINE=$(grep "^${fname}|" "${TMP_PREFIX}_fcstat.tmp" 2>/dev/null | head -1)
    f_wwnn=$(echo "$FCSTAT_LINE" | cut -d'|' -f2)
    f_wwpn=$(echo "$FCSTAT_LINE" | cut -d'|' -f3)
    f_spd_run=$(echo "$FCSTAT_LINE" | cut -d'|' -f4)
    f_spd_sup=$(echo "$FCSTAT_LINE" | cut -d'|' -f5)
    f_fcid=$(echo "$FCSTAT_LINE" | cut -d'|' -f6)
    [ -z "$f_wwnn" ]    && f_wwnn="N/A"
    [ -z "$f_wwpn" ]    && f_wwpn="N/A"
    [ -z "$f_spd_run" ] && f_spd_run="N/A"
    [ -z "$f_spd_sup" ] && f_spd_sup="N/A"
    [ -z "$f_fcid" ]    && f_fcid="N/A"

    # ── Collect vfchost entries mapped to this physical FC adapter ────────────
    VFCHOST_JS=""
    while IFS=: read -r vname vphysloc vclntid vclntname vclntos vstatus \
                         vfcname vfcloc vports vflags vvfcclient vvfcdrc; do
        [ "$vfcname" = "$fname" ] || continue

        # Virtual WWPN: check lsattr for alt_site_wwpn or current_wwpn
        # These are only populated post-LPM migration; normally blank on VIOS
        vwwpn=$(lsattr -El "$vname" 2>/dev/null | awk '
            $1 == "alt_site_wwpn" && $2 ~ /^0x/ { print $2; exit }
            $1 == "current_wwpn"  && $2 ~ /^0x/ { print $2; exit }
        ')
        [ -z "$vwwpn" ] && vwwpn="N/A (defined in HMC LPAR profile)"

        # Parse client virtual slot from VFC client DRC:
        # DRC format: U<sys_type>-V<lpar_id>-C<slot>  e.g. U9009.42A.782D930-V106-C4
        vslot=$(echo "$vvfcdrc" | sed 's/.*-C//')
        [ -z "$vslot" ] && vslot="N/A"

        VFCHOST_JS="${VFCHOST_JS}
            {
              name: '${vname}',
              physloc: '${vphysloc}',
              clntid: '${vclntid}',
              clntname: '${vclntname}',
              clntos: '${vclntos}',
              status: '${vstatus}',
              ports: '${vports}',
              vfc_client: '${vvfcclient}',
              vfc_client_drc: '${vvfcdrc}',
              vfc_client_slot: '${vslot}',
              phys_fc: '${vfcname}',
              phys_fc_loc: '${vfcloc}',
              phys_wwpn: '${f_wwpn}',
              virt_wwpn: '${vwwpn}'
            },"
    done < "${TMP_PREFIX}_lsmap.tmp"

    PHYS_JS="${PHYS_JS}
        {
          name: '${fname}',
          physloc: '${fphysloc}',
          fabric: '${ffabric}',
          tports: '${ftports}',
          aports: '${faports}',
          swwpns: '${fswwpns}',
          awwpns: '${fawwpns}',
          wwnn: '${f_wwnn}',
          wwpn: '${f_wwpn}',
          speed_run: '${f_spd_run}',
          speed_sup: '${f_spd_sup}',
          fcid: '${f_fcid}',
          vfchosts: [${VFCHOST_JS}]
        },"
done < "${TMP_PREFIX}_phys.tmp"

# ── Write HTML ────────────────────────────────────────────────────────────────
cat > "${OUTPUT_FILE}" << 'STYLE_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
STYLE_EOF

echo "<title>NPIV Tree Diagram — ${VIOS_HOSTNAME}</title>" >> "${OUTPUT_FILE}"

cat >> "${OUTPUT_FILE}" << 'STYLE_EOF'
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'IBM Plex Mono', 'Courier New', monospace; background: #0f1117; color: #e2e8f0; min-height: 100vh; padding: 24px 28px; }
  h1 { font-family: 'IBM Plex Sans', 'Segoe UI', sans-serif; font-size: 1.45rem; font-weight: 700; color: #f0f4ff; letter-spacing: 0.01em; margin-bottom: 4px; }
  .subtitle { font-size: 0.8rem; color: #8892a4; margin-bottom: 16px; }

  /* Top bar */
  .topbar { display: flex; align-items: flex-start; justify-content: space-between; flex-wrap: wrap; gap: 14px; margin-bottom: 20px; padding-bottom: 18px; border-bottom: 1px solid #22293a; }
  .info-pills { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 6px; }
  .pill { background: #161d2e; border: 1px solid #252e45; border-radius: 4px; padding: 3px 10px; font-size: 0.73rem; color: #7a87a3; }
  .pill span { color: #c0ccdf; font-weight: 600; }

  /* View toggle tabs */
  .view-tabs { display: flex; gap: 0; margin-bottom: 20px; border-bottom: 2px solid #1e2840; }
  .view-tab { padding: 8px 22px; font-family: 'IBM Plex Sans', 'Segoe UI', sans-serif; font-size: 0.8rem; font-weight: 600; color: #5a6880; cursor: pointer; border: 1px solid transparent; border-bottom: none; border-radius: 4px 4px 0 0; margin-bottom: -2px; transition: background 0.12s, color 0.12s; letter-spacing: 0.03em; }
  .view-tab:hover { background: #161d2e; color: #9aafcc; }
  .view-tab.active { background: #131b30; border-color: #1e2840; color: #7eaaee; border-bottom-color: #131b30; }

  /* Expand/Collapse buttons */
  .btn-group { display: flex; gap: 8px; padding-top: 4px; }
  .btn { padding: 6px 16px; border: 1px solid #2e3d5e; border-radius: 4px; font-size: 0.78rem; font-family: 'IBM Plex Sans', 'Segoe UI', sans-serif; font-weight: 600; cursor: pointer; letter-spacing: 0.04em; background: #131b30; color: #7eaaee; transition: background 0.13s, color 0.13s; }
  .btn:hover { background: #1a2b50; color: #b8d4ff; border-color: #4060a0; }

  /* Tree wrapper */
  .tree { padding: 4px 0; }
  .tree-view { display: none; }
  .tree-view.active { display: block; }

  /* Generic node */
  .node { margin: 1px 0; }
  .node-header { display: flex; align-items: center; gap: 8px; padding: 7px 12px 7px 6px; border-radius: 5px; cursor: pointer; user-select: none; transition: background 0.12s; border: 1px solid transparent; }
  .node-header:hover { background: #181f33; border-color: #252d45; }

  /* Triangle indicator: ▶ default, rotates to ▼ when open */
  .tri { width: 14px; height: 14px; display: flex; align-items: center; justify-content: center; flex-shrink: 0; font-size: 0.62rem; color: #5a6680; transition: transform 0.18s ease; }
  .node.open > .node-header .tri { transform: rotate(90deg); }

  /* Colour-coded tags */
  .tag { display: inline-block; padding: 1px 8px; border-radius: 3px; font-size: 0.67rem; font-weight: 700; letter-spacing: 0.07em; text-transform: uppercase; flex-shrink: 0; }
  .tag-vios    { background: #0e2050; color: #6faaff; border: 1px solid #1e4aaa; }
  .tag-fc      { background: #3a2200; color: #f0a020; border: 1px solid #7a4800; }
  .tag-vfchost { background: #082b1a; color: #3acc70; border: 1px solid #136630; }
  .tag-lpar    { background: #2a0e40; color: #c480ff; border: 1px solid #6030a0; }
  .tag-vfc     { background: #0d2535; color: #40c4ff; border: 1px solid #0a5070; }

  .node-label { font-size: 0.85rem; font-weight: 600; color: #ccd4ec; }
  .node-meta  { font-size: 0.73rem; color: #5a6680; }

  /* Status badges */
  .badge { display: inline-block; padding: 1px 7px; border-radius: 3px; font-size: 0.67rem; font-weight: 700; letter-spacing: 0.05em; }
  .badge-ok  { background: #082b1a; color: #3acc70; border: 1px solid #136630; }
  .badge-bad { background: #2e0606; color: #ee5555; border: 1px solid #6e1010; }

  /* Children container — indent with dashed guide line */
  .node-children { display: none; margin-left: 28px; border-left: 1px dashed #1e2840; padding-left: 14px; padding-top: 2px; padding-bottom: 2px; }
  .node.open > .node-children { display: block; }

  /* Detail panel (table of fields) */
  .panel { margin: 4px 0 8px 0; background: #111826; border: 1px solid #1e2840; border-radius: 6px; padding: 10px 16px; font-size: 0.755rem; line-height: 1.95; }
  .panel table { width: 100%; border-collapse: collapse; }
  .panel td { padding: 1px 8px 1px 0; vertical-align: top; }
  .panel td.lbl { color: #5a6880; white-space: nowrap; min-width: 220px; }
  .panel td.val { color: #bac8e0; word-break: break-all; }
  .panel .sec { font-size: 0.68rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.09em; color: #3a70c8; padding: 7px 0 2px 0; border-top: 1px solid #1e2840; }
  .panel .sec:first-child { padding-top: 0; border-top: none; }
  .panel .sec td { padding-top: 6px; }

  /* Footer */
  footer { margin-top: 36px; padding-top: 12px; border-top: 1px solid #181f33; font-size: 0.67rem; color: #323c58; text-align: center; letter-spacing: 0.04em; }
</style>
</head>
<body>
STYLE_EOF

# Topbar with live data
cat >> "${OUTPUT_FILE}" << TOPBAR_EOF
<div class="topbar">
  <div>
    <h1>NPIV Tree Diagram</h1>
    <div class="subtitle">IBM Virtual I/O Server &mdash; NPIV Configuration</div>
    <div class="info-pills">
      <div class="pill">VIOS Hostname: <span>${VIOS_HOSTNAME}</span></div>
      <div class="pill">VIOS OS Level: <span>${VIOS_OSLEVEL}</span></div>
      <div class="pill">Generated: <span>${COLLECT_DATE}</span></div>
    </div>
  </div>
  <div class="btn-group">
    <button class="btn" onclick="expandAll()">&#9660;&nbsp; Expand All</button>
    <button class="btn" onclick="collapseAll()">&#9654;&nbsp; Collapse All</button>
  </div>
</div>

<!-- View tabs -->
<div class="view-tabs">
  <div class="view-tab active" onclick="switchView('vios')">&#128200;&nbsp; VIOS View</div>
  <div class="view-tab"       onclick="switchView('lpar')">&#128202;&nbsp; LPAR View</div>
</div>

<div id="view-vios" class="tree-view active" id="tree-vios"></div>
<div id="view-lpar" class="tree-view"        id="tree-lpar"></div>

<footer>Made with IBM Bob &nbsp;&bull;&nbsp; NPIV Tree HTML Diagram v3.0 &nbsp;&bull;&nbsp; ${VIOS_HOSTNAME}</footer>
TOPBAR_EOF

# JavaScript data block + rendering logic
cat >> "${OUTPUT_FILE}" << 'JS_OPEN_EOF'
<script>
var DATA = {
JS_OPEN_EOF

echo "  hostname: '${VIOS_HOSTNAME}'," >> "${OUTPUT_FILE}"
echo "  oslevel:  '${VIOS_OSLEVEL}',"  >> "${OUTPUT_FILE}"
echo "  adapters: [${PHYS_JS}]"        >> "${OUTPUT_FILE}"

cat >> "${OUTPUT_FILE}" << 'JS_LOGIC_EOF'
};

/* ── Utilities ──────────────────────────────────────────────────────────── */
function esc(s) {
  return String(s === undefined || s === null ? '' : s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}

function badge(s) {
  var ok = (s === 'LOGGED_IN' || s === 'CONNECTED');
  return '<span class="badge ' + (ok ? 'badge-ok' : 'badge-bad') + '">' + esc(s) + '</span>';
}

function r(label, val) {
  return '<tr><td class="lbl">' + esc(label) + '</td><td class="val">' + esc(val) + '</td></tr>';
}

function rh(label, html) {
  return '<tr><td class="lbl">' + esc(label) + '</td><td class="val">' + html + '</td></tr>';
}

function sec(title) {
  return '<tr class="sec"><td colspan="2">' + esc(title) + '</td></tr>';
}

/* ── Toggle ─────────────────────────────────────────────────────────────── */
function tog(id) {
  var n = document.getElementById(id);
  if (n) n.classList.toggle('open');
}

function expandAll() {
  var root = document.querySelector('.tree-view.active');
  var ns = root ? root.querySelectorAll('.node') : [];
  for (var i = 0; i < ns.length; i++) ns[i].classList.add('open');
}

function collapseAll() {
  var root = document.querySelector('.tree-view.active');
  var ns = root ? root.querySelectorAll('.node') : [];
  for (var i = 0; i < ns.length; i++) ns[i].classList.remove('open');
}

/* ── View switching ─────────────────────────────────────────────────────── */
function switchView(name) {
  var views = document.querySelectorAll('.tree-view');
  var tabs  = document.querySelectorAll('.view-tab');
  for (var i = 0; i < views.length; i++) views[i].classList.remove('active');
  for (var i = 0; i < tabs.length;  i++) tabs[i].classList.remove('active');
  document.getElementById('view-' + name).classList.add('active');
  var idx = (name === 'vios') ? 0 : 1;
  tabs[idx].classList.add('active');
}

/* ── Panel builders ─────────────────────────────────────────────────────── */
function fcPanel(a) {
  return '<div class="panel"><table>' +
    sec('Physical FC Adapter — Identity') +
    r('Adapter Name',                a.name) +
    r('FC Location Code',            a.physloc) +
    r('World Wide Node Name (WWNN)', a.wwnn) +
    r('World Wide Port Name (WWPN)', a.wwpn) +
    r('Port FC ID',                  a.fcid) +
    sec('Port Speed') +
    r('Port Speed (running)',        a.speed_run) +
    r('Port Speed (supported)',      a.speed_sup) +
    sec('Fabric / Capacity') +
    r('Fabric',                      a.fabric) +
    r('Total Ports',                 a.tports) +
    r('Available Ports',             a.aports) +
    r('Switch WWPNs (total)',        a.swwpns) +
    r('Switch WWPNs (available)',    a.awwpns) +
    '</table></div>';
}

function vfcPanel(v) {
  return '<div class="panel"><table>' +
    sec('Virtual FC Host — Identity') +
    r('vfchost Name',                      v.name) +
    r('DRC / Physical Location',           v.physloc) +
    sec('Backing Physical FC Port') +
    r('Physical FC Adapter',               v.phys_fc) +
    r('Physical FC Location Code',         v.phys_fc_loc) +
    r('Physical WWPN (backing fcs port)',  v.phys_wwpn) +
    sec('Connection Status') +
    rh('Status',                           badge(v.status)) +
    r('Ports Logged In',                   v.ports) +
    '</table></div>';
}

function lparPanel(v) {
  return '<div class="panel"><table>' +
    sec('Client LPAR — Identity') +
    r('LPAR ID',                           v.clntid) +
    r('LPAR Name',                         v.clntname) +
    r('Operating System',                  v.clntos) +
    sec('Client Virtual FC Adapter') +
    r('Virtual FC Adapter Name',           v.vfc_client) +
    r('Virtual Slot Number',               v.vfc_client_slot) +
    r('VFC Client DRC Location Code',      v.vfc_client_drc) +
    r('Virtual WWPN',                      v.virt_wwpn) +
    sec('VIOS Mapping') +
    r('VIOS vfchost',                      v.name) +
    r('VIOS vfchost DRC',                  v.physloc) +
    rh('Link Status',                      badge(v.status)) +
    r('FC Ports Logged In',                v.ports) +
    sec('Physical FC Path (VIOS → SAN)') +
    r('Physical FC Adapter',               v.phys_fc) +
    r('Physical FC Location Code',         v.phys_fc_loc) +
    r('Physical WWPN (SAN-facing port)',   v.phys_wwpn) +
    '</table></div>';
}

function vfcLparPanel(v) {
  return '<div class="panel"><table>' +
    sec('Virtual FC Adapter — LPAR Side') +
    r('Virtual FC Adapter Name',           v.vfc_client) +
    r('Virtual Slot Number',               v.vfc_client_slot) +
    r('VFC Client DRC Location Code',      v.vfc_client_drc) +
    r('Virtual WWPN',                      v.virt_wwpn) +
    sec('VIOS Mapping') +
    r('VIOS vfchost',                      v.name) +
    r('VIOS vfchost DRC',                  v.physloc) +
    rh('Link Status',                      badge(v.status)) +
    r('FC Ports Logged In',                v.ports) +
    sec('Physical FC Path (VIOS → SAN)') +
    r('Physical FC Adapter',               v.phys_fc) +
    r('Physical FC Location Code',         v.phys_fc_loc) +
    r('Physical WWPN (SAN-facing port)',   v.phys_wwpn) +
    '</table></div>';
}

/* ── VIOS View builder ──────────────────────────────────────────────────── */
/* Tree: VIOS → Physical FC Adapter → vfchost → LPAR                        */
function buildViosView() {
  var h = '';

  /* VIOS root */
  h += '<div class="node open" id="v-vios">';
  h += '<div class="node-header" onclick="tog(\'v-vios\')">';
  h += '<span class="tri">&#9654;</span>';
  h += '<span class="tag tag-vios">VIOS</span>';
  h += '<span class="node-label">' + esc(DATA.hostname) + '</span>';
  h += '<span class="node-meta">&nbsp;&nbsp;IBM Virtual I/O Server &nbsp;&bull;&nbsp; AIX ' + esc(DATA.oslevel) + '</span>';
  h += '</div><div class="node-children">';

  for (var ai = 0; ai < DATA.adapters.length; ai++) {
    var a = DATA.adapters[ai];
    var fid = 'v-fc-' + ai;

    /* Physical FC adapter */
    h += '<div class="node" id="' + fid + '">';
    h += '<div class="node-header" onclick="tog(\'' + fid + '\')">';
    h += '<span class="tri">&#9654;</span>';
    h += '<span class="tag tag-fc">FC Adapter</span>';
    h += '<span class="node-label">' + esc(a.name) + '</span>';
    h += '<span class="node-meta">&nbsp;&nbsp;' + esc(a.physloc) + '&nbsp;&nbsp;WWPN: ' + esc(a.wwpn) + '</span>';
    h += '</div><div class="node-children">';
    h += fcPanel(a);

    /* vfchost nodes under this FC adapter */
    for (var vi = 0; vi < a.vfchosts.length; vi++) {
      var v   = a.vfchosts[vi];
      var vid = 'v-vfc-' + ai + '-' + vi;

      h += '<div class="node" id="' + vid + '">';
      h += '<div class="node-header" onclick="tog(\'' + vid + '\')">';
      h += '<span class="tri">&#9654;</span>';
      h += '<span class="tag tag-vfchost">vfchost</span>';
      h += '<span class="node-label">' + esc(v.name) + '</span>';
      h += '<span class="node-meta">&nbsp;&nbsp;' + esc(v.physloc) + '</span>';
      h += '&nbsp;&nbsp;' + badge(v.status);
      h += '</div><div class="node-children">';
      h += vfcPanel(v);

      /* LPAR leaf node */
      var lid = 'v-lpar-' + ai + '-' + vi;
      h += '<div class="node" id="' + lid + '">';
      h += '<div class="node-header" onclick="tog(\'' + lid + '\')">';
      h += '<span class="tri">&#9654;</span>';
      h += '<span class="tag tag-lpar">LPAR</span>';
      h += '<span class="node-label">' + esc(v.clntname) + '</span>';
      h += '<span class="node-meta">&nbsp;&nbsp;ID: ' + esc(v.clntid) +
           ' &nbsp;&bull;&nbsp; OS: ' + esc(v.clntos) +
           ' &nbsp;&bull;&nbsp; vfc: ' + esc(v.vfc_client) +
           ' (slot ' + esc(v.vfc_client_slot) + ')</span>';
      h += '</div><div class="node-children">';
      h += lparPanel(v);
      h += '</div></div>'; /* close LPAR */

      h += '</div></div>'; /* close vfchost children + node */
    }

    h += '</div></div>'; /* close FC children + FC node */
  }

  h += '</div></div>'; /* close VIOS children + VIOS node */
  document.getElementById('view-vios').innerHTML = h;
}

/* ── LPAR View builder ──────────────────────────────────────────────────── */
/* Tree: LPAR → Virtual FC Adapter → vfchost (VIOS) → Physical FC Port      */
function buildLparView() {
  /* Collect all vfchost entries grouped by LPAR ID */
  var lpars = {}; /* key: clntid, val: { id, name, os, vfcs: [] } */

  for (var ai = 0; ai < DATA.adapters.length; ai++) {
    var a = DATA.adapters[ai];
    for (var vi = 0; vi < a.vfchosts.length; vi++) {
      var v = a.vfchosts[vi];
      var key = v.clntid + '|' + v.clntname;
      if (!lpars[key]) {
        lpars[key] = { id: v.clntid, name: v.clntname, os: v.clntos, vfcs: [] };
      }
      lpars[key].vfcs.push(v);
    }
  }

  var h = '';
  var lkeys = Object.keys(lpars).sort(function(a,b){
    return parseInt(lpars[a].id||0) - parseInt(lpars[b].id||0);
  });

  for (var li = 0; li < lkeys.length; li++) {
    var lp  = lpars[lkeys[li]];
    var lpid = 'l-lpar-' + li;

    /* LPAR root */
    h += '<div class="node open" id="' + lpid + '">';
    h += '<div class="node-header" onclick="tog(\'' + lpid + '\')">';
    h += '<span class="tri">&#9654;</span>';
    h += '<span class="tag tag-lpar">LPAR</span>';
    h += '<span class="node-label">' + esc(lp.name) + '</span>';
    h += '<span class="node-meta">&nbsp;&nbsp;ID: ' + esc(lp.id) + ' &nbsp;&bull;&nbsp; OS: ' + esc(lp.os) + '</span>';
    h += '</div><div class="node-children">';

    for (var vj = 0; vj < lp.vfcs.length; vj++) {
      var v   = lp.vfcs[vj];
      var vfid = 'l-vfc-' + li + '-' + vj;

      /* Virtual FC adapter */
      h += '<div class="node" id="' + vfid + '">';
      h += '<div class="node-header" onclick="tog(\'' + vfid + '\')">';
      h += '<span class="tri">&#9654;</span>';
      h += '<span class="tag tag-vfc">Virtual FC</span>';
      h += '<span class="node-label">' + esc(v.vfc_client) + '</span>';
      h += '<span class="node-meta">&nbsp;&nbsp;slot ' + esc(v.vfc_client_slot) +
           ' &nbsp;&bull;&nbsp; DRC: ' + esc(v.vfc_client_drc) + '</span>';
      h += '</div><div class="node-children">';
      h += vfcLparPanel(v);

      /* vfchost (VIOS) */
      var vhid = 'l-vfch-' + li + '-' + vj;
      h += '<div class="node" id="' + vhid + '">';
      h += '<div class="node-header" onclick="tog(\'' + vhid + '\')">';
      h += '<span class="tri">&#9654;</span>';
      h += '<span class="tag tag-vfchost">vfchost</span>';
      h += '<span class="node-label">' + esc(v.name) + '</span>';
      h += '<span class="node-meta">&nbsp;&nbsp;VIOS: ' + esc(DATA.hostname) +
           ' &nbsp;&bull;&nbsp; ' + esc(v.physloc) + '</span>';
      h += '&nbsp;&nbsp;' + badge(v.status);
      h += '</div><div class="node-children">';
      h += vfcPanel(v);

      /* Physical FC Adapter leaf */
      var pfid = 'l-fc-' + li + '-' + vj;
      h += '<div class="node" id="' + pfid + '">';
      h += '<div class="node-header" onclick="tog(\'' + pfid + '\')">';
      h += '<span class="tri">&#9654;</span>';
      h += '<span class="tag tag-fc">FC Adapter</span>';
      h += '<span class="node-label">' + esc(v.phys_fc) + '</span>';
      h += '<span class="node-meta">&nbsp;&nbsp;' + esc(v.phys_fc_loc) +
           ' &nbsp;&bull;&nbsp; WWPN: ' + esc(v.phys_wwpn) + '</span>';
      h += '</div><div class="node-children">';
      /* FC detail panel — find full adapter record */
      for (var ak = 0; ak < DATA.adapters.length; ak++) {
        if (DATA.adapters[ak].name === v.phys_fc) {
          h += fcPanel(DATA.adapters[ak]);
          break;
        }
      }
      h += '</div></div>'; /* close FC leaf */

      h += '</div></div>'; /* close vfchost children + node */
      h += '</div></div>'; /* close Virtual FC children + node */
    }

    h += '</div></div>'; /* close LPAR children + node */
  }

  document.getElementById('view-lpar').innerHTML = h;
}

buildViosView();
buildLparView();
</script>
</body>
</html>
JS_LOGIC_EOF

}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    case "$1" in
        -h|--help)
            cat << EOF
Usage: $0 [--help]

Generates a self-contained interactive HTML NPIV tree diagram for VIOS.

Output: ${OUTPUT_DIR}/npiv_tree_YYYYMMDD_HHMMSS.html

VIOS View tree layout:
  [VIOS]       vios_usb  (blue)
  └── [FC Adapter]  fcs0 / fcs1  (amber) — WWNN, WWPN, Speed, Fabric info
      └── [vfchost]  vfchostN  (green)  — backing port, status, ports
          └── [LPAR]  <client name>  (purple) — LPAR ID, OS, virtual fc adapter,
                slot, DRC, virtual WWPN, full physical FC path

LPAR View tree layout:
  [LPAR]       <client name>  (purple)
  └── [Virtual FC]  fcsN (client adapter)  (cyan) — slot, DRC, virtual WWPN
      └── [vfchost]  vfchostN (VIOS)  (green) — status, ports logged in
          └── [FC Adapter]  fcsN (VIOS physical)  (amber) — WWPN, speed, fabric

Requires: Root access; VIOS NPIV configuration; fcstat, lsnports, lsmap
EOF
            exit 0 ;;
        *)
            check_root
            echo "Collecting NPIV data from ${VIOS_HOSTNAME:-$(hostname)}..."
            collect_data
            echo "Generating interactive HTML diagram..."
            generate_html
            echo ""
            echo "======================================================="
            echo "  NPIV HTML Diagram created:"
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

#!/bin/bash
# ============================================================
# vnic_tree_html_diagram.sh  v2.0
# IBM HMC – vNIC / SR-IOV Tree Diagram Generator
#
# Usage  (run via stdin pipe from local machine):
#   (echo "set -- 'Server-9009-42A-SN782D930'"; cat vnic_tree_html_diagram.sh) \
#     | ssh -i key hscroot@<hmc> -T > output.html
#
# NOTE: HMC uses restricted bash – no output redirect (>) is allowed.
#       The script writes HTML to STDOUT; caller captures it.
# ============================================================

if [ $# -lt 1 ]; then
    printf 'Usage: %s <managed-system>\n' "$0" >&2
    exit 1
fi

MANAGED_SYSTEM="$1"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HMC_HOST=$(lshmc -n -F hostname | grep '^hostname=' | cut -d= -f2 || true)
[ -z "$HMC_HOST" ] && HMC_HOST=$(uname -n || true)

echo "[INFO] Collecting data for: $MANAGED_SYSTEM ..." >&2

# ---- HMC data collection ---------------------------------------------------
ALL_LPARS=$(lssyscfg  -r lpar    -m "$MANAGED_SYSTEM" -F name,lpar_id,lpar_env,state)
VNIC_DATA=$(lshwres   -r virtualio --rsubtype vnic     -m "$MANAGED_SYSTEM" --level lpar)
VNIC_BKDEV=$(lshwres  -r virtualio --rsubtype vnicbkdev -m "$MANAGED_SYSTEM")
SRIOV_ADPS=$(lshwres  -r sriov    --rsubtype adapter   -m "$MANAGED_SYSTEM" \
    -F adapter_id,slot_id,phys_loc,config_state,sriov_status,phys_ports,logical_ports)
SRIOV_LP=$(lshwres    -r sriov    --rsubtype logport   -m "$MANAGED_SYSTEM" \
    -F adapter_id,logical_port_id,logical_port_type,drc_name,location_code)

echo "[INFO] Building HTML ..." >&2

# ---- VIOS list (env=vioserver) ---------------------------------------------
VIOS_LIST=""
while IFS=',' read -r lname lid lenv lstate; do
    [ -z "$lname" ] && continue
    [ "$lenv" = "vioserver" ] && VIOS_LIST="${VIOS_LIST}${lname},${lid},${lstate}
"
done <<< "$ALL_LPARS"

# ---- Backing-device state map: logport_id -> status ------------------------
# Format in VNIC_DATA: backing_device_states=sriov/lpid/pri/status,...
declare -A BD_MAP
while IFS= read -r line; do
    [ -z "$line" ] && continue
    bds=$(printf '%s' "$line" | sed 's/.*backing_device_states=//;s/".*//' | grep 'sriov' || true)
    [ -z "$bds" ] && continue
    IFS=',' read -ra BDARR <<< "$bds"
    for bditem in "${BDARR[@]}"; do
        lpid=$(printf '%s' "$bditem" | cut -d'/' -f2)
        bstat=$(printf '%s' "$bditem" | cut -d'/' -f4)
        [ -n "$lpid" ] && [ -n "$bstat" ] && BD_MAP["$lpid"]="$bstat"
    done
done <<< "$VNIC_DATA"

# ---- Node ID counter -------------------------------------------------------
# CRITICAL: never call nid inside $() — that spawns a subshell and NID never
# increments.  Always call nid standalone, then use $NID_LAST.
NID=0
NID_LAST=""
nid() { NID=$((NID+1)); NID_LAST="n${NID}"; }

# ---- HTML-escape helper (never call inside $()) ----------------------------
HE_OUT=""
he() { HE_OUT="$1"; HE_OUT="${HE_OUT//&/&amp;}"; HE_OUT="${HE_OUT//</&lt;}"; HE_OUT="${HE_OUT//>/&gt;}"; HE_OUT="${HE_OUT//\"/&quot;}"; }

# ---- Status class helper (never call inside $()) ---------------------------
SC_OUT=""
sc() {
    case "$1" in
        Operational|operational|Active|active|Running|running|1) SC_OUT="status-ok";;
        "Link Down"|"link down"|Down|down|NOT_LOGGED_IN|0)       SC_OUT="status-err";;
        *)  SC_OUT="status-warn";;
    esac
}

# ---- Statistics ------------------------------------------------------------
NUM_VIOS=0
while IFS= read -r v; do [ -n "$v" ] && NUM_VIOS=$((NUM_VIOS+1)); done <<< "$VIOS_LIST"
NUM_VNICS=0
while IFS= read -r v; do [ -n "$v" ] && NUM_VNICS=$((NUM_VNICS+1)); done <<< "$VNIC_DATA"
NUM_ADP=$(printf '%s\n' "$SRIOV_ADPS" | grep -v '^null,' | grep -c . || echo 0)
NUM_ACT=$(printf '%s\n' "$VNIC_BKDEV" | grep -c 'is_active=1' || echo 0)

# Count unique client LPARs that have vNICs
NUM_LPAR_VNIC=$(printf '%s\n' "$VNIC_DATA" | grep -o 'lpar_name=[^,]*' | sort -u | grep -c . || echo 0)

# ===========================================================================
# HTML OUTPUT
# ===========================================================================

printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n'
printf '<meta charset="UTF-8"/>\n'
printf '<meta name="viewport" content="width=device-width,initial-scale=1"/>\n'
he "$MANAGED_SYSTEM"; printf '<title>vNIC Tree – %s</title>\n' "$HE_OUT"

cat << 'CSS_EOF'
<style>
/* ── Reset & Base ───────────────────────────────────────────────────────── */
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,"Segoe UI",Roboto,system-ui,sans-serif;font-size:14px;
     background:#f0f2f5;color:#1f2328;line-height:1.55}

/* ── Header ─────────────────────────────────────────────────────────────── */
header{background:#1d3557;color:#fff;padding:13px 24px;display:flex;
       align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;
       box-shadow:0 2px 6px rgba(0,0,0,.25)}
header h1{font-size:16px;font-weight:700;letter-spacing:.4px;display:flex;align-items:center;gap:8px}
header .meta{font-size:11.5px;color:#a8c7e8;line-height:1.6}
header .meta strong{color:#dbeafe}

/* ── Toolbar ─────────────────────────────────────────────────────────────── */
.toolbar{background:#fff;border-bottom:1px solid #e5e7eb;padding:9px 24px;
          display:flex;align-items:center;gap:8px;flex-wrap:wrap;position:sticky;top:0;z-index:10}
.btn{display:inline-flex;align-items:center;gap:5px;padding:5px 13px;border-radius:5px;
     border:1px solid #d1d5db;background:#f9fafb;font-size:12.5px;cursor:pointer;
     font-weight:500;transition:all .15s;color:#374151}
.btn:hover{background:#e5e7eb;border-color:#9ca3af}
.btn.primary{background:#1d3557;color:#fff;border-color:#1d3557}
.btn.primary:hover{background:#274472}
.btn.active{background:#dbeafe;color:#1e40af;border-color:#93c5fd}
.tab-bar{display:flex;gap:4px;margin-left:16px}
.tab{padding:5px 14px;border-radius:5px 5px 0 0;border:1px solid #d1d5db;
     border-bottom:none;background:#f3f4f6;font-size:12.5px;cursor:pointer;color:#6b7280;font-weight:500}
.tab.active{background:#fff;color:#1d3557;border-color:#d1d5db;font-weight:700}
.legend{margin-left:auto;display:flex;align-items:center;gap:12px;font-size:11.5px;
        color:#57606a;flex-wrap:wrap}
.dot{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:3px;vertical-align:middle}
.d-srv{background:#475569}.d-vios{background:#1d4ed8}.d-adp{background:#d97706}
.d-vnic{background:#16a34a}.d-lp{background:#7c3aed}.d-lpar{background:#0e7490}

/* ── Stats bar ──────────────────────────────────────────────────────────── */
main{padding:20px 24px;max-width:1200px;margin:0 auto}
.sbar{display:flex;gap:10px;margin-bottom:18px;flex-wrap:wrap}
.sc{background:#fff;border:1px solid #e5e7eb;border-radius:8px;padding:10px 16px;
    min-width:110px;flex:1;transition:box-shadow .15s}
.sc:hover{box-shadow:0 2px 8px rgba(0,0,0,.08)}
.sc .n{font-size:24px;font-weight:700;color:#1d3557}
.sc .l{font-size:11px;color:#57606a;margin-top:1px;text-transform:uppercase;letter-spacing:.4px}

/* ── Tab panes ──────────────────────────────────────────────────────────── */
.pane{display:none}
.pane.active{display:block}

/* ── Tree ───────────────────────────────────────────────────────────────── */
.tree{list-style:none;padding:0}
.tree ul{list-style:none;padding:0 0 0 18px;border-left:2px solid #e5e7eb;margin:2px 0 2px 11px}
.tree li{padding:1px 0}

/* Node row */
.node{display:flex;align-items:flex-start;gap:5px;cursor:pointer;border-radius:5px;
      padding:5px 7px;user-select:none;transition:background .12s}
.node:hover{background:#eef2ff}
.node.leaf{cursor:default}
.node.leaf:hover{background:transparent}

/* Triangle toggle */
.tri{font-size:9px;color:#9ca3af;width:12px;min-width:12px;margin-top:4px;
     display:inline-block;transition:transform .18s;text-align:center}
.tri.open{transform:rotate(0)}
.tri.closed{transform:rotate(-90deg)}
.leaf .tri{visibility:hidden}

/* Colour tags */
.tag{display:inline-flex;align-items:center;padding:1px 7px;border-radius:9px;
     font-size:10.5px;font-weight:700;letter-spacing:.4px;white-space:nowrap;flex-shrink:0;
     margin-top:1px}
.t-srv {background:#e2e8f0;color:#334155}
.t-vios{background:#dbeafe;color:#1e40af}
.t-adp {background:#fef3c7;color:#92400e}
.t-vnic{background:#dcfce7;color:#166534}
.t-lp  {background:#ede9fe;color:#5b21b6}
.t-lpar{background:#cffafe;color:#155e75}

/* Node text */
.nlabel{font-size:13px;font-weight:600;flex:1;line-height:1.4}
.nsub{font-size:11px;color:#6b7280;margin-left:2px;line-height:1.8}

/* ── Detail panel ───────────────────────────────────────────────────────── */
.panel{background:#fff;border:1px solid #e5e7eb;border-radius:6px;
       padding:10px 14px;margin:3px 0 6px 30px;font-size:12px;
       display:grid;grid-template-columns:1fr 1fr;gap:0 12px}
.panel table{border-collapse:collapse;width:100%}
.panel td{padding:2px 6px 2px 0;vertical-align:top;line-height:1.5}
.panel td.k{color:#57606a;white-space:nowrap;width:48%}
.panel td.v{color:#1f2328;font-weight:500;word-break:break-all}
.panel .psec{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;
             color:#9ca3af;padding:6px 0 2px;border-top:1px solid #f3f4f6;
             grid-column:1/-1}
.panel .psec:first-child{padding-top:0;border-top:none}

/* ── Subtree container ──────────────────────────────────────────────────── */
.subtree{display:block}

/* ── Status badges ──────────────────────────────────────────────────────── */
.status-ok  {color:#16a34a;font-weight:700}
.status-warn{color:#d97706;font-weight:700}
.status-err {color:#dc2626;font-weight:700}
.badge{display:inline-flex;align-items:center;gap:3px;padding:1px 7px;border-radius:8px;
       font-size:11px;font-weight:700;white-space:nowrap}
.badge.ok  {background:#dcfce7;color:#166534}
.badge.warn{background:#fef9c3;color:#854d0e}
.badge.err {background:#fee2e2;color:#991b1b}
.badge::before{content:'';width:6px;height:6px;border-radius:50%;background:currentColor}

/* ── Capacity bar ───────────────────────────────────────────────────────── */
.capbar{display:flex;align-items:center;gap:6px}
.capbar-track{flex:1;height:6px;border-radius:3px;background:#e5e7eb;max-width:80px}
.capbar-fill{height:100%;border-radius:3px;background:#3b82f6}

/* ── Two-column card for LPAR view ─────────────────────────────────────── */
.lpar-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:4px 0 8px 30px}
@media(max-width:700px){.lpar-grid{grid-template-columns:1fr}}
.bk-card{background:#fff;border:1px solid #e5e7eb;border-radius:7px;padding:10px 13px;font-size:12px}
.bk-card-title{font-size:11px;font-weight:700;color:#57606a;text-transform:uppercase;
               letter-spacing:.5px;margin-bottom:6px;display:flex;align-items:center;gap:5px}
.bk-card table{width:100%;border-collapse:collapse}
.bk-card td{padding:1.5px 0;vertical-align:top}
.bk-card td:first-child{color:#6b7280;width:46%}
.bk-card td:last-child{font-weight:500;word-break:break-all}

/* ── Footer ─────────────────────────────────────────────────────────────── */
footer{text-align:center;font-size:11px;color:#9ca3af;padding:18px;
       border-top:1px solid #e5e7eb;margin-top:28px}
</style>
</head>
<body>
CSS_EOF

# ---- Header ----------------------------------------------------------------
he "$MANAGED_SYSTEM"; MGR_ESC="$HE_OUT"
he "$HMC_HOST";       HMC_ESC="$HE_OUT"
printf '<header>\n'
printf '  <h1>&#x1F5A7; IBM PowerVM &mdash; vNIC / SR-IOV Tree</h1>\n'
printf '  <div class="meta">\n'
printf '    Managed System: <strong>%s</strong><br>\n' "$MGR_ESC"
printf '    HMC: <strong>%s</strong> &nbsp;|&nbsp; Generated: %s\n' "$HMC_ESC" "$TIMESTAMP"
printf '  </div>\n'
printf '</header>\n'

# ---- Toolbar ---------------------------------------------------------------
printf '<div class="toolbar">\n'
printf '  <button class="btn primary" onclick="expandAll()">&#9660; Expand All</button>\n'
printf '  <button class="btn" onclick="collapseAll()">&#9654; Collapse All</button>\n'
printf '  <div class="tab-bar">\n'
printf '    <div class="tab active" id="tab-vios" onclick="showTab('"'"'vios'"'"')">&#x1F5A7; VIOS View</div>\n'
printf '    <div class="tab" id="tab-lpar" onclick="showTab('"'"'lpar'"'"')">&#x1F4BB; LPAR View</div>\n'
printf '  </div>\n'
printf '  <div class="legend">\n'
printf '    <span><span class="dot d-srv"></span>Server</span>\n'
printf '    <span><span class="dot d-vios"></span>VIOS</span>\n'
printf '    <span><span class="dot d-adp"></span>SR-IOV Adapter</span>\n'
printf '    <span><span class="dot d-vnic"></span>vNIC</span>\n'
printf '    <span><span class="dot d-lp"></span>Logical Port</span>\n'
printf '    <span><span class="dot d-lpar"></span>Client LPAR</span>\n'
printf '  </div>\n'
printf '</div>\n'

printf '<main>\n'

# ---- Stats bar -------------------------------------------------------------
printf '<div class="sbar">\n'
printf '  <div class="sc"><div class="n">%s</div><div class="l">VIOS Servers</div></div>\n' "$NUM_VIOS"
printf '  <div class="sc"><div class="n">%s</div><div class="l">Client LPARs</div></div>\n' "$NUM_LPAR_VNIC"
printf '  <div class="sc"><div class="n">%s</div><div class="l">vNIC Adapters</div></div>\n' "$NUM_VNICS"
printf '  <div class="sc"><div class="n">%s</div><div class="l">SR-IOV Adapters</div></div>\n' "$NUM_ADP"
printf '  <div class="sc"><div class="n">%s</div><div class="l">Active Backings</div></div>\n' "$NUM_ACT"
printf '</div>\n'

# ===========================================================================
# TAB 1 – VIOS VIEW: Server → VIOS → SR-IOV Adapter → vNIC Client
# ===========================================================================
printf '<div class="pane active" id="pane-vios">\n'
printf '<ul class="tree">\n'

nid; SRV="$NID_LAST"
he "$MANAGED_SYSTEM"; MGR_ESC="$HE_OUT"
printf '<li>\n'
printf '<div class="node" onclick="toggle('"'"'%s'"'"')">\n' "$SRV"
printf '  <span class="tri open" id="tri_%s">&#9660;</span>\n' "$SRV"
printf '  <span class="tag t-srv">SERVER</span>\n'
printf '  <span class="nlabel">%s</span>\n' "$MGR_ESC"
printf '  <span class="nsub">&nbsp;IBM Power &ndash; 9009-42A</span>\n'
printf '</div>\n'
printf '<ul class="subtree" id="%s">\n' "$SRV"

# ---- Loop VIOS -------------------------------------------------------------
while IFS=',' read -r vname vid vstate; do
    [ -z "$vname" ] && continue
    nid; VNODE="$NID_LAST"
    sc "$vstate"; VS_CLS="$SC_OUT"
    he "$vname";  VN_ESC="$HE_OUT"
    he "$vstate"; VS_ESC="$HE_OUT"

    printf '<li>\n'
    printf '<div class="node" onclick="toggle('"'"'%s'"'"')">\n' "$VNODE"
    printf '  <span class="tri open" id="tri_%s">&#9660;</span>\n' "$VNODE"
    printf '  <span class="tag t-vios">VIOS</span>\n'
    printf '  <span class="nlabel">%s</span>\n' "$VN_ESC"
    printf '  <span class="nsub">&nbsp;LPAR ID: %s &nbsp;&mdash;&nbsp;<span class="%s">%s</span></span>\n' \
        "$vid" "$VS_CLS" "$VS_ESC"
    printf '</div>\n'
    printf '<ul class="subtree" id="%s">\n' "$VNODE"

    # Collect adapter IDs used by this VIOS
    ADP_IDS=""
    while IFS= read -r vline; do
        [ -z "$vline" ] && continue
        adps=$(printf '%s' "$vline" | grep -o "sriov/${vname}/${vid}/[0-9]*/" | cut -d'/' -f4 || true)
        for a in $adps; do
            if ! printf '%s\n' "$ADP_IDS" | grep -q "^${a}$"; then
                ADP_IDS="${ADP_IDS}${a}
"
            fi
        done
    done <<< "$VNIC_DATA"
    # Supplement from VNIC_BKDEV
    while IFS= read -r bline; do
        [ -z "$bline" ] && continue
        b_vname=$(printf '%s' "$bline" | grep -o 'lpar_name=[^,]*' | cut -d= -f2)
        b_vid=$(printf '%s' "$bline" | grep -o 'lpar_id=[^,]*' | cut -d= -f2)
        if [ "$b_vname" = "$vname" ] && [ "$b_vid" = "$vid" ]; then
            b_aid=$(printf '%s' "$bline" | grep -o 'adapter_id=[^,]*' | cut -d= -f2)
            if [ -n "$b_aid" ] && ! printf '%s\n' "$ADP_IDS" | grep -q "^${b_aid}$"; then
                ADP_IDS="${ADP_IDS}${b_aid}
"
            fi
        fi
    done <<< "$VNIC_BKDEV"
    ADP_IDS=$(printf '%s' "$ADP_IDS" | sort -u | grep -v '^$' || true)

    if [ -z "$ADP_IDS" ]; then
        printf '<li><div class="node leaf"><span class="tri"></span>'
        printf '<span class="tag t-adp">SR-IOV</span>'
        printf '<span class="nlabel" style="color:#9ca3af;font-style:italic">No SR-IOV adapters via this VIOS</span>'
        printf '</div></li>\n'
    fi

    # ---- Loop Adapters ---------------------------------------------------
    while IFS= read -r aid; do
        [ -z "$aid" ] && continue
        nid; ANODE="$NID_LAST"

        AINFO=$(printf '%s\n' "$SRIOV_ADPS" | grep "^${aid}," || true)
        a_slot=$(printf '%s' "$AINFO" | cut -d, -f2); [ -z "$a_slot" ] && a_slot="N/A"
        a_loc=$(printf '%s' "$AINFO"  | cut -d, -f3); [ -z "$a_loc"  ] && a_loc="N/A"
        a_cfg=$(printf '%s' "$AINFO"  | cut -d, -f4); [ -z "$a_cfg"  ] && a_cfg="N/A"
        a_stat=$(printf '%s' "$AINFO" | cut -d, -f5); [ -z "$a_stat" ] && a_stat="unknown"
        a_phys=$(printf '%s' "$AINFO" | cut -d, -f6); [ -z "$a_phys" ] && a_phys="N/A"
        a_log=$(printf '%s' "$AINFO"  | cut -d, -f7); [ -z "$a_log"  ] && a_log="N/A"

        sc "$a_stat"; A_CLS="$SC_OUT"
        he "$a_stat"; A_STAT_ESC="$HE_OUT"
        he "$a_loc";  A_LOC_ESC="$HE_OUT"

        printf '<li>\n'
        printf '<div class="node" onclick="toggle('"'"'%s'"'"')">\n' "$ANODE"
        printf '  <span class="tri open" id="tri_%s">&#9660;</span>\n' "$ANODE"
        printf '  <span class="tag t-adp">SR-IOV</span>\n'
        printf '  <span class="nlabel">Adapter %s</span>\n' "$aid"
        printf '  <span class="nsub">&nbsp;Slot %s &nbsp;&mdash;&nbsp;<span class="%s">%s</span></span>\n' \
            "$a_slot" "$A_CLS" "$A_STAT_ESC"
        printf '</div>\n'

        # Adapter detail panel
        printf '<div class="panel">\n'
        printf '  <div class="psec">SR-IOV Adapter</div>\n'
        printf '  <table><tr><td class="k">Adapter ID</td><td class="v">%s</td></tr>\n' "$aid"
        printf '  <tr><td class="k">Slot ID</td><td class="v">%s</td></tr>\n' "$a_slot"
        printf '  <tr><td class="k">Physical Location</td><td class="v">%s</td></tr>\n' "$A_LOC_ESC"
        printf '  <tr><td class="k">Config State</td><td class="v">%s</td></tr>\n' "$a_cfg"
        printf '  <tr><td class="k">SR-IOV Status</td><td class="v"><span class="%s">%s</span></td></tr>\n' "$A_CLS" "$A_STAT_ESC"
        printf '  <tr><td class="k">Physical Ports</td><td class="v">%s</td></tr>\n' "$a_phys"
        printf '  <tr><td class="k">Logical Ports</td><td class="v">%s</td></tr></table>\n' "$a_log"
        printf '</div>\n'

        printf '<ul class="subtree" id="%s">\n' "$ANODE"

        # Gather matching vNIC lines
        MATCHED=""
        while IFS= read -r vline; do
            [ -z "$vline" ] && continue
            if printf '%s' "$vline" | grep -q "sriov/${vname}/${vid}/${aid}/"; then
                MATCHED="${MATCHED}${vline}
"
            fi
        done <<< "$VNIC_DATA"

        if [ -z "$MATCHED" ]; then
            printf '<li><div class="node leaf"><span class="tri"></span>'
            printf '<span class="tag t-vnic">vNIC</span>'
            printf '<span class="nlabel" style="color:#9ca3af;font-style:italic">No vNIC clients</span>'
            printf '</div></li>\n'
        fi

        # ---- Loop vNIC clients -------------------------------------------
        while IFS= read -r vl; do
            [ -z "$vl" ] && continue
            nid; VNIC_NODE="$NID_LAST"

            c_name=$(printf '%s' "$vl" | grep -o 'lpar_name=[^,]*' | cut -d= -f2)
            c_id=$(printf '%s' "$vl"   | grep -o 'lpar_id=[^,]*'   | cut -d= -f2)
            c_slot=$(printf '%s' "$vl" | grep -o 'slot_num=[^,]*'  | cut -d= -f2)
            c_pvid=$(printf '%s' "$vl" | grep -o 'port_vlan_id=[^,]*' | cut -d= -f2)
            c_mac=$(printf '%s' "$vl"  | grep -o 'mac_addr=[^,]*'  | cut -d= -f2)
            c_mode=$(printf '%s' "$vl" | grep -o 'curr_mode=[^,]*' | cut -d= -f2)
            c_dmode=$(printf '%s' "$vl"| grep -o 'desired_mode=[^,]*' | cut -d= -f2)
            c_afo=$(printf '%s' "$vl"  | grep -o 'auto_priority_failover=[^,]*' | cut -d= -f2)
            c_ppri=$(printf '%s' "$vl" | grep -o 'pvid_priority=[^,]*' | cut -d= -f2)
            c_avl=$(printf '%s' "$vl"  | grep -o 'allowed_vlan_ids=[^,]*' | cut -d= -f2)
            c_omac=$(printf '%s' "$vl" | grep -o 'allowed_os_mac_addrs=[^,"]*' | cut -d= -f2)
            [ -z "$c_omac" ] && c_omac="none"

            lp_id=$(printf '%s' "$vl" | grep -o "sriov/${vname}/${vid}/${aid}/[0-9]*/[0-9a-fx]*" | sed 's|.*/||' || true)
            bd_stat="unknown"
            [ -n "$lp_id" ] && [ -n "${BD_MAP[$lp_id]+x}" ] && bd_stat="${BD_MAP[$lp_id]}"

            bd_entry=$(printf '%s' "$vl" | grep -o "sriov/${vname}/${vid}/${aid}/[^\",]*" || true)
            c_pp=$(printf '%s' "$bd_entry"   | cut -d'/' -f5)
            c_cap=$(printf '%s' "$bd_entry"  | cut -d'/' -f7)
            c_mcap=$(printf '%s' "$bd_entry" | cut -d'/' -f8)
            c_fpri=$(printf '%s' "$bd_entry" | cut -d'/' -f9)

            c_macf=$(printf '%s' "$c_mac" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')
            c_state=$(printf '%s\n' "$ALL_LPARS" | grep "^${c_name}," | cut -d, -f4)
            [ -z "$c_state" ] && c_state="Unknown"

            sc "$bd_stat"; V_CLS="$SC_OUT"
            sc "$c_state"; C_SCLS="$SC_OUT"
            he "$c_name";  C_NAME_ESC="$HE_OUT"
            he "$bd_stat"; BD_ESC="$HE_OUT"
            he "$c_state"; CS_ESC="$HE_OUT"
            he "$c_macf";  MAC_ESC="$HE_OUT"

            # Badge HTML
            BADGE_BD="<span class=\"badge ${V_CLS#status-}\">${BD_ESC}</span>"
            BADGE_CS="<span class=\"badge ${C_SCLS#status-}\">${CS_ESC}</span>"

            printf '<li>\n'
            printf '<div class="node" onclick="toggle('"'"'%s'"'"')">\n' "$VNIC_NODE"
            printf '  <span class="tri open" id="tri_%s">&#9660;</span>\n' "$VNIC_NODE"
            printf '  <span class="tag t-vnic">vNIC</span>\n'
            printf '  <span class="nlabel">%s</span>\n' "$C_NAME_ESC"
            printf '  <span class="nsub">&nbsp;Slot %s &nbsp;&bull;&nbsp; PVID %s &nbsp;&bull;&nbsp; MAC %s &nbsp;&mdash;&nbsp;%s</span>\n' \
                "$c_slot" "$c_pvid" "$MAC_ESC" "$BADGE_BD"
            printf '</div>\n'

            # vNIC detail panel
            printf '<div class="panel">\n'
            printf '<div class="psec">Client LPAR</div>\n'
            printf '<table>\n'
            printf '<tr><td class="k">LPAR Name</td><td class="v">%s</td></tr>\n' "$C_NAME_ESC"
            printf '<tr><td class="k">LPAR ID</td><td class="v">%s</td></tr>\n' "$c_id"
            printf '<tr><td class="k">LPAR State</td><td class="v">%s</td></tr>\n' "$BADGE_CS"
            printf '</table>\n'
            printf '<table>\n'
            printf '<tr><td class="k">vNIC Slot</td><td class="v">%s</td></tr>\n' "$c_slot"
            printf '<tr><td class="k">MAC Address</td><td class="v">%s</td></tr>\n' "$MAC_ESC"
            printf '<tr><td class="k">Port VLAN ID</td><td class="v">%s</td></tr>\n' "$c_pvid"
            printf '</table>\n'
            printf '<div class="psec">Backing / SR-IOV</div>\n'
            printf '<table>\n'
            printf '<tr><td class="k">Backing VIOS</td><td class="v">%s (ID %s)</td></tr>\n' "$VN_ESC" "$vid"
            printf '<tr><td class="k">SR-IOV Adapter</td><td class="v">%s</td></tr>\n' "$aid"
            printf '<tr><td class="k">Physical Port</td><td class="v">%s</td></tr>\n' "$c_pp"
            printf '<tr><td class="k">Logical Port</td><td class="v">%s</td></tr>\n' "$lp_id"
            printf '<tr><td class="k">Failover Priority</td><td class="v">%s</td></tr>\n' "$c_fpri"
            printf '<tr><td class="k">Capacity</td><td class="v"><div class="capbar"><span>%s%%</span><div class="capbar-track"><div class="capbar-fill" style="width:%s%%"></div></div></div></td></tr>\n' "$c_cap" "$c_cap"
            printf '<tr><td class="k">Max Capacity</td><td class="v">%s%%</td></tr>\n' "$c_mcap"
            printf '<tr><td class="k">Backing Status</td><td class="v">%s</td></tr>\n' "$BADGE_BD"
            printf '</table>\n'
            printf '<div class="psec">vNIC Settings</div>\n'
            printf '<table>\n'
            printf '<tr><td class="k">Mode (Current)</td><td class="v">%s</td></tr>\n' "$c_mode"
            printf '<tr><td class="k">Mode (Desired)</td><td class="v">%s</td></tr>\n' "$c_dmode"
            printf '<tr><td class="k">Auto Priority Failover</td><td class="v">%s</td></tr>\n' "$c_afo"
            printf '<tr><td class="k">PVID Priority</td><td class="v">%s</td></tr>\n' "$c_ppri"
            printf '<tr><td class="k">Allowed VLANs</td><td class="v">%s</td></tr>\n' "$c_avl"
            printf '<tr><td class="k">Allowed OS MACs</td><td class="v">%s</td></tr>\n' "$c_omac"
            printf '</table>\n'
            printf '</div>\n'

            # ---- Logical Port sub-node -----------------------------------
            LP_INFO=$(printf '%s\n' "$SRIOV_LP" | grep "logical_port_id=${lp_id}," || true)
            lp_drc=$(printf '%s' "$LP_INFO"  | grep -o 'drc_name=[^,]*'          | cut -d= -f2); [ -z "$lp_drc"  ] && lp_drc="N/A"
            lp_loc=$(printf '%s' "$LP_INFO"  | grep -o 'location_code=[^,]*'     | cut -d= -f2); [ -z "$lp_loc"  ] && lp_loc="N/A"
            lp_type=$(printf '%s' "$LP_INFO" | grep -o 'logical_port_type=[^,]*' | cut -d= -f2); [ -z "$lp_type" ] && lp_type="N/A"

            printf '<ul class="subtree" id="%s">\n' "$VNIC_NODE"
            printf '<li><div class="node leaf">\n'
            printf '  <span class="tri"></span>\n'
            printf '  <span class="tag t-lp">LOG PORT</span>\n'
            he "$lp_id";  LP_ESC="$HE_OUT"
            printf '  <span class="nlabel">%s</span>\n' "$LP_ESC"
            printf '  <span class="nsub">&nbsp;DRC: %s &nbsp;&bull;&nbsp; %s &nbsp;&mdash;&nbsp;%s</span>\n' \
                "$lp_drc" "$lp_type" "$BADGE_BD"
            printf '</div>\n'
            he "$lp_loc"; LLOC_ESC="$HE_OUT"
            printf '<div class="panel">\n'
            printf '<table>\n'
            printf '<tr><td class="k">Logical Port ID</td><td class="v">%s</td></tr>\n' "$LP_ESC"
            printf '<tr><td class="k">Adapter ID</td><td class="v">%s</td></tr>\n' "$aid"
            printf '<tr><td class="k">Port Type</td><td class="v">%s</td></tr>\n' "$lp_type"
            printf '<tr><td class="k">DRC Name</td><td class="v">%s</td></tr>\n' "$lp_drc"
            printf '<tr><td class="k">Location Code</td><td class="v">%s</td></tr>\n' "$LLOC_ESC"
            printf '<tr><td class="k">Physical Port ID</td><td class="v">%s</td></tr>\n' "$c_pp"
            printf '<tr><td class="k">Status</td><td class="v">%s</td></tr>\n' "$BADGE_BD"
            printf '</table>\n'
            printf '</div>\n'
            printf '</li>\n'
            printf '</ul>\n'

            printf '</li>\n'   # end vNIC li
        done <<< "$MATCHED"

        printf '</ul>\n'   # end adapter subtree
        printf '</li>\n'   # end adapter li
    done <<< "$ADP_IDS"

    printf '</ul>\n'   # end VIOS subtree
    printf '</li>\n'   # end VIOS li
done <<< "$VIOS_LIST"

printf '</ul>\n'   # server subtree
printf '</li>\n'
printf '</ul>\n'   # root tree
printf '</div>\n'  # pane-vios

# ===========================================================================
# TAB 2 – LPAR VIEW: Client LPAR → vNIC Slot → Backing Cards
# ===========================================================================
printf '<div class="pane" id="pane-lpar">\n'
printf '<ul class="tree">\n'

nid; SRV2="$NID_LAST"
printf '<li>\n'
printf '<div class="node" onclick="toggle('"'"'%s'"'"')">\n' "$SRV2"
printf '  <span class="tri open" id="tri_%s">&#9660;</span>\n' "$SRV2"
printf '  <span class="tag t-srv">SERVER</span>\n'
printf '  <span class="nlabel">%s</span>\n' "$MGR_ESC"
printf '  <span class="nsub">&nbsp;IBM Power &ndash; 9009-42A &mdash; LPAR perspective</span>\n'
printf '</div>\n'
printf '<ul class="subtree" id="%s">\n' "$SRV2"

# Collect unique LPAR names that have vNICs
LPAR_NAMES=""
while IFS= read -r vl; do
    [ -z "$vl" ] && continue
    lname=$(printf '%s' "$vl" | grep -o 'lpar_name=[^,]*' | cut -d= -f2)
    [ -z "$lname" ] && continue
    if ! printf '%s\n' "$LPAR_NAMES" | grep -q "^${lname}$"; then
        LPAR_NAMES="${LPAR_NAMES}${lname}
"
    fi
done <<< "$VNIC_DATA"

while IFS= read -r lpar_name; do
    [ -z "$lpar_name" ] && continue
    nid; LPAR_NODE="$NID_LAST"

    lpar_id=$(printf '%s\n' "$ALL_LPARS" | grep "^${lpar_name}," | cut -d, -f2)
    lpar_state=$(printf '%s\n' "$ALL_LPARS" | grep "^${lpar_name}," | cut -d, -f4)
    [ -z "$lpar_state" ] && lpar_state="Unknown"
    sc "$lpar_state"; LS_CLS="$SC_OUT"
    he "$lpar_name";  LN_ESC="$HE_OUT"
    he "$lpar_state"; LST_ESC="$HE_OUT"

    # Collect all vNIC lines for this LPAR
    LPAR_VNICS=""
    while IFS= read -r vl; do
        [ -z "$vl" ] && continue
        lname=$(printf '%s' "$vl" | grep -o 'lpar_name=[^,]*' | cut -d= -f2)
        [ "$lname" = "$lpar_name" ] && LPAR_VNICS="${LPAR_VNICS}${vl}
"
    done <<< "$VNIC_DATA"

    printf '<li>\n'
    printf '<div class="node" onclick="toggle('"'"'%s'"'"')">\n' "$LPAR_NODE"
    printf '  <span class="tri open" id="tri_%s">&#9660;</span>\n' "$LPAR_NODE"
    printf '  <span class="tag t-lpar">LPAR</span>\n'
    printf '  <span class="nlabel">%s</span>\n' "$LN_ESC"
    printf '  <span class="nsub">&nbsp;ID: %s &nbsp;&mdash;&nbsp;<span class="%s">%s</span></span>\n' \
        "$lpar_id" "$LS_CLS" "$LST_ESC"
    printf '</div>\n'
    printf '<ul class="subtree" id="%s">\n' "$LPAR_NODE"

    # ---- Each vNIC slot for this LPAR ------------------------------------
    while IFS= read -r vl; do
        [ -z "$vl" ] && continue
        nid; SLOT_NODE="$NID_LAST"

        c_slot=$(printf '%s' "$vl"  | grep -o 'slot_num=[^,]*'           | cut -d= -f2)
        c_pvid=$(printf '%s' "$vl"  | grep -o 'port_vlan_id=[^,]*'       | cut -d= -f2)
        c_mac=$(printf '%s' "$vl"   | grep -o 'mac_addr=[^,]*'           | cut -d= -f2)
        c_mode=$(printf '%s' "$vl"  | grep -o 'curr_mode=[^,]*'          | cut -d= -f2)
        c_dmode=$(printf '%s' "$vl" | grep -o 'desired_mode=[^,]*'       | cut -d= -f2)
        c_afo=$(printf '%s' "$vl"   | grep -o 'auto_priority_failover=[^,]*' | cut -d= -f2)
        c_ppri=$(printf '%s' "$vl"  | grep -o 'pvid_priority=[^,]*'      | cut -d= -f2)
        c_avl=$(printf '%s' "$vl"   | grep -o 'allowed_vlan_ids=[^,]*'   | cut -d= -f2)

        c_macf=$(printf '%s' "$c_mac" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/')
        he "$c_macf"; MAC_ESC="$HE_OUT"

        # Parse all backings for this vNIC
        raw_bd=$(printf '%s' "$vl" | sed 's/.*backing_devices=//;s/","backing_device_states=.*//' | grep 'sriov' || true)
        raw_bds=$(printf '%s' "$vl" | sed 's/.*backing_device_states=//;s/".*//' | grep 'sriov' || true)

        # Determine overall status: if any backing is Operational → ok
        OVERALL_STAT="unknown"
        IFS=',' read -ra BDS_ARR <<< "$raw_bds"
        for bdi in "${BDS_ARR[@]}"; do
            bdi_stat=$(printf '%s' "$bdi" | cut -d'/' -f4)
            [ "$bdi_stat" = "Operational" ] && OVERALL_STAT="Operational"
        done
        [ "$OVERALL_STAT" = "unknown" ] && OVERALL_STAT=$(printf '%s' "${BDS_ARR[0]}" | cut -d'/' -f4)
        sc "$OVERALL_STAT"; OV_CLS="$SC_OUT"
        he "$OVERALL_STAT"; OV_ESC="$HE_OUT"
        BADGE_OV="<span class=\"badge ${OV_CLS#status-}\">${OV_ESC}</span>"

        printf '<li>\n'
        printf '<div class="node" onclick="toggle('"'"'%s'"'"')">\n' "$SLOT_NODE"
        printf '  <span class="tri open" id="tri_%s">&#9660;</span>\n' "$SLOT_NODE"
        printf '  <span class="tag t-vnic">vNIC</span>\n'
        printf '  <span class="nlabel">Slot %s</span>\n' "$c_slot"
        printf '  <span class="nsub">&nbsp;MAC: %s &nbsp;&bull;&nbsp; PVID: %s &nbsp;&bull;&nbsp; Mode: %s &nbsp;&mdash;&nbsp;%s</span>\n' \
            "$MAC_ESC" "$c_pvid" "$c_mode" "$BADGE_OV"
        printf '</div>\n'

        # vNIC-level summary panel
        printf '<div class="panel">\n'
        printf '<div class="psec">vNIC Configuration</div>\n'
        printf '<table>\n'
        printf '<tr><td class="k">vNIC Slot</td><td class="v">%s</td></tr>\n' "$c_slot"
        printf '<tr><td class="k">MAC Address</td><td class="v">%s</td></tr>\n' "$MAC_ESC"
        printf '<tr><td class="k">Port VLAN ID</td><td class="v">%s</td></tr>\n' "$c_pvid"
        printf '<tr><td class="k">Allowed VLANs</td><td class="v">%s</td></tr>\n' "$c_avl"
        printf '</table>\n'
        printf '<table>\n'
        printf '<tr><td class="k">Mode (Current)</td><td class="v">%s</td></tr>\n' "$c_mode"
        printf '<tr><td class="k">Mode (Desired)</td><td class="v">%s</td></tr>\n' "$c_dmode"
        printf '<tr><td class="k">Auto PF</td><td class="v">%s</td></tr>\n' "$c_afo"
        printf '<tr><td class="k">PVID Priority</td><td class="v">%s</td></tr>\n' "$c_ppri"
        printf '<tr><td class="k">Overall Status</td><td class="v">%s</td></tr>\n' "$BADGE_OV"
        printf '</table>\n'
        printf '</div>\n'

        # ---- Backing device cards (one card per VIOS backing) -----------
        printf '<ul class="subtree" id="%s">\n' "$SLOT_NODE"
        printf '<li><div class="lpar-grid">\n'

        IFS=',' read -ra BD_ARR  <<< "$raw_bd"
        IFS=',' read -ra BSTATE_ARR <<< "$raw_bds"

        BK_IDX=0
        for bk in "${BD_ARR[@]}"; do
            [ -z "$bk" ] && continue
            bk_vios_name=$(printf '%s' "$bk" | cut -d'/' -f2)
            bk_vios_id=$(printf '%s' "$bk"   | cut -d'/' -f3)
            bk_adp=$(printf '%s' "$bk"       | cut -d'/' -f4)
            bk_pp=$(printf '%s' "$bk"        | cut -d'/' -f5)
            bk_lp=$(printf '%s' "$bk"        | cut -d'/' -f6)
            bk_cap=$(printf '%s' "$bk"       | cut -d'/' -f7)
            bk_mcap=$(printf '%s' "$bk"      | cut -d'/' -f8)
            bk_fpri=$(printf '%s' "$bk"      | cut -d'/' -f9)

            # Get status for this logport
            bk_stat="unknown"
            [ -n "$bk_lp" ] && [ -n "${BD_MAP[$bk_lp]+x}" ] && bk_stat="${BD_MAP[$bk_lp]}"
            sc "$bk_stat"; BK_CLS="$SC_OUT"
            he "$bk_stat"; BK_ESC="$HE_OUT"
            BK_BADGE="<span class=\"badge ${BK_CLS#status-}\">${BK_ESC}</span>"

            # Get adapter details
            AINFO=$(printf '%s\n' "$SRIOV_ADPS" | grep "^${bk_adp}," || true)
            bk_a_loc=$(printf '%s' "$AINFO" | cut -d, -f3); [ -z "$bk_a_loc" ] && bk_a_loc="N/A"
            bk_a_stat=$(printf '%s' "$AINFO" | cut -d, -f5); [ -z "$bk_a_stat" ] && bk_a_stat="unknown"

            # Get logport details
            LP_INFO=$(printf '%s\n' "$SRIOV_LP" | grep "logical_port_id=${bk_lp}," || true)
            bk_drc=$(printf '%s' "$LP_INFO"  | grep -o 'drc_name=[^,]*' | cut -d= -f2); [ -z "$bk_drc" ] && bk_drc="N/A"
            bk_loc=$(printf '%s' "$LP_INFO"  | grep -o 'location_code=[^,]*' | cut -d= -f2); [ -z "$bk_loc" ] && bk_loc="N/A"
            bk_ltype=$(printf '%s' "$LP_INFO" | grep -o 'logical_port_type=[^,]*' | cut -d= -f2); [ -z "$bk_ltype" ] && bk_ltype="N/A"

            BK_IDX=$((BK_IDX+1))
            printf '<div class="bk-card">\n'
            printf '<div class="bk-card-title"><span class="dot d-vios"></span>Backing #%s &mdash; %s %s</div>\n' \
                "$BK_IDX" "$BK_BADGE" ""
            printf '<table>\n'
            printf '<tr><td><strong>VIOS</strong></td><td>%s (ID %s)</td></tr>\n' "$bk_vios_name" "$bk_vios_id"
            printf '<tr><td>SR-IOV Adapter</td><td>%s @ %s</td></tr>\n' "$bk_adp" "$bk_a_loc"
            printf '<tr><td>Physical Port</td><td>%s</td></tr>\n' "$bk_pp"
            printf '<tr><td><strong>Logical Port</strong></td><td>%s</td></tr>\n' "$bk_lp"
            printf '<tr><td>DRC Name</td><td>%s</td></tr>\n' "$bk_drc"
            printf '<tr><td>Location Code</td><td style="font-size:11px">%s</td></tr>\n' "$bk_loc"
            printf '<tr><td>Port Type</td><td>%s</td></tr>\n' "$bk_ltype"
            printf '<tr><td>Capacity</td><td><div class="capbar"><span>%s%%</span><div class="capbar-track"><div class="capbar-fill" style="width:%s%%"></div></div></div></td></tr>\n' "$bk_cap" "$bk_cap"
            printf '<tr><td>Max Capacity</td><td>%s%%</td></tr>\n' "$bk_mcap"
            printf '<tr><td>Failover Priority</td><td>%s</td></tr>\n' "$bk_fpri"
            printf '<tr><td>Backing Status</td><td>%s</td></tr>\n' "$BK_BADGE"
            printf '</table>\n'
            printf '</div>\n'
        done

        printf '</div></li>\n'   # end lpar-grid li
        printf '</ul>\n'         # end slot subtree

        printf '</li>\n'         # end slot li
    done <<< "$LPAR_VNICS"

    printf '</ul>\n'   # end LPAR subtree
    printf '</li>\n'   # end LPAR li
done <<< "$LPAR_NAMES"

printf '</ul>\n'   # server subtree (lpar view)
printf '</li>\n'
printf '</ul>\n'   # root tree (lpar view)
printf '</div>\n'  # pane-lpar

# ===========================================================================
# Footer + JavaScript
# ===========================================================================
cat << 'JS_EOF'
</main>
<footer>Generated by vnic_tree_html_diagram.sh v2.0 &nbsp;|&nbsp; IBM HMC vNIC / SR-IOV Documentation &nbsp;|&nbsp; Made with IBM Bob</footer>
<script>
/* ── Toggle single node ──────────────────────────────────────────────── */
function toggle(id){
  var s=document.getElementById(id);
  var t=document.getElementById('tri_'+id);
  if(!s)return;
  var open=s.style.display!=='none';
  s.style.display=open?'none':'block';
  if(t){t.className=open?'tri closed':'tri open';t.innerHTML=open?'&#9654;':'&#9660;';}
}

/* ── Expand / Collapse all in active pane ────────────────────────────── */
function expandAll(){
  var pane=document.querySelector('.pane.active');
  pane.querySelectorAll('.subtree').forEach(function(s){s.style.display='block';});
  pane.querySelectorAll('.tri').forEach(function(t){t.className='tri open';t.innerHTML='&#9660;';});
}
function collapseAll(){
  var pane=document.querySelector('.pane.active');
  pane.querySelectorAll('.subtree').forEach(function(s){s.style.display='none';});
  pane.querySelectorAll('.tri').forEach(function(t){t.className='tri closed';t.innerHTML='&#9654;';});
}

/* ── Tab switching ───────────────────────────────────────────────────── */
function showTab(name){
  document.querySelectorAll('.pane').forEach(function(p){p.classList.remove('active');});
  document.querySelectorAll('.tab').forEach(function(t){t.classList.remove('active');});
  document.getElementById('pane-'+name).classList.add('active');
  document.getElementById('tab-'+name).classList.add('active');
}
</script>
</body>
</html>
JS_EOF

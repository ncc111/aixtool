#!/bin/ksh
# =============================================================================
# generate_svg.sh
# PowerHA Topology SVG Generator  —  v3.1
#
# Reads the SVG data file produced by powerha_inventory.sh and generates a
# self-contained SVG that matches the reference HTML topology exactly:
#   • 1100x620 canvas, dark background #0f172a
#   • filter id="sh", markers #arr #arrg #arrp #arro
#   • Cluster box x=430 w=240, fill #14532d, text #4ade80
#   • CAA repo bar x=360 w=380, stroke #818cf8
#   • Network boxes 130×34 at x=12, compact style
#   • Nodes labelled PRIMARY/STANDBY, with IP and state detail
#   • Fallover arrow between nodes (amber dashed)
#   • RG boxes 200×68, positioned symmetrically: RG1 left, RG2 right
#   • Service IP boxes stroke #a78bfa, App boxes stroke #fb923c
#   • VG boxes fill #14532d, LV boxes fill #0f2a3a stroke #38bdf8 (data)
#     or #0f2a3a stroke #475569 (log)
#   • Legend centred at x=420 y=505, footer at y=612
#
# Usage: ksh generate_svg.sh <svgdata_file> <output.svg>
#
# All coordinates are pre-computed integers — no arithmetic expressions
# are emitted inside SVG attributes.
# =============================================================================

DATA_FILE="${1}"
OUT_FILE="${2:-/tmp/pha_topology.svg}"

if [ ! -f "${DATA_FILE}" ]; then
    print "ERROR: SVG data file not found: ${DATA_FILE}" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Parse data file
# ─────────────────────────────────────────────────────────────────────────────
typeset CL_NAME="" CL_STATE="" CL_VER="" CL_HB=""
typeset NODES="" NODE_STATES="" NODE_DETAILS=""
typeset NODE1_IP="" NODE2_IP=""
typeset RGS="" RG_STATES="" RG_NODES="" RG_VGS="" RG_SVCS=""
typeset VGS="" VG_STATES="" VG_PVS=""
typeset APPS=""
typeset NETS="" NET_MASKS=""
# NET_IPMAP: space-separated tokens "netname=ip1 ip2", semicolon between networks
# e.g. "net_ether_01=192.168.141.101 192.168.141.102;net_ether_02=10.10.10.101 10.10.10.102;"
typeset NET_IPMAP=""
typeset SVC_NAMES="" SVC_IPS=""
typeset REPOS=""
typeset LV_DATA=""   # format: VGNAME:LVNAME:TYPE:MP;...
typeset -i NODE_IDX=0

while IFS="|" read TYPE NAME PARENT DETAIL STATE; do
    [ -z "${TYPE}" ] && continue
    case "${TYPE}" in
        \#*) continue ;;
        CLUSTER)
            CL_NAME="${NAME}"
            CL_STATE="${STATE}"
            CL_VER=$(print "${DETAIL}" | sed 's/.*Ver://;s/ .*//')
            CL_HB=$(print "${DETAIL}"  | sed 's/.*HB://;s/ .*//')
            ;;
        NODE)
            NODE_IDX=$((NODE_IDX + 1))
            NODES="${NODES}${NAME};"
            NODE_STATES="${NODE_STATES}${STATE};"
            NODE_DETAILS="${NODE_DETAILS}${DETAIL};"
            ;;
        INTERFACE)
            _IF_TYPE=$(print "${DETAIL}" | sed 's/.*Type://;s/ .*//')
            _IF_IP=$(print "${DETAIL}"   | sed 's/IP://;s/ .*//')
            _IF_NET=$(print "${DETAIL}"  | sed 's/.*Net://;s/ .*//')
            if [ "${_IF_TYPE}" = "boot" ]; then
                # Capture first boot IP per node for node boxes
                _N1=$(print "${NODES}" | cut -d';' -f1)
                _N2=$(print "${NODES}" | cut -d';' -f2)
                if [ "${PARENT}" = "${_N1}" ]; then
                    [ -z "${NODE1_IP}" ] && NODE1_IP="${_IF_IP}"
                elif [ "${PARENT}" = "${_N2}" ]; then
                    [ -z "${NODE2_IP}" ] && NODE2_IP="${_IF_IP}"
                fi
                # Accumulate boot IPs per network using IFS-safe for loop
                # NET_IPMAP tokens: "netname=ip1 ip2" separated by semicolons
                _matched=0
                _rebuilt=""
                _OLD_IFS="${IFS}"; IFS=";"
                for _tok in ${NET_IPMAP}; do
                    [ -z "${_tok}" ] && continue
                    _tname=$(print "${_tok}" | cut -d= -f1)
                    _tips=$(print "${_tok}"  | cut -d= -f2)
                    if [ "${_tname}" = "${_IF_NET}" ]; then
                        _matched=1
                        _rebuilt="${_rebuilt}${_tname}=${_tips} ${_IF_IP};"
                    else
                        _rebuilt="${_rebuilt}${_tok};"
                    fi
                done
                IFS="${_OLD_IFS}"
                if [ "${_matched}" = "0" ]; then
                    NET_IPMAP="${NET_IPMAP}${_IF_NET}=${_IF_IP};"
                else
                    NET_IPMAP="${_rebuilt}"
                fi
            fi
            ;;
        RG)
            RGS="${RGS}${NAME};"
            RG_STATES="${RG_STATES}${STATE};"
            RG_NODES="${RG_NODES}$(print "${DETAIL}" | sed 's/.*Node://;s/ .*//');"
            RG_VGS="${RG_VGS}$(print "${DETAIL}" | sed 's/.*VG://;s/ .*//');"
            RG_SVCS="${RG_SVCS}$(print "${DETAIL}" | sed 's/.*SVC://');"
            ;;
        VG)
            VGS="${VGS}${NAME};"
            VG_STATES="${VG_STATES}${STATE};"
            VG_PVS="${VG_PVS}$(print "${DETAIL}" | sed 's/.*PVs://;s/@.*//');"
            ;;
        APP)
            APPS="${APPS}${NAME};"
            ;;
        NETWORK)
            NETS="${NETS}${NAME};"
            NET_MASKS="${NET_MASKS}$(print "${DETAIL}" | sed 's/.*Mask://;s/ .*//');"
            ;;
        SERVICEIP)
            SVC_NAMES="${SVC_NAMES}${NAME};"
            SVC_IPS="${SVC_IPS}$(print "${DETAIL}" | sed 's/IP://;s/ .*//');"
            ;;
        REPO)
            REPOS="${REPOS}${DETAIL} "
            ;;
        LV)
            # Skip header/blank rows — valid LVs have a real Type field
            LV_TYPE=$(print "${DETAIL}" | sed 's/Type://;s/ .*//')
            [ -z "${LV_TYPE}" ] && continue
            [ "${LV_TYPE}" = "NAME" ] && continue
            # Skip rows where NAME ends with ':' (lsvg header artefact)
            case "${NAME}" in *:) continue ;; esac
            LV_MP=$(print "${DETAIL}" | sed 's/.*Mount://')
            LV_DATA="${LV_DATA}${PARENT}:${NAME}:${LV_TYPE}:${LV_MP};"
            ;;
    esac
done < "${DATA_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# Colour helpers — match HTML reference palette exactly
# ─────────────────────────────────────────────────────────────────────────────
node_fill()  { print "#14532d"; }
node_stroke(){ print "#22c55e"; }
node_text()  { print "#4ade80"; }

rg_fill_ok()   { print "#14532d"; }
rg_stroke_ok() { print "#22c55e"; }
rg_text_ok()   { print "#4ade80"; }
rg_fill_warn() { print "#451a03"; }
rg_stroke_warn(){ print "#f59e0b"; }
rg_text_warn() { print "#fbbf24"; }
rg_fill_bad()  { print "#450a0a"; }
rg_stroke_bad(){ print "#ef4444"; }
rg_text_bad()  { print "#f87171"; }

rg_colors() {
    # sets RG_FILL RG_STROKE RG_TXT based on state $1
    case "$1" in
        ONLINE|STABLE|active) RG_FILL="#14532d"; RG_STROKE="#22c55e"; RG_TXT="#4ade80" ;;
        OFFLINE|DOWN|FAIL*)   RG_FILL="#450a0a"; RG_STROKE="#ef4444"; RG_TXT="#f87171" ;;
        *)                    RG_FILL="#451a03"; RG_STROKE="#f59e0b"; RG_TXT="#fbbf24" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Extract nth semicolon-delimited token
# ─────────────────────────────────────────────────────────────────────────────
nth() {
    # nth <string> <n>   (1-based)
    print "$1" | tr ';' '\n' | sed -n "${2}p"
}

count_tokens() {
    print "$1" | tr ';' '\n' | grep -c '.'
}

# ─────────────────────────────────────────────────────────────────────────────
# Layout — fixed reference positions from HTML (1100×620)
# ─────────────────────────────────────────────────────────────────────────────
SVG_W=1100
SVG_H=660

# Cluster
CL_X=430; CL_Y=36; CL_W=240; CL_H=52; CL_MX=550; CL_BY=$((CL_Y+CL_H))  # bottom y=88

# CAA repo bar
REPO_X=360; REPO_Y=104; REPO_W=380; REPO_H=30; REPO_MX=550

# Networks — stack vertically on left: x=12, width=155, height=58 (3 text lines)
NET_X=12; NET_W=155; NET_H=58; NET_MX=89
NET_Y0=150; NET_YSTEP=66    # spacing accounts for taller boxes

# Nodes — two fixed positions matching HTML reference
# Node 1 (primary): x=200 w=200  Node 2 (standby): x=700 w=200
NODE_W=200; NODE_H=60; NODE_Y=150
NODE1_X=200; NODE1_MX=300
NODE2_X=700; NODE2_MX=800
NODE_BY=$((NODE_Y + NODE_H))   # =210

# RGs — two fixed positions: RG1 left (x=155), RG2 right (x=740)
RG_W=200; RG_H=68; RG_Y=285
RG1_X=155; RG1_MX=255; RG1_BY=$((RG_Y+RG_H))   # =353
RG2_X=740; RG2_MX=840; RG2_BY=$((RG_Y+RG_H))

# Service IP — centred under its RG (same x-centre as RG)
SVC_W=130; SVC_H=36; SVC_Y=385
SVC1_X=$((RG1_MX - SVC_W/2));  SVC1_MX=${RG1_MX}   # centred under RG1
SVC2_X=$((RG2_MX - SVC_W/2));  SVC2_MX=${RG2_MX}   # centred under RG2

# App controller — row below Service IP
APP_W=130; APP_H=36; APP_Y=$((SVC_Y + SVC_H + 12))
APP1_X=$((RG1_MX - APP_W/2));  APP1_MX=${RG1_MX}   # centred under RG1
APP2_X=$((RG2_MX - APP_W/2));  APP2_MX=${RG2_MX}   # centred under RG2

# VG — row below App controller
VG_W=200; VG_H=48; VG_Y=$((APP_Y + APP_H + 12))
VG1_X=155; VG1_MX=255; VG1_BY=$((VG_Y+VG_H))
VG2_X=740; VG2_MX=840; VG2_BY=$((VG_Y+VG_H))

# LV rows below VG
LV_W=95; LV_H=38; LV_Y=$((VG_Y + VG_H + 14))
# LV1 side: data LV at x=108, log LV at x=215
LV1_DATA_X=108;  LV1_DATA_MX=155
LV1_LOG_X=215;   LV1_LOG_MX=262
# LV2 side: data LV at x=783, log LV at x=888
LV2_DATA_X=783;  LV2_DATA_MX=830
LV2_LOG_X=888;   LV2_LOG_MX=935

# Legend and Footer — computed after all rows so they sit below LVs
# LV_Y is set dynamically; legend goes 12px below LV bottom
# These are computed later after LV_Y is known (see "Derived values" section)
LEG_X=420; LEG_W=310; LEG_H=100

# ─────────────────────────────────────────────────────────────────────────────
# Derived values
# ─────────────────────────────────────────────────────────────────────────────
REPO_DISP=$(print "${REPOS}" | sed 's/  */ /g;s/^ //;s/ $//')

# Legend and footer Y — dynamic, sit below the LV row
typeset -i LEG_Y=$((LV_Y + LV_H + 14))
typeset -i FOOT_Y=$((LEG_Y + LEG_H + 8))

NODE_COUNT=$(count_tokens "${NODES}")
RG_COUNT=$(count_tokens "${RGS}")

NODE1=$(nth "${NODES}" 1); NODE1_STATE=$(nth "${NODE_STATES}" 1)
NODE2=$(nth "${NODES}" 2); NODE2_STATE=$(nth "${NODE_STATES}" 2)

# Node IPs — populated from INTERFACE boot records during parse
N1_IP="${NODE1_IP}"
N2_IP="${NODE2_IP}"

RG1=$(nth "${RGS}" 1); RG1_STATE=$(nth "${RG_STATES}" 1)
RG1_NODE=$(nth "${RG_NODES}" 1); RG1_VG=$(nth "${RG_VGS}" 1); RG1_SVC=$(nth "${RG_SVCS}" 1)

RG2=$(nth "${RGS}" 2); RG2_STATE=$(nth "${RG_STATES}" 2)
RG2_NODE=$(nth "${RG_NODES}" 2); RG2_VG=$(nth "${RG_VGS}" 2); RG2_SVC=$(nth "${RG_SVCS}" 2)

VG1=$(nth "${VGS}" 1); VG1_STATE=$(nth "${VG_STATES}" 1); VG1_PV=$(nth "${VG_PVS}" 1)
VG2=$(nth "${VGS}" 2); VG2_STATE=$(nth "${VG_STATES}" 2); VG2_PV=$(nth "${VG_PVS}" 2)

SVC1_IP=$(nth "${SVC_IPS}" 1)
SVC2_IP=$(nth "${SVC_IPS}" 2)

APP1=$(nth "${APPS}" 1)
APP2=$(nth "${APPS}" 2)

# LV data: extract data LV and log LV for each VG
# Use ":jfs2:" to match data LVs (not jfs2log); field 3 is the type
lv_data_name()  { print "${LV_DATA}" | tr ';' '\n' | grep "^${1}:" | grep ":jfs2:"    | head -1 | cut -d: -f2; }
lv_data_type()  { print "${LV_DATA}" | tr ';' '\n' | grep "^${1}:" | grep ":jfs2:"    | head -1 | cut -d: -f3; }
lv_data_mp()    { print "${LV_DATA}" | tr ';' '\n' | grep "^${1}:" | grep ":jfs2:"    | head -1 | cut -d: -f4; }
lv_log_name()   { print "${LV_DATA}" | tr ';' '\n' | grep "^${1}:" | grep ":jfs2log:" | head -1 | cut -d: -f2; }
lv_log_type()   { print "${LV_DATA}" | tr ';' '\n' | grep "^${1}:" | grep ":jfs2log:" | head -1 | cut -d: -f3; }

VG1_LV_DATA=$(lv_data_name "${VG1}"); VG1_LV_TYPE=$(lv_data_type "${VG1}"); VG1_LV_MP=$(lv_data_mp "${VG1}")
VG1_LV_LOG=$(lv_log_name   "${VG1}"); VG1_LV_LTYPE=$(lv_log_type "${VG1}")
VG2_LV_DATA=$(lv_data_name "${VG2}"); VG2_LV_TYPE=$(lv_data_type "${VG2}"); VG2_LV_MP=$(lv_data_mp "${VG2}")
VG2_LV_LOG=$(lv_log_name   "${VG2}"); VG2_LV_LTYPE=$(lv_log_type "${VG2}")

# Fallback: use lsvg if LV data not in SVG data file
if [ -z "${VG1_LV_DATA}" ] && [ -n "${VG1}" ]; then
    VG1_LV_DATA=$(lsvg -l "${VG1}" 2>/dev/null | grep "jfs2 " | grep -v "log" | head -1 | awk '{print $1}')
    VG1_LV_TYPE="jfs2"
    VG1_LV_MP=$(lsvg -l "${VG1}" 2>/dev/null | grep "jfs2 " | grep -v "log" | head -1 | awk '{print $NF}')
    VG1_LV_LOG=$(lsvg -l "${VG1}" 2>/dev/null | grep "jfs2log" | head -1 | awk '{print $1}')
    VG1_LV_LTYPE="jfs2log"
fi
if [ -z "${VG2_LV_DATA}" ] && [ -n "${VG2}" ]; then
    VG2_LV_DATA=$(lsvg -l "${VG2}" 2>/dev/null | grep "jfs2 " | grep -v "log" | head -1 | awk '{print $1}')
    VG2_LV_TYPE="jfs2"
    VG2_LV_MP=$(lsvg -l "${VG2}" 2>/dev/null | grep "jfs2 " | grep -v "log" | head -1 | awk '{print $NF}')
    VG2_LV_LOG=$(lsvg -l "${VG2}" 2>/dev/null | grep "jfs2log" | head -1 | awk '{print $1}')
    VG2_LV_LTYPE="jfs2log"
fi

# Network short labels
net_label() {
    case "$1" in
        *_01) print "net_ether_01" ;;
        *_02) print "net_ether_02  MGT" ;;
        *_03) print "net_ether_03  BK" ;;
        *)    print "$1" ;;
    esac
}

# Lookup boot IPs for a network from NET_IPMAP
# Returns space-separated IPs, e.g. "192.168.141.101 192.168.141.102"
net_ips_for() {
    _OLD_IFS="${IFS}"; IFS=";"
    for _tok in ${NET_IPMAP}; do
        [ -z "${_tok}" ] && continue
        _tname=$(print "${_tok}" | cut -d= -f1)
        if [ "${_tname}" = "${1}" ]; then
            print "${_tok}" | cut -d= -f2
            IFS="${_OLD_IFS}"
            return
        fi
    done
    IFS="${_OLD_IFS}"
    print ""
}

# Lookup nth mask from NET_MASKS (parallel to NETS)
net_mask_for() {
    # $1 = network name
    typeset -i _mi=0
    _OLD_IFS="${IFS}"; IFS=";"
    for _nname in ${NETS}; do
        _mi=$((_mi + 1))
        if [ "${_nname}" = "${1}" ]; then
            print "${NET_MASKS}" | cut -d';' -f${_mi}
            IFS="${_OLD_IFS}"
            return
        fi
    done
    IFS="${_OLD_IFS}"
    print ""
}

# RG state colours
rg_colors "${RG1_STATE}"; RG1_FILL="${RG_FILL}"; RG1_STROKE="${RG_STROKE}"; RG1_TXT="${RG_TXT}"
rg_colors "${RG2_STATE}"; RG2_FILL="${RG_FILL}"; RG2_STROKE="${RG_STROKE}"; RG2_TXT="${RG_TXT}"

# VG state colours (reuse rg_colors)
rg_colors "${VG1_STATE}"; VG1_FILL="${RG_FILL}"; VG1_STROKE="${RG_STROKE}"; VG1_TXT="${RG_TXT}"
rg_colors "${VG2_STATE}"; VG2_FILL="${RG_FILL}"; VG2_STROKE="${RG_STROKE}"; VG2_TXT="${RG_TXT}"

GEN_DATE=$(date "+%Y-%m-%d %H:%M:%S")
GEN_HOST=$(hostname)

# ─────────────────────────────────────────────────────────────────────────────
# Write SVG
# ─────────────────────────────────────────────────────────────────────────────
cat > "${OUT_FILE}" << SVGEOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${SVG_W}" height="${SVG_H}"
     viewBox="0 0 ${SVG_W} ${SVG_H}" font-family="monospace,sans-serif">
  <defs>
    <filter id="sh" x="-10%" y="-10%" width="120%" height="120%">
      <feDropShadow dx="2" dy="2" stdDeviation="3" flood-color="#00000044"/>
    </filter>
    <marker id="arr" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#94a3b8"/>
    </marker>
    <marker id="arrg" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#22c55e"/>
    </marker>
    <marker id="arrp" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#a78bfa"/>
    </marker>
    <marker id="arro" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#fb923c"/>
    </marker>
  </defs>

  <!-- Background -->
  <rect width="${SVG_W}" height="${SVG_H}" fill="#0f172a"/>

  <!-- Title -->
  <text x="550" y="22" text-anchor="middle" fill="#e2e8f0" font-size="15"
        font-weight="bold">IBM PowerHA SystemMirror &#x2014; Cluster Topology  ${CL_NAME}</text>

  <!-- ══ CLUSTER ══ -->
  <rect x="${CL_X}" y="${CL_Y}" width="${CL_W}" height="${CL_H}" rx="8"
        fill="#14532d" stroke="#22c55e" stroke-width="2.5" filter="url(#sh)"/>
  <text x="${CL_MX}" y="55" text-anchor="middle" fill="#4ade80"
        font-size="10" font-weight="bold">CLUSTER</text>
  <text x="${CL_MX}" y="72" text-anchor="middle" fill="#e2e8f0"
        font-size="14" font-weight="bold">${CL_NAME}</text>
  <text x="${CL_MX}" y="84" text-anchor="middle" fill="#4ade80"
        font-size="10">${CL_STATE}  |  PowerHA ${CL_VER}  |  ${CL_HB} HB</text>

SVGEOF

# ── CAA Repository bar ────────────────────────────────────────────────────────
REPO_TY1=$((REPO_Y + 12))
REPO_TY2=$((REPO_Y + 24))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ CAA REPOSITORY DISKS ══ -->
  <rect x="${REPO_X}" y="${REPO_Y}" width="${REPO_W}" height="${REPO_H}" rx="5"
        fill="#1e293b" stroke="#818cf8" stroke-width="1.5"/>
  <text x="${REPO_MX}" y="${REPO_TY1}" text-anchor="middle" fill="#a5b4fc"
        font-size="8" font-weight="bold">CAA REPOSITORY DISKS</text>
  <text x="${REPO_MX}" y="${REPO_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="9">${REPO_DISP}</text>
  <line x1="${CL_MX}" y1="${CL_BY}" x2="${REPO_MX}" y2="${REPO_Y}"
        stroke="#818cf8" stroke-width="1.2"/>

SVGEOF

# ── Networks (left column) ───────────────────────────────────────────────────
typeset -i NI=0
print "${NETS}" | tr ';' '\n' | grep '.' | while read NETNAME; do
    NI=$((NI + 1))
    N_Y=$((NET_Y0 + (NI-1) * NET_YSTEP))
    N_TY1=$((N_Y + 13))   # "NETWORK" label
    N_TY2=$((N_Y + 26))   # network name
    N_TY3=$((N_Y + 38))   # mask
    N_TY4=$((N_Y + 50))   # IPs
    N_LY=$((N_Y + 29))    # connector mid-point
    N_LX=$((NET_X + NET_W))
    N_LABEL=$(net_label "${NETNAME}")
    N_MASK=$(net_mask_for "${NETNAME}")
    N_IPS=$(net_ips_for "${NETNAME}")
    cat >> "${OUT_FILE}" << SVGEOF
  <!-- Network: ${NETNAME} -->
  <rect x="${NET_X}" y="${N_Y}" width="${NET_W}" height="${NET_H}" rx="5"
        fill="#1e293b" stroke="#38bdf8" stroke-width="1.5"/>
  <text x="${NET_MX}" y="${N_TY1}" text-anchor="middle" fill="#38bdf8"
        font-size="8" font-weight="bold">NETWORK</text>
  <text x="${NET_MX}" y="${N_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="9">${N_LABEL}</text>
  <text x="${NET_MX}" y="${N_TY3}" text-anchor="middle" fill="#94a3b8"
        font-size="7">Mask: ${N_MASK}</text>
  <text x="${NET_MX}" y="${N_TY4}" text-anchor="middle" fill="#7dd3fc"
        font-size="7">${N_IPS}</text>
  <line x1="${N_LX}" y1="${N_LY}" x2="${CL_X}" y2="62"
        stroke="#38bdf8" stroke-width="1" stroke-dasharray="4,3"
        marker-end="url(#arr)"/>
SVGEOF
done

# ── Node 1 (PRIMARY) ─────────────────────────────────────────────────────────
N1_TY1=$((NODE_Y + 17))
N1_TY2=$((NODE_Y + 34))
N1_TY3=$((NODE_Y + 50))
cat >> "${OUT_FILE}" << SVGEOF

  <!-- ══ NODE: ${NODE1} (PRIMARY) ══ -->
  <rect x="${NODE1_X}" y="${NODE_Y}" width="${NODE_W}" height="${NODE_H}" rx="8"
        fill="#14532d" stroke="#22c55e" stroke-width="2" filter="url(#sh)"/>
  <text x="${NODE1_MX}" y="${N1_TY1}" text-anchor="middle" fill="#4ade80"
        font-size="9" font-weight="bold">NODE  (PRIMARY)</text>
  <text x="${NODE1_MX}" y="${N1_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="13" font-weight="bold">${NODE1}</text>
  <text x="${NODE1_MX}" y="${N1_TY3}" text-anchor="middle" fill="#4ade80"
        font-size="9">${N1_IP}  |  ${NODE1_STATE}  CAA:UP</text>
  <line x1="480" y1="${CL_BY}" x2="${NODE1_MX}" y2="${NODE_Y}"
        stroke="#22c55e" stroke-width="1.8" marker-end="url(#arrg)"/>

SVGEOF

# ── Node 2 (STANDBY) ─────────────────────────────────────────────────────────
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ NODE: ${NODE2} (STANDBY) ══ -->
  <rect x="${NODE2_X}" y="${NODE_Y}" width="${NODE_W}" height="${NODE_H}" rx="8"
        fill="#14532d" stroke="#22c55e" stroke-width="2" filter="url(#sh)"/>
  <text x="${NODE2_MX}" y="${N1_TY1}" text-anchor="middle" fill="#4ade80"
        font-size="9" font-weight="bold">NODE  (STANDBY)</text>
  <text x="${NODE2_MX}" y="${N1_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="13" font-weight="bold">${NODE2}</text>
  <text x="${NODE2_MX}" y="${N1_TY3}" text-anchor="middle" fill="#4ade80"
        font-size="9">${N2_IP}  |  ${NODE2_STATE}  CAA:UP</text>
  <line x1="620" y1="${CL_BY}" x2="${NODE2_MX}" y2="${NODE_Y}"
        stroke="#22c55e" stroke-width="1.8" marker-end="url(#arrg)"/>

SVGEOF

# ── Fallover arrow between nodes ─────────────────────────────────────────────
typeset -i FOVER_Y=$((NODE_Y + NODE_H/2))
typeset -i FOVER_TX=$((NODE1_X + NODE_W))
typeset -i FOVER_LBL_Y=$((FOVER_Y - 6))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- Fallover arrow -->
  <line x1="${FOVER_TX}" y1="${FOVER_Y}" x2="${NODE2_X}" y2="${FOVER_Y}"
        stroke="#f59e0b" stroke-width="1.5" stroke-dasharray="6,3"
        marker-end="url(#arr)"/>
  <text x="550" y="${FOVER_LBL_Y}" text-anchor="middle" fill="#f59e0b"
        font-size="9">Fallover &#x2192; FNPN</text>

SVGEOF

# ── Resource Group connectors — link to the CURRENT online node ───────────────
# Determine which node X-centre to draw from based on RG1_NODE / RG2_NODE
# If the RG's current node matches NODE1 → use NODE1_MX, else NODE2_MX
rg_node_cx() {
    # $1=rg_online_node_name  $2=offset_from_centre (+/- pixels for the x touch point)
    if [ "${1}" = "${NODE1}" ]; then
        print $((NODE1_MX + ${2}))
    else
        print $((NODE2_MX + ${2}))
    fi
}

RG_TY1=$((RG_Y + 15))
RG_TY2=$((RG_Y + 31))
RG_TY3=$((RG_Y + 45))
RG_TY4=$((RG_Y + 59))

# RG1: connector leaves the bottom of the online node, offset left of centre
typeset -i RG1_NODE_CX=$(rg_node_cx "${RG1_NODE}" -50)
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ RESOURCE GROUP: ${RG1} ══ -->
  <rect x="${RG1_X}" y="${RG_Y}" width="${RG_W}" height="${RG_H}" rx="7"
        fill="${RG1_FILL}" stroke="${RG1_STROKE}" stroke-width="2" filter="url(#sh)"/>
  <text x="${RG1_MX}" y="${RG_TY1}" text-anchor="middle" fill="${RG1_TXT}"
        font-size="8" font-weight="bold">RESOURCE GROUP</text>
  <text x="${RG1_MX}" y="${RG_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="13" font-weight="bold">${RG1}</text>
  <text x="${RG1_MX}" y="${RG_TY3}" text-anchor="middle" fill="${RG1_TXT}"
        font-size="9">${RG1_STATE} @ ${RG1_NODE}</text>
  <text x="${RG1_MX}" y="${RG_TY4}" text-anchor="middle" fill="#94a3b8"
        font-size="8">OHN / FNPN / NFB</text>
  <line x1="${RG1_NODE_CX}" y1="${NODE_BY}" x2="${RG1_MX}" y2="${RG_Y}"
        stroke="#22c55e" stroke-width="1.5" marker-end="url(#arrg)"/>

SVGEOF

# RG2: connector leaves the bottom of the online node, offset right of centre
typeset -i RG2_NODE_CX=$(rg_node_cx "${RG2_NODE}" 50)
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ RESOURCE GROUP: ${RG2} ══ -->
  <rect x="${RG2_X}" y="${RG_Y}" width="${RG_W}" height="${RG_H}" rx="7"
        fill="${RG2_FILL}" stroke="${RG2_STROKE}" stroke-width="2" filter="url(#sh)"/>
  <text x="${RG2_MX}" y="${RG_TY1}" text-anchor="middle" fill="${RG2_TXT}"
        font-size="8" font-weight="bold">RESOURCE GROUP</text>
  <text x="${RG2_MX}" y="${RG_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="13" font-weight="bold">${RG2}</text>
  <text x="${RG2_MX}" y="${RG_TY3}" text-anchor="middle" fill="${RG2_TXT}"
        font-size="9">${RG2_STATE} @ ${RG2_NODE}</text>
  <text x="${RG2_MX}" y="${RG_TY4}" text-anchor="middle" fill="#94a3b8"
        font-size="8">OHN / FNPN / NFB</text>
  <line x1="${RG2_NODE_CX}" y1="${NODE_BY}" x2="${RG2_MX}" y2="${RG_Y}"
        stroke="#22c55e" stroke-width="1.5" marker-end="url(#arrg)"/>

SVGEOF

# ── Service IP 1 — sits directly below RG1 ───────────────────────────────────
SVC_TY1=$((SVC_Y + 14))
SVC_TY2=$((SVC_Y + 29))
typeset -i SVC1_BY=$((SVC_Y + SVC_H))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ SERVICE IP: ${RG1_SVC} ══ -->
  <rect x="${SVC1_X}" y="${SVC_Y}" width="${SVC_W}" height="${SVC_H}" rx="5"
        fill="#1e293b" stroke="#a78bfa" stroke-width="1.5"/>
  <text x="${SVC1_MX}" y="${SVC_TY1}" text-anchor="middle" fill="#a78bfa"
        font-size="8" font-weight="bold">SERVICE IP</text>
  <text x="${SVC1_MX}" y="${SVC_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="10">${SVC1_IP}</text>
  <line x1="${RG1_MX}" y1="${RG1_BY}" x2="${SVC1_MX}" y2="${SVC_Y}"
        stroke="#a78bfa" stroke-width="1.2" marker-end="url(#arrp)"/>

SVGEOF

# ── App Controller 1 — sits below Service IP 1 ───────────────────────────────
APP_TY1=$((APP_Y + 14))
APP_TY2=$((APP_Y + 29))
typeset -i APP1_BY=$((APP_Y + APP_H))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ APP CONTROLLER: ${APP1} ══ -->
  <rect x="${APP1_X}" y="${APP_Y}" width="${APP_W}" height="${APP_H}" rx="5"
        fill="#1e293b" stroke="#fb923c" stroke-width="1.5"/>
  <text x="${APP1_MX}" y="${APP_TY1}" text-anchor="middle" fill="#fb923c"
        font-size="8" font-weight="bold">APP CONTROLLER</text>
  <text x="${APP1_MX}" y="${APP_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="9">${APP1}</text>
  <line x1="${SVC1_MX}" y1="${SVC1_BY}" x2="${APP1_MX}" y2="${APP_Y}"
        stroke="#fb923c" stroke-width="1.2" marker-end="url(#arro)"/>

SVGEOF

# ── Volume Group 1 — sits below App Controller 1 ─────────────────────────────
VG_TY1=$((VG_Y + 15))
VG_TY2=$((VG_Y + 30))
VG_TY3=$((VG_Y + 43))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ VOLUME GROUP: ${VG1} ══ -->
  <rect x="${VG1_X}" y="${VG_Y}" width="${VG_W}" height="${VG_H}" rx="6"
        fill="${VG1_FILL}" stroke="${VG1_STROKE}" stroke-width="1.5"/>
  <text x="${VG1_MX}" y="${VG_TY1}" text-anchor="middle" fill="${VG1_TXT}"
        font-size="8" font-weight="bold">VOLUME GROUP</text>
  <text x="${VG1_MX}" y="${VG_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="12" font-weight="bold">${VG1}</text>
  <text x="${VG1_MX}" y="${VG_TY3}" text-anchor="middle" fill="#94a3b8"
        font-size="8">${VG1_PV} @ ${RG1_NODE}  |  SCSIPR:Yes</text>
  <line x1="${APP1_MX}" y1="${APP1_BY}" x2="${VG1_MX}" y2="${VG_Y}"
        stroke="#22c55e" stroke-width="1.2" stroke-dasharray="5,3"
        marker-end="url(#arrg)"/>

SVGEOF

# ── LV 1 — data LV (blue) ────────────────────────────────────────────────────
LV_TY1=$((LV_Y + 14))
LV_TY2=$((LV_Y + 27))
LV_TY3=$((LV_Y + 37))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- LV: ${VG1_LV_DATA} (${VG1_LV_TYPE}) -->
  <rect x="${LV1_DATA_X}" y="${LV_Y}" width="${LV_W}" height="${LV_H}" rx="5"
        fill="#0f2a3a" stroke="#38bdf8" stroke-width="1"/>
  <text x="${LV1_DATA_MX}" y="${LV_TY1}" text-anchor="middle" fill="#38bdf8"
        font-size="7">${VG1_LV_TYPE}</text>
  <text x="${LV1_DATA_MX}" y="${LV_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="9">${VG1_LV_DATA}</text>
  <text x="${LV1_DATA_MX}" y="${LV_TY3}" text-anchor="middle" fill="#94a3b8"
        font-size="7">${VG1_LV_MP}</text>
  <line x1="${VG1_BY}" y1="${VG1_BY}" x2="${LV1_DATA_MX}" y2="${LV_Y}"
        stroke="#38bdf8" stroke-width="1" stroke-dasharray="3,2"/>

SVGEOF

# ── LV 1 — log LV (grey) ─────────────────────────────────────────────────────
cat >> "${OUT_FILE}" << SVGEOF
  <!-- LV: ${VG1_LV_LOG} (${VG1_LV_LTYPE}) -->
  <rect x="${LV1_LOG_X}" y="${LV_Y}" width="${LV_W}" height="${LV_H}" rx="5"
        fill="#0f2a3a" stroke="#475569" stroke-width="1"/>
  <text x="${LV1_LOG_MX}" y="${LV_TY1}" text-anchor="middle" fill="#64748b"
        font-size="7">${VG1_LV_LTYPE}</text>
  <text x="${LV1_LOG_MX}" y="${LV_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="9">${VG1_LV_LOG}</text>
  <text x="${LV1_LOG_MX}" y="${LV_TY3}" text-anchor="middle" fill="#475569"
        font-size="7">N/A</text>
  <line x1="${VG1_MX}" y1="${VG1_BY}" x2="${LV1_LOG_MX}" y2="${LV_Y}"
        stroke="#475569" stroke-width="1" stroke-dasharray="3,2"/>

SVGEOF

# ── Service IP 2 — sits directly below RG2 ───────────────────────────────────
typeset -i SVC2_BY=$((SVC_Y + SVC_H))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ SERVICE IP: ${RG2_SVC} ══ -->
  <rect x="${SVC2_X}" y="${SVC_Y}" width="${SVC_W}" height="${SVC_H}" rx="5"
        fill="#1e293b" stroke="#a78bfa" stroke-width="1.5"/>
  <text x="${SVC2_MX}" y="${SVC_TY1}" text-anchor="middle" fill="#a78bfa"
        font-size="8" font-weight="bold">SERVICE IP</text>
  <text x="${SVC2_MX}" y="${SVC_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="10">${SVC2_IP}</text>
  <line x1="${RG2_MX}" y1="${RG2_BY}" x2="${SVC2_MX}" y2="${SVC_Y}"
        stroke="#a78bfa" stroke-width="1.2" marker-end="url(#arrp)"/>

SVGEOF

# ── App Controller 2 — sits below Service IP 2 ───────────────────────────────
typeset -i APP2_BY=$((APP_Y + APP_H))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ APP CONTROLLER: ${APP2} ══ -->
  <rect x="${APP2_X}" y="${APP_Y}" width="${APP_W}" height="${APP_H}" rx="5"
        fill="#1e293b" stroke="#fb923c" stroke-width="1.5"/>
  <text x="${APP2_MX}" y="${APP_TY1}" text-anchor="middle" fill="#fb923c"
        font-size="8" font-weight="bold">APP CONTROLLER</text>
  <text x="${APP2_MX}" y="${APP_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="9">${APP2}</text>
  <line x1="${SVC2_MX}" y1="${SVC2_BY}" x2="${APP2_MX}" y2="${APP_Y}"
        stroke="#fb923c" stroke-width="1.2" marker-end="url(#arro)"/>

SVGEOF

# ── Volume Group 2 — sits below App Controller 2 ─────────────────────────────
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ VOLUME GROUP: ${VG2} ══ -->
  <rect x="${VG2_X}" y="${VG_Y}" width="${VG_W}" height="${VG_H}" rx="6"
        fill="${VG2_FILL}" stroke="${VG2_STROKE}" stroke-width="1.5"/>
  <text x="${VG2_MX}" y="${VG_TY1}" text-anchor="middle" fill="${VG2_TXT}"
        font-size="8" font-weight="bold">VOLUME GROUP</text>
  <text x="${VG2_MX}" y="${VG_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="12" font-weight="bold">${VG2}</text>
  <text x="${VG2_MX}" y="${VG_TY3}" text-anchor="middle" fill="#94a3b8"
        font-size="8">${VG2_PV} @ ${RG2_NODE}  |  SCSIPR:Yes</text>
  <line x1="${APP2_MX}" y1="${APP2_BY}" x2="${VG2_MX}" y2="${VG_Y}"
        stroke="#22c55e" stroke-width="1.2" stroke-dasharray="5,3"
        marker-end="url(#arrg)"/>

SVGEOF

# ── LV 2 — data LV (blue) ────────────────────────────────────────────────────
cat >> "${OUT_FILE}" << SVGEOF
  <!-- LV: ${VG2_LV_DATA} (${VG2_LV_TYPE}) -->
  <rect x="${LV2_DATA_X}" y="${LV_Y}" width="${LV_W}" height="${LV_H}" rx="5"
        fill="#0f2a3a" stroke="#38bdf8" stroke-width="1"/>
  <text x="${LV2_DATA_MX}" y="${LV_TY1}" text-anchor="middle" fill="#38bdf8"
        font-size="7">${VG2_LV_TYPE}</text>
  <text x="${LV2_DATA_MX}" y="${LV_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="9">${VG2_LV_DATA}</text>
  <text x="${LV2_DATA_MX}" y="${LV_TY3}" text-anchor="middle" fill="#94a3b8"
        font-size="7">${VG2_LV_MP}</text>
  <line x1="${VG2_MX}" y1="${VG2_BY}" x2="${LV2_DATA_MX}" y2="${LV_Y}"
        stroke="#38bdf8" stroke-width="1" stroke-dasharray="3,2"/>

SVGEOF

# ── LV 2 — log LV (grey) ─────────────────────────────────────────────────────
cat >> "${OUT_FILE}" << SVGEOF
  <!-- LV: ${VG2_LV_LOG} (${VG2_LV_LTYPE}) -->
  <rect x="${LV2_LOG_X}" y="${LV_Y}" width="${LV_W}" height="${LV_H}" rx="5"
        fill="#0f2a3a" stroke="#475569" stroke-width="1"/>
  <text x="${LV2_LOG_MX}" y="${LV_TY1}" text-anchor="middle" fill="#64748b"
        font-size="7">${VG2_LV_LTYPE}</text>
  <text x="${LV2_LOG_MX}" y="${LV_TY2}" text-anchor="middle" fill="#e2e8f0"
        font-size="9">${VG2_LV_LOG}</text>
  <text x="${LV2_LOG_MX}" y="${LV_TY3}" text-anchor="middle" fill="#475569"
        font-size="7">N/A</text>
  <line x1="${VG2_MX}" y1="${VG2_BY}" x2="${LV2_LOG_MX}" y2="${LV_Y}"
        stroke="#475569" stroke-width="1" stroke-dasharray="3,2"/>

SVGEOF

# ── Legend ────────────────────────────────────────────────────────────────────
typeset -i LEG_R1=$((LEG_Y + 21))
typeset -i LEG_R2=$((LEG_Y + 36))
typeset -i LEG_R3=$((LEG_Y + 51))
typeset -i LEG_C1=$((LEG_X + 10))
typeset -i LEG_C2=$((LEG_X + 140))
typeset -i LEG_TXT1=$((LEG_X + 24))
typeset -i LEG_TXT2=$((LEG_X + 154))
typeset -i LEG_LBL=$((LEG_Y + 15))
typeset -i LEG_R4=$((LEG_Y + 66))
typeset -i LEG_R5=$((LEG_Y + 81))
typeset -i LEG_FOOT=$((LEG_Y + 95))
# Pre-compute all legend text y positions (row y + 8) — avoid arithmetic in SVG attrs
typeset -i LEG_R1_TY=$((LEG_R1 + 8))
typeset -i LEG_R2_TY=$((LEG_R2 + 8))
typeset -i LEG_R3_TY=$((LEG_R3 + 8))
typeset -i LEG_R4_TY=$((LEG_R4 + 8))
cat >> "${OUT_FILE}" << SVGEOF
  <!-- ══ LEGEND ══ -->
  <rect x="${LEG_X}" y="${LEG_Y}" width="${LEG_W}" height="${LEG_H}" rx="6"
        fill="#1e293b" stroke="#334155" stroke-width="1"/>
  <text x="${LEG_C1}" y="${LEG_LBL}" fill="#94a3b8" font-size="9" font-weight="bold">LEGEND</text>
  <rect x="${LEG_C1}" y="${LEG_R1}" width="10" height="9" fill="#14532d" stroke="#22c55e" stroke-width="1.5"/>
  <text x="${LEG_TXT1}" y="${LEG_R1_TY}" fill="#e2e8f0" font-size="8">STABLE / NORMAL / ONLINE / active</text>
  <rect x="${LEG_C1}" y="${LEG_R2}" width="10" height="9" fill="#451a03" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="${LEG_TXT1}" y="${LEG_R2_TY}" fill="#e2e8f0" font-size="8">WARNING / PENDING</text>
  <rect x="${LEG_C1}" y="${LEG_R3}" width="10" height="9" fill="#450a0a" stroke="#ef4444" stroke-width="1.5"/>
  <text x="${LEG_TXT1}" y="${LEG_R3_TY}" fill="#e2e8f0" font-size="8">OFFLINE / DOWN / FAILED</text>
  <rect x="${LEG_C2}" y="${LEG_R1}" width="10" height="9" fill="#1e293b" stroke="#38bdf8" stroke-width="1.5"/>
  <text x="${LEG_TXT2}" y="${LEG_R1_TY}" fill="#e2e8f0" font-size="8">NETWORK / LV</text>
  <rect x="${LEG_C2}" y="${LEG_R2}" width="10" height="9" fill="#1e293b" stroke="#a78bfa" stroke-width="1.5"/>
  <text x="${LEG_TXT2}" y="${LEG_R2_TY}" fill="#e2e8f0" font-size="8">SERVICE IP</text>
  <rect x="${LEG_C2}" y="${LEG_R3}" width="10" height="9" fill="#1e293b" stroke="#fb923c" stroke-width="1.5"/>
  <text x="${LEG_TXT2}" y="${LEG_R3_TY}" fill="#e2e8f0" font-size="8">APP CONTROLLER</text>
  <rect x="${LEG_C2}" y="${LEG_R4}" width="10" height="9" fill="#1e293b" stroke="#818cf8" stroke-width="1.5"/>
  <text x="${LEG_TXT2}" y="${LEG_R4_TY}" fill="#e2e8f0" font-size="8">CAA REPOSITORY</text>

  <!-- ══ FOOTER ══ -->
  <text x="550" y="${FOOT_Y}" text-anchor="middle" fill="#334155" font-size="8">
    READ-ONLY &#x2014; No PowerHA configuration was modified  |  IBM PowerHA SystemMirror Topology  |  ${CL_NAME}  |  Generated: ${GEN_DATE}
  </text>

</svg>
SVGEOF

print "SVG topology written to: ${OUT_FILE}"
exit 0

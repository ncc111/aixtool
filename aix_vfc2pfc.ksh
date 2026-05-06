#!/bin/ksh

echo "======================================================================"
echo "   AIX Virtual FC NPIV Host Mapping Report"
echo "   $(hostname) - $(date)"
echo "======================================================================"
echo ""

for fcs in $(lsdev -Cc adapter -F name | grep '^fcs')
do
    echo "=== ${fcs} ==="

    # Preferred method: vfcstat (cleaner output)
    if command -v vfcstat >/dev/null 2>&1; then
        vfcstat -d ${fcs} -f hostinfo 2>/dev/null
    else
        # Fallback to procfs
        if [[ -f "/proc/sys/adapter/fc/${fcs}/hostinfo" ]]; then
            cat "/proc/sys/adapter/fc/${fcs}/hostinfo"
        else
            echo "hostinfo not available on this AIX level"
        fi
    fi

    echo "----------------------------------------------------------------------"
    echo ""
done

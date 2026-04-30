#!/bin/ksh
echo "System memory usage: \n"
svmon -G -O unit=MB,timestamp=on,pgsz=on

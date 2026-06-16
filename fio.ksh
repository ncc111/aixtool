fio --name=bench --ioengine=posixaio --filename=/dev/rhdisk8 --rw=read --bs=1024k --direct=1 --iodepth=32 --numjobs=1 --runtime=60 --time_based\
 --group_reporting --size=5G

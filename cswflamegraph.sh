#!/bin/bash
#
# cswflamegraph - a Vector pcp pmda for generating a context switch
#		  flame graph.
#
# USAGE: cswflamegraph [seconds]
#
# The $PCP_CONTAINER_NAME environment variable will be read, and if it is
# not NULL, a CPU flame graph will be generated for the container name it
# identifies only.
#
# Check and adjust the environment settings below.
#
# REQUIREMENTS: The libraries perfmaplib.sh and vectorlib.sh. See those
# files for their own requirements.
#
# DEBUG: STDERR includes timestamped debug messages, and command errors. It
# is redirected to the pmda vector log (/var/log/pcp/pmcd/vector.log).
#
# SEE ALSO: http://vectoross.io http://pcp.io
#
# Copyright 2017 Netflix, Inc.
# Licensed under the Apache License, Version 2.0 (the "License")

# host
export TZ=US/Pacific
TS=$(date +%Y-%m-%d_%T)
PATH=/bin:/usr/bin:$PATH
HOSTNAME=$(uname -n)

# pcp pmda paths
METRIC=cswflamegraph
PMDA_DIR=${0%/*}
WEBSITE_DIR=/usr/share/pcp/jsdemos/$METRIC
WORKING_DIR=/var/log/pcp/vector/$METRIC
FG_DIR=/var/lib/pcp/pmdas/vector/BINFlameGraph
BCC_DIR=/usr/share/bcc/tools
OUT_SVG=$WEBSITE_DIR/${METRIC}.${PCP_CONTEXT}.svg
OUT_STATUS=$WORKING_DIR/${METRIC}.${PCP_CONTEXT}.status
OUT_STACKS=$WORKING_DIR/bcc.stacks.$$
CGROUPFS=/sys/fs/cgroup

# libraries
. $PMDA_DIR/vectorlib.sh
. $PMDA_DIR/perfmaplib.sh

# s3
# S3BUCKET="s3://"

# perf settings
SECS=${1:-10}		# default to 10 seconds if not sepcified

#
# Ensure output directories exist
#
[ ! -d "$WORKING_DIR" ] && mkdir -p $WORKING_DIR
[ ! -d "$WEBSITE_DIR" ] && mkdir -p $WEBSITE_DIR
[ -d "$WEBSITE_DIR" -a -e "$OUT_SVG" ] && rm $OUT_SVG
[ -d "$FG_DIR" ] || errorexit "Flame graph software missing"

# terminator for new log group:
echo >&2

if ! grep -w bpf_get_stackid /proc/kallsyms > /dev/null 2>&1; then
	# check for the capability rather than the kernel version, because it
	# may have been backported.
	errorexit "BPF stacks not available on this kernel version (see help)"
fi
if [ ! -e $BCC_DIR/stackcount ]; then
	errorexit "bcc/BPF tool stackcount not installed ($BCC_DIR)"
fi

debugtime "$0 start, container=$PCP_CONTAINER_NAME"
statusmsg "Tracing for $SECS seconds"

# XXX make container aware when bcc tool supports it
cgroupfilter=""
tasklist=""
fgtitle="Context Switch Flame Graph (no idle): $HOSTNAME, $TS"

#
# Trace
#
# XXX support older version of stackcount that lacks -d and -f:
timeout -s 2 $SECS ${BCC_DIR}/stackcount t:sched:sched_switch > $OUT_STACKS &
bgpid=$!
s=0
# update status message
while (( s < SECS )); do
	# give bcc a chance to error before doing a kill -0 check:
	sleep 1
	kill -0 $bgpid > /dev/null 2>&1 || break
	sleep 4
	(( s += 5 ))
	statusmsg "Tracing for $SECS seconds ($s/$SECS)" 2>/dev/null
done
wait -n
status=$?
(( status == 0 || status == 124 )) || errorexit "BPF instrumentation failed. Old kernel version? (See help.)"

# lower our priority before flame graph generation, to reduce CPU contention:
renice -n 19 -p $$ &>/dev/null

# prepare symbol maps
statusmsg "Collecting symbol maps"
dump_java_maps $tasklist
fix_node_maps $tasklist

# decide upon a palette
if pgrep -x node >/dev/null; then
	color=js
else
	color=java
fi

# generate flame graph and stash it away with the folded profile on s3
statusmsg "Flame Graph generation"
$FG_DIR/stackcollapse.pl < $OUT_STACKS | egrep -v 'cpu_idle|cpuidle_enter' | \
    $FG_DIR/flamegraph.pl --minwidth=0.5 --color=$color --hash --title="$fgtitle" --countname=events > $OUT_SVG

# send to s3
# statusmsg "s3 archive"
# s3cp $OUT_SVG $S3BUCKET/${METRIC}-$TS.svg >/dev/null &
# s3cp $OUT_STACKS $S3BUCKET/${METRIC}-$TS.stacks >/dev/null &

statusmsg "Usage: $(rusage)"
statusmsg "DONE"

# $PERF_DATA file left behind for debug or custom reports
# XXX add code that cleans up all output files except the most recent 10

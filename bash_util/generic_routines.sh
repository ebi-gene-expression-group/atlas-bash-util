#!/bin/bash

IFS="
"

# This procedure uses lsf_list to check if process $arg is running. Because lsf_list has been known to hang (presumably because
# of the underlying bjobs hanging when the LSF cluster is very busy), this function runs lsf_list in the background, and kills
# and re-tries it if it doesn't come back within 10 seconds.
lsf_process_running() {
    arg=$1
    rm -rf lsf_list.$arg.aux
    lsf_list > lsf_list.$arg.aux &
    bgProcId=$!
    while [ ! -f lsf_list.$arg.aux ]; do
	# Sleep for 1 sec - to let lsf_list complete if it's to respond quickly
	sleep 1
	ps $bgProcId > /dev/null
	if [ $? -eq 0 ]; then
	    echo "lsf_list ($bgProcId) is still running - sleep for 10 secs..."
	    sleep 10
	    if [ $? -eq 0 ]; then
	        # The background process is _still_ running - kill it and re-start
	        kill -9 $bgProcId > /dev/null 2>&1
		if [ $? -eq 0 ]; then 
		    # If $bgProcId was in fact killed, start another one
		    lsf_list > lsf_list.$arg.aux &
		    bgProcId=$!
		fi
	    fi
	fi
    done
    grep $arg lsf_list.$arg.aux > /dev/null
    ret=$?
    rm -rf lsf_list.$arg.aux
    return $ret
}
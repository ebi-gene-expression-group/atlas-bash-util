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

function capitalize_first_letter {
    arg=$1
    echo -n $arg | sed 's/\(.\).*/\1/' | tr "[:lower:]" "[:upper:]"; echo -n $arg | sed 's/.\(.*\)/\1/'
}

importMageTabFromAE2() {
    expAcc=$1

    middle=`echo $expAcc | awk -F"-" '{print $2}'`
    cp /nfs/ma/home/arrayexpress/ae2_production/data/EXPERIMENT/${middle}/${expAcc}/${expAcc}.idf.txt ${expAcc}/${expAcc}.idf.txt
    if [ ! -s $expAcc/$expAcc.idf.txt ]; then
	echo "[ERROR] Failed to download: /nfs/ma/home/arrayexpress/ae2_production/data/EXPERIMENT/${middle}/${expAcc}/${expAcc}.idf.txt" >> $log
	return  1
    fi

    middle=`echo $expAcc | awk -F"-" '{print $2}'`
    cp /nfs/ma/home/arrayexpress/ae2_production/data/EXPERIMENT/${middle}/${expAcc}/${expAcc}.sdrf.txt ${expAcc}/${expAcc}.sdrf.txt
    if [ ! -s $expAcc/$expAcc.sdrf.txt ]; then
	echo "[ERROR] Failed to download: /nfs/ma/home/arrayexpress/ae2_production/data/EXPERIMENT/${middle}/${expAcc}/${expAcc}.sdrf.txt" >> $log
        return 1
    fi

    return 0
}

# Applies fixes encoded in $fixesFile to $exp.$fileTypeToBeFixed.txt
applyFixes() {
    exp=$1
    fixesFile=$2
    fileTypeToBeFixed=$3
    log=$4

    # Apply factor type fixes in ${fileTypeToBeFixed} file
    for l in $(cat $ATLAS_PROD/sw/atlasprod/experiment_metadata/$fixesFile | sed 's|[[:space:]]*$||g');
    do
	if [ ! -s "$exp/$exp.${fileTypeToBeFixed}.txt" ]; then
	    echo "ERROR: $exp/$exp.${fileTypeToBeFixed}.txt not found or is empty" >> $log
	    return 1
	fi 
	echo $l | grep -P '\t' > /dev/null
	if [ $? -ne 0 ]; then
	    echo  "WARNING: line: '$l' in automatic_fixes_properties.txt is missing a tab character - not applying the fix "  >> $log
	fi
	correct=`echo $l | awk -F"\t" '{print $1}'`
	toBeReplaced=`echo $l | awk -F"\t" '{print $2}'`
	perl -pi -e "s|\t${toBeReplaced}\t|\t${correct}\t|g" $exp/$exp.${fileTypeToBeFixed}.txt
	perl -pi -e "s|\t${toBeReplaced}$|\t${correct}|g" $exp/$exp.${fileTypeToBeFixed}.txt
	if [ "$fixesFile" == "automatic_fixes_properties.txt" ]; then
	    if [ "$fileTypeToBeFixed" == "sdrf" ]; then
		#in sdrf fix factor types only
		perl -pi -e "s|\[${toBeReplaced}\]|[${correct}]|g" $exp/$exp.${fileTypeToBeFixed}.txt
	    fi
	fi
    done
}

applyAllFixesForExperiment() {
   exp=$1
   echo "Applying fixes for $exp ..." 
    # Apply factor type fixes in idf file
    applyFixes $exp automatic_fixes_properties.txt idf
    if [ $? -ne 0 ]; then
	echo "ERROR: Applying factor type fixes in idf file for $exp failed" 
	return 1
    fi
    # Apply factor/sample characteristic type fixes to sdrf
    applyFixes $exp automatic_fixes_properties.txt sdrf 
    if [ $? -ne 0 ]; then
	echo "ERROR: Applying sample characteristic/factor types fixes in sdrf file for $exp failed" 
	return 1
    fi
    # Apply sample characteristic/factor value fixes in sdrf file
    applyFixes $exp automatic_fixes_values.txt sdrf
    if [ $? -ne 0 ]; then
	echo "ERROR: Applying sample characteristic/factor value fixes in sdrf file for $exp failed" 
	return 1
    fi
}
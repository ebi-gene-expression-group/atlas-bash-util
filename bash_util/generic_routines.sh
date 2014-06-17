#!/bin/bash

IFS="
"

# This procedure uses lsf_list to check if process $arg is running. Because lsf_list has been known to hang (presumably because
# of the underlying bjobs hanging when the LSF cluster is very busy), this function includes 5 re-tries
lsf_process_running() {
    arg=$1
    tries=1
    lsfListOutput=`lsf_list 5`
    exitStatus=$?
    while [ "$exitStatus" -ne 0 ]; do
        tries=$[$tries+1]
	if [ $tries -le 5 ]; then 
            lsfListOutput=`lsf_list 5`
	    exitStatus=$?
	else
	    echo "ERROR: Tried to run lsf_list $tries times - it timed out every time"  >&2
	    break
	fi
    done
    if [ "$exitStatus" -ne 0 ]; then
	return 255
    else
	echo $lsfListOutput | grep "$arg" > /dev/null
	return $?
    fi
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
	echo "[ERROR] Failed to download: /nfs/ma/home/arrayexpress/ae2_production/data/EXPERIMENT/${middle}/${expAcc}/${expAcc}.idf.txt" >&2
	return  1
    fi

    middle=`echo $expAcc | awk -F"-" '{print $2}'`
    cp /nfs/ma/home/arrayexpress/ae2_production/data/EXPERIMENT/${middle}/${expAcc}/${expAcc}.sdrf.txt ${expAcc}/${expAcc}.sdrf.txt
    if [ ! -s $expAcc/$expAcc.sdrf.txt ]; then
	echo "[ERROR] Failed to download: /nfs/ma/home/arrayexpress/ae2_production/data/EXPERIMENT/${middle}/${expAcc}/${expAcc}.sdrf.txt" >&2
        return 1
    fi

    return 0
}

# Applies fixes encoded in $fixesFile to $exp.$fileTypeToBeFixed.txt
applyFixes() {
    exp=$1
    fixesFile=$2
    fileTypeToBeFixed=$3

    # Apply factor type fixes in ${fileTypeToBeFixed} file
    for l in $(cat $ATLAS_PROD/sw/atlasprod/experiment_metadata/$fixesFile | sed 's|[[:space:]]*$||g');
    do
	if [ ! -s "$exp/$exp.${fileTypeToBeFixed}.txt" ]; then
	    echo "ERROR: $exp/$exp.${fileTypeToBeFixed}.txt not found or is empty" >&2
	    return 1
	fi 
	echo $l | grep -P '\t' > /dev/null
	if [ $? -ne 0 ]; then
	    echo  "WARNING: line: '$l' in automatic_fixes_properties.txt is missing a tab character - not applying the fix " 
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
	echo "ERROR: Applying factor type fixes in idf file for $exp failed" >&2
	return 1
    fi
    # Apply factor/sample characteristic type fixes to sdrf
    applyFixes $exp automatic_fixes_properties.txt sdrf 
    if [ $? -ne 0 ]; then
	echo "ERROR: Applying sample characteristic/factor types fixes in sdrf file for $exp failed" >&2
	return 1
    fi
    # Apply sample characteristic/factor value fixes in sdrf file
    applyFixes $exp automatic_fixes_values.txt sdrf
    if [ $? -ne 0 ]; then
	echo "ERROR: Applying sample characteristic/factor value fixes in sdrf file for $exp failed" >&2
	return 1
    fi
}

# Restriction to run prod scripts as the prod user only
check_prod_user() {
    user=`whoami`
    if [ "$user" != "fg_atlas" ]; then
	echo "ERROR: You need be sudo-ed as fg_atlas to run this script" >&2
	return 1
    fi
    return 0
}

# Get sudo-ed user
get_sudoed_user() {
    realUser=`TTYTEST=$(ps | awk '{print $2}' |tail -1); ps -ef |grep "$TTYTEST$" |awk '{print $1}'`
    echo $realUser
}
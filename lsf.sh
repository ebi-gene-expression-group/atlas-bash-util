# Submit a job to the cluster

lsf_submit(){
    local commandString="$1"
    local jobQueue="$2"
    local jobName="$3"
    local lsfMem="$4"
    local nThreads="$5"
    local jobGroupName="$6"       
    local workingDir="$7"
    local logPrefix="$8"

    # Need at least the command string

    if [ -z "$commandString" ]; then
        die "Need at least a command string for LSF submission"
    fi

    # Check parameter settings

    if [ -n "$jobQueue" ]; then jobQueue=" -q ${jobQueue}"; fi
    if [ -n "$jobName" ]; then jobName=" -J ${jobName}"; fi
    if [ -n "$lsfMem" ]; then lsfMem=" -R \"rusage[mem=$lsfMem]\" -M $lsfMem"; fi
    if [ -n "$nThreads" ]; then nThreads=" -R \"span[ptile=$nThreads]\" -n $nThreads"; fi
    if [ -n "$jobGroupName" ]; then jobGroupName=" -g $jobGroupName"; fi
    if [ -n "$workingDir" ]; then workingDir=" -cwd \"$workingDir\""; fi
    if [ -n "$logPrefix" ]; then 
        logPrefix=" -o \"${logPrefix}.out\" -e \"${logPrefix}\""; 
        mkdir -p $(dirname $logPrefix)
    fi

    local bsub_cmd=$(echo -e "bsub $jobQueue $jobName $lsfMem $nThreads $jobGroupName $workingDir $logPrefix \"$commandString\"" | tr -s " ")

    local bsubOutput=
    bsubOutput=$(eval $bsub_cmd)

    # Assuming submission was successful, extract the job ID

    if [ $? -ne 0 ]; then
        die "Job submission failed"
    else
        echo $bsubOutput | head -n1 | cut -d'<' -f2 | cut -d'>' -f1
    fi
}

# Check lsf status for a job

lsf_job_status() {
    local jobId=$1
    local jobStdout=$2

    check_variables 'jobId'

    local errCode=
    local jobStatus=$(bjobs -a -o "stat" --job_id $jobId | tail -n +2)
    local logPath=
    
    if [ -z "$jobStdout" ]; then 
        jobStdout=$(bjobs -l $jobId)
    elif [ -f "$jobStdout" ]; then
        logMsg=", check logs at $jobStdout."    
        jobStdout="$(cat $jobStdout)"
    fi

    if [ "$jobStatus" = "DONE" ] || [ "$jobStatus" = "" ]; then
        echo -e "$jobStdout" | grep -q 'Done successfully.'
        if [ $? -eq 0 ]; then         
            warn "Successful run for $jobId!" 1>&2
        else
            warn "Failure for job ${jobId}${logMsg}"
            errCode=1
        fi
    elif [ "$jobStatus" = "EXIT" ]; then
        warn "Job $jobId had exit status ${jobStatus}${logMsg}"
        errCode=1
    fi

    echo -n "$jobStatus"
    return $errCode
}

# Monitor running of a particular job

lsf_monitor_job() {
    local jobId=$1
    local pollSecs=${2:-10}
    local jobStdout=$3
    
    local lsfJobStatus=$(lsf_job_status "$jobId" "$jobStdout")
    local lastStatus=$lsfJobStatus
    echo -en "Starting status is ${lsfJobStatus}" 1>&2

    while [ "$lsfJobStatus" = 'PEND' ] || [ "$lsfJobStatus" = 'RUN' ]; do
        echo -n '.' 1>&2
        sleep $pollSecs
        lsfJobStatus=$(lsf_job_status "$jobId" "$jobStdout" 2>/dev/null)
        if [ "$lsfJobStatus" != "$lastStatus" ]; then
            echo -en "\nStatus is now ${lsfJobStatus}" 1>&2
            lastStatus=$lsfJobStatus
        fi
    done
    echo -e "\n" 1>&2
    echo -n "$lsfJobStatus"
} 


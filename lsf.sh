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
    local prioritise="$9"
    local condaEnv="${10}"

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
    if [ -n "$condaEnv" ]; then
        condaBase=$(dirname "$( which conda )" )
        condaCmd=". ${condaBase}/activate ${condaBase}/../envs/${condaEnv}"
        commandString="${condaCmd} && ${commandString}"
    fi
    if [ -n "$logPrefix" ]; then 
        mkdir -p $(dirname $logPrefix)
        logPrefix=" -o \"${logPrefix}.out\" -e \"${logPrefix}.err\""
    fi

    local bsub_cmd=$(echo -e "bsub $jobQueue $jobName $lsfMem $nThreads $jobGroupName $workingDir $logPrefix \"$commandString\"" | tr -s " ")

    local bsubOutput=
    bsubOutput=$(eval $bsub_cmd)

    # Assuming submission was successful, extract the job ID

    if [ $? -ne 0 ]; then
        die "Job submission failed"
    else
        local jobId=$(echo $bsubOutput | head -n1 | cut -d'<' -f2 | cut -d'>' -f1)
        if [ "$prioritise" = 'yes' ]; then
            warn "Prioritising $jobId"
            btop $jobId
        fi
        echo $jobId
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
    local jobStderr=
    local monitorStyle=${4:-'std_out_err'}
    local logCleanup=${5:-'no'}
   
    echo "Monitor style: $monitorStyle"
 
    # Delete any prior logs

    if [ -n "$jobStdout" ]; then
        jobStderr=$(echo -e "$jobStdout" | sed s/.out$/.err/)
        rm -rf $jobStdout $jobStderr
    fi

    # If a log file is provided and viewLogOutput is 'yes', then start tailing the files
   
    local tail_pid=
    if [ -n "$jobStdout" ] && [ "$monitorStyle" = 'std_out_err' ]; then
        touch $jobStderr $jobStdout
        tail -f $jobStderr -f $jobStdout & 
        tail_pid=$!
    else
        monitorStyle='status'
    fi

    # Now submit the job and start status checking

    local lsfJobStatus=$(lsf_job_status "$jobId" "$jobStdout")
    local lastStatus=$lsfJobStatus

    if [ "$monitorStyle" = 'status' ]; then echo -en "Starting status is ${lsfJobStatus}" 1>&2; fi
    
    while [ "$lsfJobStatus" = 'PEND' ] || [ "$lsfJobStatus" = 'RUN' ]; do
        
        if [ "$monitorStyle" = 'status' ]; then echo -n '.' 1>&2; fi
        
        sleep $pollSecs
        lsfJobStatus=$(lsf_job_status "$jobId" "$jobStdout" 2>/dev/null)
        if [ "$lsfJobStatus" != "$lastStatus" ]; then

            if [ "$monitorStyle" = 'status' ]; then echo -en "\nStatus is now ${lsfJobStatus}" 1>&2; fi

            lastStatus=$lsfJobStatus
        fi
    done

    if [ "$monitorStyle" = 'status' ]; then echo -e "\n" 1>&2; fi
    
    # If we've beein tailing job output, then kill it

    if [ -n "$jobStdout" ] && [ "$monitorStyle" = 'std_out_err' ]; then
    
        # Sleep before we kill to allow final outputs to print.
        sleep 10 
        kill -9 $tail_pid
        wait $pid > /dev/null 2>&1
        if [ "$logCleanup" = 'yes' ]; then
            echo "Cleaning up logs $jobStdout, $jobStderr"
            
            # Sleep for a bit before we delete, otherwise it seems like the
            # tail we killed above doesn't quite finish reporting 
           
            sleep 10 
            rm -rf $jobStdout $jobStderr
        fi
    fi
        
    if [ "$lsfJobStatus" != 'DONE' ]; then
        return 1
    fi
} 


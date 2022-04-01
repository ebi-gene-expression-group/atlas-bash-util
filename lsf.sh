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
    local quiet="${11:-'no'}"

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
        condaBase=$(conda info --json | awk '/conda_prefix/ { gsub(/"|,/, "", $2); print $2 }')
        condaCmd=". ${condaBase}/bin/activate ${condaBase}/envs/${condaEnv}"
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
            warn "Prioritising $jobId" "$quiet"
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
    else
        jobStdout=
    fi

    if [ "$jobStatus" = "DONE" ] || [ "$jobStatus" = "" ]; then
        echo -e "$jobStdout" | grep -qP '(Done successfully.|Successfully completed)'
        if [ $? -eq 0 ]; then         
            warn "Successful run for $jobId!" "$quiet"
            errCode=0 
        else
            warn "Failure for job ${jobId}${logMsg}" "$quiet"
            errCode=1
        fi
    elif [ "$jobStatus" = "EXIT" ]; then
        warn "Job $jobId had exit status ${jobStatus}${logMsg}" "$quiet"
        bjobsDashEll=$(bjobs -l $jobId)
        jobExitCode=$(echo -e "$bjobsDashEll" | grep -oP "exit code \d+" | sed "s/exit code //")
        if [ -n "$jobExitCode" ]; then
            errCode=$jobExitCode
        else
            errCode=1
        fi
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
    local returnStdout=${6:-'no'}
    local quiet=${7:-'no'}

    warn "Monitor style: $monitorStyle" "$quiet"
 
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

    local lsfJobStatus
    lsfJobStatus=$(lsf_job_status "$jobId" "$jobStdout")
    lsfExitCode=$?
    local lastStatus=$lsfJobStatus
    
    if [ "$monitorStyle" = 'status' ]; then warn "Starting status is ${lsfJobStatus}" "$quiet" 'no'; fi
    
    while [ "$lsfJobStatus" = 'PEND' ] || [ "$lsfJobStatus" = 'RUN' ]; do
        
        if [ "$monitorStyle" = 'status' ]; then warn '.' "$quiet" 'no'; fi
        
        sleep $pollSecs
        lsfJobStatus=$(lsf_job_status "$jobId" "$jobStdout")
        lsfExitCode=$?
        if [ "$lsfJobStatus" != "$lastStatus" ]; then

            if [ "$monitorStyle" = 'status' ]; then warn "\nStatus is now ${lsfJobStatus}" "$quiet" 'no' 1>&2; fi

            lastStatus=$lsfJobStatus
        fi
    done

    if [ "$monitorStyle" = 'status' ]; then warn "\n" "$quiet"; fi
    
    # If we've beein tailing job output, then kill it

    if [ -n "$jobStdout" ];then
    
        # Sometimes the log files take a few seconds to appear, which can cause
        # problems for the below with very short jobs.

        # Wait for log file to appear

        local checkCount=0
        while [ ! -f "$jobStdout" ] && [ $checkCount -lt 60 ]; do
            sleep 1
            checkCount=$((checkCount+1))
        done    
        if [ ! -f "$jobStdout" ]; then
            die "$jobStdout still absent, something strange with job $jobId"
        fi
   
        # Wait for log file to be complete

        local logComplete=1
        checkCount=0
        while [ "$logComplete" -eq "1" ]; do
            grep -q "for stderr output of this job." $jobStdout
            logComplete=$?
            sleep 1
            checkCount=$((checkCount+1))
        done
        if [ "$logComplete" -ne "0" ]; then
            die "$jobStdout still seems incomplete, something strange with job $jobId"
        fi

        # If we're tracking the logs, kill the tail processes

        if [ "$monitorStyle" = 'std_out_err' ]; then
    
            # Sleep before we kill to allow final outputs to print.
            kill -9 $tail_pid
            wait $pid > /dev/null 2>&1
        fi

        # If user has requested pass-through of STDOUT, cat the log

        if [ "$returnStdout" = 'yes' ]; then
            cat $jobStdout | sed '/^\-\{20\}/q' $jobStdout | head -n -2
        fi

        if [ "$logCleanup" = 'yes' ]; then
            warn "Cleaning up logs $jobStdout, $jobStderr" "$quiet"
            
            rm -rf $jobStdout $jobStderr
        fi
    fi
    return $lsfExitCode
} 


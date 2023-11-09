# Submit a job to the SLURM cluster

slurm_submit(){
    local commandString="$1"
    local jobQueue="$2"
    local jobName="$3"
    local slurmMem="$4"
    local nThreads="$5"
    local jobGroupName="$6"       
    local workingDir="$7"
    local logPrefix="$8"
    local prioritise="$9"
    local condaEnv="${10}"
    local quiet="${11:-'no'}"

    # Need at least the command string

    if [ -z "$commandString" ]; then
        die "Need at least a command string for SLURM submission"
    fi

    # Check parameter settings

    if [ -n "$jobQueue" ]; then jobQueue=" -p ${jobQueue}"; fi
    if [ -n "$jobName" ]; then jobName=" --J ${jobName}"; fi
    if [ -n "$slurmMem" ]; then slurmMem=" --mem $slurmMem"; fi
    if [ -n "$nThreads" ]; then nThreads=" --cpus-per-task $nThreads"; fi
    if [ -n "$jobGroupName" ]; then jobGroupName=" --job-group $jobGroupName"; fi
    if [ -n "$workingDir" ]; then workingDir=" --chdir \"$workingDir\""; fi
    if [ -n "$condaEnv" ]; then
        condaBase=$(conda info --json | awk '/conda_prefix/ { gsub(/"|,/, "", $2); print $2 }')
        #condaCmd=". ${condaBase}/bin/activate ${condaBase}/envs/${condaEnv}"
        ###### the lines below were added to enable the activation of a conda env that is not inside the base conda env directory
        condaEnvPath="${condaBase}/envs/${condaEnv}"
        if [ -d "$condaEnv" ]; then condaEnvPath="$condaEnv"; fi
        condaCmd=". ${condaBase}/bin/activate ${condaEnvPath}"
        ######
        commandString="${condaCmd} && ${commandString}"
    fi
    if [ -n "$logPrefix" ]; then 
        mkdir -p $(dirname $logPrefix)
        logPrefix=" -o \"${logPrefix}.out\" -e \"${logPrefix}.err\""
    fi

    local sbatch_cmd=$(echo -e "sbatch $jobQueue $jobName $slurmMem $nThreads $jobGroupName $workingDir $logPrefix \"$commandString\"" | tr -s " ")

    local sbatchOutput=
    sbatchOutput=$(eval $sbatch_cmd)

    # Assuming submission was successful, extract the job ID

    if [ $? -ne 0 ]; then
        die "Job submission failed"
    else
        local jobId=$(echo $sbatchOutput | grep -oE 'Submitted batch job [0-9]+')
        job_id=${job_id##* }
        # if [ "$prioritise" = 'yes' ]; then
        #     warn "Prioritising $jobId" "$quiet"
        #     btop $jobId
        # fi
        echo $jobId
    fi
}


# Get status and exit code from job ID

slurm_job_status_from_sacct() {
    local jobId=$1
    local quiet=${2:-'no'}

    check_variables 'jobId'

    local jobStatus=
    local jobExitCode=-1

    local jobInfo=$(sacct -j $jobId --format=jobid,state,exitCode,reason --noheader | grep -vE '\.ba\+|\.ex\+') #ignores .ba and .ex entries

    
    if [ -n "$jobInfo" ]; then
        jobStatus=$(echo -e "$jobInfo" | awk '{print $2}')
        if [ "$jobStatus" = 'RUNNING' ]; then
            jobExitCode=0
            warn "$jobId is still running" "$quiet"
        elif [ "$jobStatus" = 'COMPLETED' ]; then
            jobExitCode=0
            warn "Successful run for $jobId!" "$quiet"
        elif [ "$jobStatus" = 'FAILED' ]; then
            jobExitCode=$(echo -e "$jobInfo" | awk '{print $3}')
            jobReason=$(echo -e "$jobInfo" | awk '{print $4}')
        
            # logMsg=''
            # if [ "$jobStdout" != '-' ]; then
            #     logMsg=", check standard out ($jobStdout) and error ($jobStderr) ."
            # fi    
            warn "Job $jobId had exit status ${jobStatus}, error code $jobExitCode and reason $jobReason" "$quiet"
        elif [ "$jobStatus" = 'TIMEOUT' ]; then
            jobExitCode=$(echo -e "$jobInfo" | awk '{print $3}')
            jobReason="TIME OUT"
        
            # logMsg=''
            # if [ "$jobStdout" != '-' ]; then
            #     logMsg=", check standard out ($jobStdout) and error ($jobStderr) ."
            # fi    
            warn "Job $jobId had exit status ${jobStatus}, error code $jobExitCode and reason $jobReason" "$quiet"
        elif [ "$jobStatus" = 'NODE_FAIL' ]; then
            jobExitCode=$(echo -e "$jobInfo" | awk '{print $3}')
            jobReason="NODE_FAIL"
        
            # logMsg=''
            # if [ "$jobStdout" != '-' ]; then
            #     logMsg=", check standard out ($jobStdout) and error ($jobStderr) ."
            # fi    
            warn "Job $jobId had exit status ${jobStatus}, error code $jobExitCode and reason $jobReason" "$quiet"
        fi
    else
        die "Could not get job info for $jobID"
    fi
    
    echo -n "$jobStatus"
    return $jobExitCode
}

# Check slurm status for a job

slurm_job_status_from_log() {
    local jobStdout=$1
    local quiet=${2:-'no'} 

    check_variables 'jobStdout'

    local jobStatus=
    local jobExitCode=-1

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

    # Now get the info part of the log

    local jobInfo=$(cat $jobStdout | sed -n '/^Sender: slurm/,$p')
    local jobId=$(echo -e "$jobInfo" | grep -oP "Subject: Job \d+" | sed 's/Subject: Job //')

    echo -e "$jobInfo" | grep -qP '(Done successfully.|Successfully completed)'
    if [ $? -eq 0 ]; then         
        warn "Successful run for $jobId!" "$quiet"
        jobStatus=DONE
        jobExitCode=0 
    else
        warn "Failure for job ${jobId}${logMsg}" "$quiet"
        jobStatus=EXIT
        jobExitCode=$(cat $jobStdout| grep -oP "exit code \d+" | sed "s/exit code //")
        if [ -z "$jobExitCode" ]; then
            jobExitCode=1
        fi

        warn "Job $jobId had exit status ${jobStatus}, error code $jobExitCode, check standard out $jobStdout" "$quiet"
    fi

    echo -n "$jobStatus"
    return $jobExitCode
}

slurm_monitor_job() {
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

    # Now  start status checking

    local slurmJobStatus
    slurmJobStatus=$(slurm_job_status_from_sacct "$jobId" "$quiet")
    slurmExitCode=$?
    local lastStatus=$slurmJobStatus

    if [ "$monitorStyle" = 'status' ]; then warn "Starting status is ${slurmJobStatus}" "$quiet" 'no'; fi

    while [ "$slurmJobStatus" = 'PENDING' ] || [ "$slurmJobStatus" = 'RUNNING' ]; do

        if [ "$monitorStyle" = 'status' ]; then warn '.' "$quiet" 'no'; fi

        sleep $pollSecs
        slurmJobStatus=$(slurm_job_status_from_sacct "$jobId" "$quiet")
        slurmExitCode=$?
        if [ "$slurmJobStatus" != "$lastStatus" ]; then

            if [ "$monitorStyle" = 'status' ]; then warn "\nStatus is now ${slurmJobStatus}" "$quiet" 'no' 1>&2; fi

            lastStatus=$slurmJobStatus
        fi
    done

    if [ "$monitorStyle" = 'status' ]; then warn "\n" "$quiet"; fi

    # If we've beein tailing job output, then kill it

    if [ -n "$jobStdout" ];then

        # Checking the status from log has the effect of waiting for it to be
        # complete, which we want before we kill the tail
        slurmLogStatus=$(slurm_job_status_from_log "$jobStdout" "yes")

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
    return $slurmExitCode
}


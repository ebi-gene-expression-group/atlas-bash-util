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
        local jobId=$(echo $sbatchOutput | head -n1 | cut -d'<' -f2 | cut -d'>' -f1)
        if [ "$prioritise" = 'yes' ]; then
            warn "Prioritising $jobId" "$quiet"
            btop $jobId
        fi
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

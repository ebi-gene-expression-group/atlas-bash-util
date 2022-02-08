#!/bin/bash

IFS="
"

PEACH_API_URI=${PEACH_API_URI:'http://peach.ebi.ac.uk:8480/api'}

# Check that a given variable is defined

check_variables() {
    vars=("$@")

    for variable in "${vars[@]}"; do
        local value=${!variable}
        if [ -z "$value" ]; then
            die "ERROR: $variable not set";
        fi
    done
}

# Echo error but don't exit

warn (){
    errMsg=$1

    check_variables 'errMsg'

    echo -e "$errMsg" 1>&2
}

# Echo error and exit

die (){
    errMsg=$1
    errCode=$2

    check_variables 'errMsg'

    if [ -n "$errCode" ]; then
        errMsg="$errMsg - exiting with error code $errCode"
    else
        errCode=1
    fi

    echo -e "$errMsg" 1>&2
    exit $errCode
}


# Send Report
send_report() {
    log=$1
    email=$2
    subject=$3
    label=$4
    if [ -z "$label" ]; then
        label="atlas3"
    fi
    numOfNonEmptyLinesInReport=$(egrep -v '^$' ${log}.report | wc -l)
    if [ $numOfNonEmptyLinesInReport -gt 0 ]; then
        today="$(eval date +%Y-%m-%d)"
        mailx -s "[$label/cron] Process new experiments for $today: $subject" $email <${log}.report
        cat ${log}.report >>$log
    fi

    rm -rf ${log}.out ${log}.err ${log}.report
}

# Returns prod or test, depending on the Atlas environment in which the script calling it is running
# It is assuming that all atlasinstall_<env>s are under ${ATLAS_PROD}/sw (it will fail otherwise)
atlas_env() {
    scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    atlasInstallSubDir=$(echo $scriptDir | awk -F"/" '{print $8}')
    echo $atlasInstallSubDir | awk -F"_" '{print $2}'
}

# This procedure returns 0 if process $arg is running; otherwise it returns 1
lsf_process_running() {
    arg=$1
    bjobs -l | tr -d "\n" | perl -p -e 's/\s+/ /g' | perl -p -e 's/Job/\nJob/g' | grep 'Job Priority' | grep "$arg" >/dev/null
    return $?
}

function capitalize_first_letter {
    arg=$1
    echo -n $arg | sed 's/\(.\).*/\1/' | tr "[:lower:]" "[:upper:]" | tr -d "\n"
    echo -n $arg | sed 's/.\(.*\)/\1/'
}

## get privacy status for any experiments
## -MTAB- experiments loaded by AE/Annotare uis checked by peach API
## -GEOD-/-ERAD-/-ENAD- are loaded as public from now on
peach_api_privacy_status() {
    expAcc=$1
    exp_import=$(echo $expAcc | awk -F"-" '{print $2}')

    if [ $exp_import == "MTAB" ]; then
        response=$(curl -s "${PEACH_API_URI}/privacy.txt?acc=$expAcc")
        if [ -z "$response" ]; then
            die "WARNING: Got empty response from ${PEACH_API_URI}/privacy.txt?acc=$expAcc" 0
        fi
        privacyStatus=$(echo $response | awk '{print $2}' | awk -F":" '{print $2}')
        ## if not MTAB, ie. GEOD or ENAD or ERAD are all loaded as public
    else
        privacyStatus=$(echo "public")
    fi

    echo $privacyStatus
}

peach_api_release_date() {
    expAcc=$1
    exp_import=$(echo $expAcc | awk -F"-" '{print $2}')

    if [ $exp_import == "MTAB" ]; then
        response=$(curl -s "$PEACH_API_URI/privacy.txt?acc=$expAcc")
        if [ -z "$response" ]; then
            die "WARNING: Got empty response from ${PEACH_API_URI}/privacy.txt?acc=$expAcc" 0
        fi
        releaseDate=$(echo $response | awk '{print $3}' | awk -F":" '{print $2}')

    ## if not MTAB, ie. GEOD or ENAD or ERAD are all loaded as of today, considering its public and have release date
    ## not less than 2 days
    else
        releaseDate="$(date --date="2 days ago" +%Y-%m-%d)"
    fi

    echo $releaseDate
}

enad_experiment() {
    expAcc=$1
    expType=$(echo $expAcc | awk -F"-" '{ print $2 }')
    if [ "$expType" == "ENAD" ]; then
        return 0
    else
        return 1
    fi
}

## get ena study id from idf
get_ena_study_id() {
    expAcc=$1
    ena_study_id=$(cat $ATLAS_PROD/ENA_import/ENAD/$expAcc/$expAcc.idf.txt | grep -P "Comment\[SecondaryAccession\]" | awk -F"\t" '{ print $2 }')
    echo "$ena_study_id"
}

# this function creates directory in $IRAP_SINGLE_LIB
# for ena based experiments and irap single lib and copies processed isl matrices
move_ena_experiments_to_isl_studies() {
    expAcc=$1
    expTargetDir=$(find ${ATLAS_PROD}/analysis/*/rna-seq/experiments -type d -name $expAcc)

    # get organism name
    organism=$(get_organism.sh ${expTargetDir})
    if [ $? -ne 0 ]; then
        die "Error: failed to retrieve organism for $expAcc"
    fi
    # make directory with organism name in ISL
    mkdir -p ${IRAP_SINGLE_LIB}/studies/$expAcc/$organism

    ena_study_id=$(get_ena_study_id $expAcc)
    if [ $? -ne 0 ]; then
        die "Error: failed to retrieve ENA study id for $expAcc"
    fi

    # RNA-seqer API response to check if the ena study id matrices has been processed.
    api_response=$(curl -s "https://www.ebi.ac.uk/fg/rnaseq/api/tsv/getStudy/$ena_study_id")
    if [ $? -ne 0 ]; then
        echo $api_response
        die "ERROR: Unable to get response from study id $expAcc, not processed ENA study id $ena_study_id"
    fi

    ## download processed matrices from ftp server to the current directory
    ## works similar to rsync
    wget -r -np -nd -N "ftp://ftp.ebi.ac.uk/pub/databases/arrayexpress/data/atlas/rnaseq/studies/ena/$ena_study_id" -P ${IRAP_SINGLE_LIB}/studies/$expAcc/$organism >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        die "ERROR: Unable to download matrices for $expAcc, not processed ENA study id $ena_study_id"
    fi
}

# Applies fixes encoded in $fixesFile to $exp.$fileTypeToBeFixed.txt
applyFixes() {
    exp=$1
    fixesFilePath=$2
    fileTypeToBeFixed=$3
    atlasEnv=$(atlas_env)

    echo 

    # Apply factor type fixes in ${fileTypeToBeFixed} file
    for l in $($cat fixesFilePath | sed 's|[[:space:]]*$||g'); do
        if [ ! -s "$exp/$exp.${fileTypeToBeFixed}" ]; then
            warn "ERROR: $exp/$exp.${fileTypeToBeFixed} not found or is empty"
            return 1
        fi
        echo $l | grep -P '\t' >/dev/null
        if [ $? -ne 0 ]; then
            echo "WARNING: line: '$l' in automatic_fixes_properties.txt is missing a tab character - not applying the fix "
        fi
        correct=$(echo $l | awk -F"\t" '{print $1}')
        toBeReplaced=$(echo $l | awk -F"\t" '{print $2}' | sed 's/[^-A-Za-z0-9_ ]/\\\&/g')

        if [ "$(basename $fixesFilePath)" == "automatic_fixes_properties.txt" ]; then
            # in sdrf or condensed-sdrv fix factor/characteristic types only
            if [ "$fileTypeToBeFixed" == "condensed-sdrf.tsv" ]; then
                # In condensed-sdrf, the factor/characteristic type is the penultimate column - so tabs on both sides
                perl -pi -e "s|\t${toBeReplaced}\t|\t${correct}\t|g" $exp/$exp.${fileTypeToBeFixed}
            else
                # idf
                perl -pi -e "s|\t${toBeReplaced}\t|\t${correct}\t|g" $exp/$exp.${fileTypeToBeFixed}
                perl -pi -e "s|\t${toBeReplaced}$|\t${correct}|g" $exp/$exp.${fileTypeToBeFixed}
            fi
        elif [ "$(basename $fixesFilePath)" == "automatic_fixes_values.txt" ]; then
            if [ "$fileTypeToBeFixed" == "condensed-sdrf.tsv" ]; then
                # In condensed-sdrf, the factor/characteristic value is the last column - so tab on the left and line ending on the right
                perl -pi -e "s|\t${toBeReplaced}$|\t${correct}|g" $exp/$exp.${fileTypeToBeFixed}
            fi
        fi
    done
}

applyAllFixesForExperiment() {
    exp=$1
    echo "Applying fixes for $exp ..."
    # Apply factor type fixes in idf file
    applyFixes $exp automatic_fixes_properties.txt idf.txt
    if [ $? -ne 0 ]; then
        warn "ERROR: Applying factor type fixes in idf file for $exp failed"
    fi

    # Apply factor/sample characteristic type fixes to the condensed-sdrf file
    applyFixes $exp automatic_fixes_properties.txt condensed-sdrf.tsv
    if [ $? -ne 0 ]; then
        echo "ERROR: Applying sample characteristic/factor types fixes in sdrf file for $exp failed" >&2
        return 1
    fi
    # Apply sample characteristic/factor value fixes to the condensed-sdrf file
    applyFixes $exp automatic_fixes_values.txt condensed-sdrf.tsv
    if [ $? -ne 0 ]; then
        echo "ERROR: Applying sample characteristic/factor value fixes in sdrf file for $exp failed" >&2
        return 1
    fi
}

# Restriction to run prod scripts as the prod user only
check_prod_user() {
    user=$(whoami)

    [ -z ${ATLAS_PROD_USER+x} ] && die "Env var ATLAS_PROD_USER for the Atlas production user needs to be defined."

    if [ "$user" != "$ATLAS_PROD_USER" ]; then
        echo "ERROR: You need be sudo-ed as $ATLAS_PROD_USER to run this script" >&2
        return 1
    fi
    return 0
}

# Get sudo-ed user
get_sudoed_user() {
    realUser=$(
        TTYTEST=$(ps | awk '{print $2}' | tail -1)
        ps -ef | grep "$TTYTEST$" | awk '{print $1}'
    )
    echo $realUser
}

get_pass() {
    dbUser=$1
    if [ -e "${ATLAS_PROD}/sw/${dbUser}" ]; then
        cat ${ATLAS_PROD}/sw/${dbUser}
    else
        echo "ERROR: Failed to retrieve DB password" >&2
        return 1
    fi
}

# Get mapping between Atlas experiments and Ensembl DBs that own their species
get_experiments_loaded_since_date() {
    dbConnection=$1
    sinceDate=$2
    echo "select accession from experiment where last_update >= to_date('$sinceDate','DDMonYYYY') and private = 'F' order by accession;" | psql $dbConnection | tail -n +3 | head -n -2 | sed 's/ //g'
}

email_log_error() {
    errorMsg=$1
    log=$2
    email=$3
    echo $errorMsg >>$log
    mailx -s $errorMsg $email <$log
}

# Check if $JOB_TYPE for $EXP_IRAP_DIR is currently in progress
# If $JOB_TYPE is not specified, check if any stage for $EXP_IRAP_DIR is currently in progress
get_inprogress() {
    dbConnection=$1
    JOB_TYPE=$2
    EXP_IRAP_DIR=$3
    jobTypeClause=
    if [ "$JOB_TYPE" != "any" ]; then
        jobTypeClause="jobtype='$JOB_TYPE' and"
    fi
    echo $(echo "select count(*) from ATLAS_JOBS where $jobTypeClause jobobject='${EXP_IRAP_DIR}';" | psql $dbConnection | tail -n +3 | head -n1 | sed 's/ //g')
}

# Set 'in-progress' flag in the DB - so that crontab-ed experiment loading calls don't ever conflict with each other
set_inprogress() {
    dbConnection=$1
    JOB_TYPE=$2
    EXP_IRAP_DIR=$3
    inProgress=$(get_inprogress $dbConnection $JOB_TYPE $EXP_IRAP_DIR)
    if [ $inProgress -ne 0 ]; then
        return 1
    else
        # First delete any previous entries from $EXP_IRAP_DIR - only one job in progress per ${EXP_IRAP_DIR} is allowed
        echo "delete from ATLAS_JOBS where jobobject='${EXP_IRAP_DIR}';" | psql $dbConnection
        echo "insert into ATLAS_JOBS values (current_timestamp(0),'$JOB_TYPE','${EXP_IRAP_DIR}');" | psql $dbConnection
    fi
}

# Remove 'process is active' flag for $processName
remove_inprogress() {
    dbConnection=$1
    JOB_TYPE=$2
    echo "delete from ATLAS_JOBS where jobtype='$JOB_TYPE';" | psql $dbConnection
}

find_properties_file() {
    organism=$1
    property=$2
    #--------------------------------------------------
    # Doesn't work -- gives syntax error on LSF.
    # Salvatore from Systems suggested to add a "$" at the start of the commands
    # (e.g. < $(find ...) but this then produced "ambiguous redirect" messages so
    # giving up on this.
    #
    #   cat \
    #     < (find -L ${ATLAS_PROD}/bioentity_properties/wbps -name ${organism}.wbpsgene.${property}.tsv) \
    #     < (find -L ${ATLAS_PROD}/bioentity_properties/ensembl -name ${organism}.ensgene.${property}.tsv) \
    #     | head -n1
    #--------------------------------------------------

    ensFile="${ATLAS_PROD}/bioentity_properties/ensembl/${organism}.ensgene.${property}.tsv"
    if [ -s "$ensFile" ]; then
        echo $ensFile
    else
        wbpsFile="${ATLAS_PROD}/bioentity_properties/wbps/${organism}.wbpsgene.${property}.tsv"
        if [ -s "$wbpsFile" ]; then
            echo $wbpsFile
        else
            die "No annotation file found for organism $organism and property $property"
        fi
    fi
}

get_arraydesign_file() {
    arraydesign=$1
    organism=$2
    if [ -z ${2+x} ]; then
        find -L ${ATLAS_PROD}/bioentity_properties/array_designs -type f -name "*.${arraydesign}.tsv" | head -n1
    else
        find -L ${ATLAS_PROD}/bioentity_properties/array_designs -type f -name "${organism}.${arraydesign}.tsv" | head -n1
    fi
}

get_organism_given_arraydesign_file() {
    basename $1 | awk -F"." '{print $1}'
}

get_analysis_path_for_experiment_accession() {
    [ "$1" ] && find $ATLAS_PROD/analysis -maxdepth 4 -type d -name "$1" -print -quit
}

get_db_connection() {
    user=$1
    dbIdentifier=$2
    local OPTARG OPTIND opt
    while getopts ":u:d:" opt; do
        case $opt in
        u)
            user=$OPTARG
            ;;
        d)
            dbIdentifier=$OPTARG
            ;;
        ?)
            warn "Unknown option: $OPTARG"
            return 1
            ;;
        esac
    done
    pgPassFile=$ATLAS_PROD/sw/${user}_gxpatlas${dbIdentifier}
    if [ ! -s "$pgPassFile" ]; then
        warn "ERROR: Cannot find password for $user and $dbIdentifier"
        return 1
    fi
    pgAtlasDB=gxpatlas${dbIdentifier}
    pgAtlasHostPort=$(cat $pgPassFile | awk -F":" '{print $1":"$2}')
    pgAtlasUserPass=$(cat $pgPassFile | awk -F":" '{print $5}')
    if [ $? -ne 0 ]; then
        echo >&2 "ERROR: Failed to retrieve db pass"
        return 1
    fi
    echo "postgresql://${user}:${pgAtlasUserPass}@${pgAtlasHostPort}/${pgAtlasDB}"
}

# Take the first two parts of the name, put an underscore in between
# We use lowercase throughout atlasprod, Ensembl website capitalizes them like words
# Exception: canis lupus familiaris is domesticated dog, Canis_familiaris in Ensembl (because Canis_lupus would be wolf)
# For potential reuse later: sed 's/Oryza sativa \([A-Za-z]*\) /Oryza \1 /'
to_ensembl_species_lowercase() {
    cat - | sed 's/Oryza sativa Indica [A-Za-z]roup/Oryza indica/' | tr '[:upper:]' '[:lower:]' | awk '{print $1"_"$2}' | sed 's/canis_lupus/canis_familiaris/'
}

# Get organism from the plain .sdrf. Currently used only in loading single-cell
# bundles.
get_organism_from_sdrf_txt() {
    sdrf_file=$1

    if [ ! -e $sdrf_file ]; then
        echo "ERROR: .sdrf file $sdrf_file does not exist"
        return 1
    fi

    f=$(head -n1 $sdrf_file | awk -F'\t' '{for (i = 1; i <= NF; ++i) if ($i ~ "Characteristics *\\[organism\\]") print i }')
    cut -f "$f" $sdrf_file | tail -n+2 | sort -u | to_ensembl_species_lowercase
}

## monitor all lsf jobs that are completed through log irrespective of success or exitted
wait_until_all_jobs_completed() {
    logJobs=$1

    total_jobs=$(cat $logJobs | wc -l)
    echo "total jobs submitted - $total_jobs"

    ## initialise completed and exited jobs
    completed=0
    exited=0

    while true; do

        finished="$(($completed + $exited))"
        echo "jobs finished - $finished"

        if [ $finished -eq $total_jobs ]; then
            break
        fi

        ## wait for a while
        sleep 60

        ## count
        completed=$(cat $logJobs | xargs -n 100 grep -l 'Successfully completed.' | wc -l)
        exited=$(cat $logJobs | xargs -n 100 grep -l 'Exited with' | wc -l)
    done

    echo "lsf jobs completed - $finished"

    if [ $exited -gt 0 ]; then
        echo "lsf jobs exited - $exited"
        exit 1
    fi
}

# Determine if experiment is microarray, rna-seq or proteomics
get_exp_technology() {

    expAcc=$1
    # Unset $baselineOrDifferential from last time
    technology=

    if [[ $expAcc == *"PROT"* ]]; then
        technology="proteomics"
    else
        # Does this experiment have a directory under the baseline or differential
        # processing space yet?
        ls ${ATLAS_PROD}/analysis/differential/microarray/experiments/${expAcc} 2>/dev/null 1>/dev/null
        foundInMicroarray=$?
        if [ $foundInMicroarray -eq 0 ]; then
            technology="microarray"
        else
            ls ${ATLAS_PROD}/analysis/*/rna-seq/experiments/${expAcc} 2>/dev/null 1>/dev/null
            foundInRna_seq=$?
            if [ $foundInRna_seq -eq 0 ]; then
                technology="rna-seq"
            fi
        fi
    fi

    echo "$technology"
}

# Determine if experiment is baseline or differential
get_baseline_or_differential() {

    expAcc=$1
    # Unset $baselineOrDifferential from last time
    baselineOrDifferential=

    # Does this experiment have a directory under the baseline or differential
    # processing space yet?
    ls ${ATLAS_PROD}/analysis/differential/*/experiments/${expAcc} 2>/dev/null 1>/dev/null
    foundInDifferential=$?
    if [ $foundInDifferential -eq 0 ]; then
        baselineOrDifferential="differential"
    else
        ls ${ATLAS_PROD}/analysis/baseline/rna-seq/experiments/${expAcc} 2>/dev/null 1>/dev/null
        foundInBaseline=$?
        if [ $foundInBaseline -eq 0 ]; then
            baselineOrDifferential="baseline"
        fi
    fi

    echo "$baselineOrDifferential"
}

# Get a directory for a given experiment
get_experiment_target_dir() {
    expAcc=$1

    baselineOrDifferential=$(get_baseline_or_differential $expAcc)
    microarrayORrna_seq=$(get_microarray_or_rna_seq $expAcc)

    expTargetDir=${ATLAS_PROD}/analysis/$baselineOrDifferential/$microarrayORrna_seq/experiments/${expAcc}
    echo "$expTargetDir"
}

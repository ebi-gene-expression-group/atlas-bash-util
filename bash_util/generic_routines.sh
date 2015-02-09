#!/bin/bash

IFS="
"

# Returns prod or test, depending on the Atlas environment in which the script calling it is running
# It is assuming that all atlasinstall_<env>s are under /nfs/ma/home/atlas3-production/sw (it will fail otherwise)
atlas_env() {
    scriptDir=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
    atlasInstallSubDir=$(echo $scriptDir | awk -F"/" '{print $7}')
    echo $atlasInstallSubDir | awk -F"_" '{print $2}'
}

is_multispecies_experiment() {
    expAcc=$1
    echo "E-GEOD-41338 E-GEOD-30352" | grep $expAcc > /dev/null
    return $?
}

# This procedure returns 0 if process $arg is running; otherwise it returns 1
lsf_process_running() {
    arg=$1
    bjobs -l | tr -d "\n" | perl -p -e 's/\s+/ /g' | perl -p -e 's/Job/\nJob/g' | grep 'Job Priority' | grep "$arg" > /dev/null
    return $?
}

function capitalize_first_letter {
    arg=$1
    echo -n $arg | sed 's/\(.\).*/\1/' | tr "[:lower:]" "[:upper:]" | tr -d "\n"; echo -n $arg | sed 's/.\(.*\)/\1/'
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
    for l in $(cat $ATLAS_PROD/sw/atlasinstall_prod/atlasprod/experiment_metadata/$fixesFile | sed 's|[[:space:]]*$||g');
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
	toBeReplaced=`echo $l | awk -F"\t" '{print $2}' | sed 's/[^-A-Za-z0-9_ ]/\\\&/g'`
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

get_dbpass() {
    dbUser=$1
    if [ -e "${ATLAS_PROD}/sw/${dbUser}" ]; then
	cat ${ATLAS_PROD}/sw/${dbUser}
    else
	echo "ERROR: Failed to retrieve DB password" >&2
	return 1
    fi
}

# Fetch properties for ensemblProperty1 and (optionally) ensemblProperty2 from the Ensembl biomart identified by url, serverVirtualSchema and datasetName)
# Called in fetchAllEnsemblMapings.sh
function fetchProperties {
    url=$1
    serverVirtualSchema=$2
    datasetName=$3
    ensemblProperty1=$4
    ensemblProperty2=$5
    chromosomeName=$6

    if [[ -z "$url" || -z "$serverVirtualSchema" || -z "$datasetName" || -z "$ensemblProperty1" ]]; then
	echo "ERROR: Usage: url serverVirtualSchema datasetName ensemblProperty1 (ensemblProperty2)" >&2
	exit 1
    fi

    if [ ! -z "$chromosomeName" ]; then
	chromosomeFilter="<Filter name = \"chromosome_name\" value = \"${chromosomeName}\"/>"
    else
	chromosomeFilter=""
    fi

    query="query=<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE Query><Query virtualSchemaName = \"${serverVirtualSchema}\" formatter = \"TSV\" header = \"1\" uniqueRows = \"1\" count = \"0\" ><Dataset name = \"${datasetName}\" interface = \"default\" >${chromosomeFilter}<Attribute name = \"${ensemblProperty1}\" />"
    if [ ! -z "$ensemblProperty2" ]; then
	query="$query<Attribute name = \"${ensemblProperty2}\" />"
    fi
    # In some cases a line '^\t$ensemblProperty2' is being returned (with $ensemblProperty1 missing), e.g. in the following call:
    #curl -s -G -X GET --data-urlencode 'query=<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE Query><Query virtualSchemaName = "metazoa_mart_19" formatter = "TSV" header = "1" uniqueRows = "1" count = "0" ><Dataset name = "agambiae_eg_gene" interface = "default" >${chromosomeFilter} <Attribute name = "ensembl_peptide_id" /><Attribute name = "description" /></Dataset></Query>' "http://metazoa.ensembl.org/biomart/martservice" | grep AGAP005154
    # Until this is clarified, skip such lines with grep -vP '^\t'
    curl -s -G -X GET --data-urlencode "$query</Dataset></Query>" "$url" | tail -n +2 | sort -k 1,1 | grep -vP '^\t'
    # echo "curl -s -G -X GET --data-urlencode \"$query</Dataset></Query>\" \"$url\" | tail -n +2 | sort -k 1,1" > /dev/stderr
}

# Called in fetchAllEnsemblMapings.sh
function fetchGeneSynonyms {
    annSrc=$1
    mySqlDbHost=$2
    mySqlDbPort=$3
    mySqlDbName=$4
    softwareVersion=$5
    latestReleaseDB=`mysql -s -u anonymous -h "$mySqlDbHost" -P "$mySqlDbPort" -e "SHOW DATABASES LIKE '${mySqlDbName}_core_${softwareVersion}%'" | grep "^${mySqlDbName}_core_${softwareVersion}"`
    if [ -z "$latestReleaseDB" ]; then
	echo "ERROR: for $annSrc: Failed to retrieve then database name for release number: $softwareVersion" >&2
	exit 1
    else 
        mysql -s -u anonymous -h $mySqlDbHost -P $mySqlDbPort -e "use ${latestReleaseDB}; SELECT DISTINCT gene.stable_id, external_synonym.synonym FROM gene, xref, external_synonym WHERE gene.display_xref_id = xref.xref_id AND external_synonym.xref_id = xref.xref_id ORDER BY gene.stable_id" | sort -k 1,1
    fi 
}
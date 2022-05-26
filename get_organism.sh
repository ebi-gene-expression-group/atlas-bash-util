#!/bin/bash
# Gets the organism for an experiment
# Usage: get_organism.sh <path to exp>
# If condensed-sdrf.tsv in $ATLAS_EXPS is present, use that, otherwise revisit ArrayExpress/Magetab
# For microarray experiments an array for different species will rarely be used so we get organism from array design file name

set -euo pipefail
scriptDir=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source $scriptDir/generic_routines.sh
projectRoot=${scriptDir}/..

# Call a Perl script that models AE import
# Gets the idf file from magetab, reads the location of the corresponding sdrf, parses whole sdrf
# This takes a long time and for already imported experiments isn't really needed
# Pros:
# - validates there is a correct organism to be found, and errors out if there isn't
# Cons:
# - for old experiments, sometimes the AE data isn't what's considered okay now and the routine fails not letting us redo GSEA after Ensembl update
use_perl_code_to_get_organism(){
	experimentAccession=$1
	configurationXml=$2
	$projectRoot/db/scripts/get_experiment_info.pl --experiment "$experimentAccession" --xmlfile "$configurationXml" --organism  | to_ensembl_species_lowercase
}

if [ $# -lt 1 ]; then
        echo "Usage: $0 expPath "
        echo "e.g. $0 ${ATLAS_PROD}/analysis/baseline/rna-seq/experiments/E-MTAB-513"
        exit 1;
fi

expPath=$1
expAcc=$(basename ${expPath})

if [ -e "$ATLAS_EXPS/$expAcc/$expAcc.condensed-sdrf.tsv" ]; then
	get_organism_from_condensed_sdrf "$ATLAS_EXPS/$expAcc/$expAcc.condensed-sdrf.tsv"
elif [ -e "$expPath/$expAcc-configuration.xml" ]; then
	use_perl_code_to_get_organism "$expAcc" "$expPath/$expAcc-configuration.xml"
else
	>&2 echo "Can't retrieve organism: neither $ATLAS_EXPS/$expAcc/$expAcc.condensed-sdrf.tsv nor $expPath/$expAcc-configuration.xml not found "
	exit 1
fi

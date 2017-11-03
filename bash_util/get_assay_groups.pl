#!/usr/bin/env perl
#
# In: path to a configuration file e.g. $ATLAS_EXPS/E-MTAB-513/E-MTAB-513-configuration.xml
# Out: <assay group><tab><assay>

my ($path) = @_;

die "Usage: $0 <path to configuration.xml>" unless $path;

my $experimentConfig = Atlas::AtlasConfig::Reader::parseAtlasConfig($path);

for my $analytics ( @{ $experiment_config->get_atlas_analytics } ) {
	for my $assay_group ( @{ $analytics->get_atlas_assay_groups } ) {
		my $assay_group_id = $assay_group -> get_assay_group_id;
		for my $biological_replicate ( @{ $assay_group->get_biological_replicates } ) {
			for my $assay (@{ $biological_replicate->get_assays } ) {
				my $assay_id = $assay -> get_name;
				my $replicate_id = $biological_replicate->get_technical_replicate_group // $assay_id;
				print "$assay_group_id\t$replicate_id\t$assay_id\n";
			}
		}
	}
}

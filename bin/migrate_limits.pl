#!/usr/bin/perl

use strict;
use warnings;

use YAML::XS;
use BOM::Platform::Runtime;
use JSON qw(from_json to_json);

my $limits = YAML::XS::LoadFile('limits.yml');

my $current = from_json(BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles);
foreach my $id (keys %$limits) {
    my $ref = $limits->{$id};
    foreach my $market (keys %$ref) {
        my $comment = $ref->{$market}{all}{comment} . ". [played on $market]";
        my $updated_on = $ref->{$market}{all}{modified};
        my $updated_by = $ref->{$market}{all}{staff};
        $current->{$id}->{reason} = $comment;
        $current->{$id}->{updated_on} = $updated_on;
        $current->{$id}->{updated_by} = $updated_by;
    }
}
BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles(to_json($current));
BOM::Platform::Runtime->instance->app_config->save_dynamic;

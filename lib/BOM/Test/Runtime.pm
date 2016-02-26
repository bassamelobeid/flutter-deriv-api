package BOM::Test::Runtime;

=head1 NAME

BOM::Test::Runtime

=head1 DESCRIPTION

Used to setup a runtime for testing, without depending on our chronicle settings which come from production. It will instead load the settings from 't/data/app_settings.yml' file and hence all settings common across test cases can be set there.

If you want to setup individual AppConfig stuff for your test alone you can directly set the value for your config, like
BOM::Platform::Runtime->instance->app_config->system->SETTING_NAME('XXXX');
... # Run your tests.


=head1 SYNOPSIS

    use BOM::Test::Runtime qw(:normal);

=cut

use 5.010;
use strict;
use warnings;

use BOM::Platform::Runtime;
use BOM::Test::Runtime::MockDS;
use YAML::CacheLoader;

sub _normal {
    my $app_settings = '/home/git/regentmarkets/bom-test/data/app_settings.yml';
    if (!-f $app_settings) {
        $app_settings = '../' . $app_settings;
    }
    my $hash = YAML::CacheLoader::LoadFile($app_settings);
    $hash->{_rev} = 'a';

    my $hdata = BOM::Test::Runtime::MockDS->new(data => $hash);

    my $ac = BOM::Platform::Runtime::AppConfig->new(db => $hdata);

    return BOM::Platform::Runtime->instance(BOM::Platform::Runtime->new(app_config => $ac));
}

sub import {
    my ($class, $init) = @_;

    if ($init and $init eq ':normal') {
        return _normal();
    }

    return;
}

1;

#!/usr/bin/env perl

package BOM::Riskd;

use Moose;
with 'App::Base::Daemon';

use lib qw(/home/git/regentmarkets/bom-backoffice/lib/);
use Time::Duration::Concise::Localize;
use BOM::Platform::Runtime;

use BOM::RiskReporting::Dashboard;
use BOM::RiskReporting::MarkedToModel;

has rest_period => (
    is         => 'ro',
    isa        => 'Time::Duration::Concise::Localize',
    lazy_build => 1,
);

sub _build_rest_period {
    return Time::Duration::Concise::Localize->new(interval => '37s');
}

sub documentation {
    return qq/This daemon generates live risk reports./;
}

sub daemon_run {
    my $self = shift;

    die 'riskd only to run on master servers.'
        if (not BOM::Platform::Runtime->instance->hosts->localhost->has_role('master_live_server'));

    while (1) {
        say STDERR 'Starting marked-to-model calculation.';
        BOM::RiskReporting::MarkedToModel->new(run_by => $self)->generate;
        say STDERR 'Completed marked-to-model calculation.';
        $self->rest;
        say STDERR 'Starting risk report generation.';
        BOM::RiskReporting::Dashboard->new(run_by => $self)->generate;
        say STDERR 'Completed risk report generation.';
        $self->rest;
    }

    return 255;
}

sub rest {
    my $self     = shift;
    my $how_long = $self->rest_period;

    say STDERR 'Checking for config changes.';
    BOM::Platform::Runtime->instance->app_config->check_for_update;    # We're a long-running process. See if config changed underneath us.
    say STDERR 'Resting for ' . $how_long->as_string . '...';
    sleep($how_long->seconds);

    return;
}

sub handle_shutdown {
    my $self = shift;
    say STDERR 'Shutting down.';
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

package main;
use strict;

exit BOM::Riskd->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;

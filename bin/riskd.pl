#!/etc/rmg/bin/perl

package BOM::Riskd;

use Moose;
with 'App::Base::Daemon';

use lib qw(/home/git/regentmarkets/bom-backoffice/lib/);
use Time::Duration::Concise::Localize;
use BOM::Platform::Runtime;

use BOM::RiskReporting::Dashboard;
use BOM::RiskReporting::MarkedToModel;
no indirect;
use Try::Tiny;

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

    while (1) {
        try {
            BOM::RiskReporting::MarkedToModel->new->generate;
        }
        catch {
            warn "Failure in BOM::RiskReporting::MarkedToModel: $_\n";
        };
        $self->rest;
        try {
            BOM::RiskReporting::Dashboard->new->generate;
        }
        catch {
            warn "Failure in BOM::RiskReporting::Dashboard: $_\n";
        };
        $self->rest;
    }

    return 255;
}

sub rest {
    my $self     = shift;
    my $how_long = $self->rest_period;

    BOM::Platform::Runtime->instance->app_config->check_for_update;    # We're a long-running process. See if config changed underneath us.
    sleep($how_long->seconds);

    return;
}

sub handle_shutdown {
    my $self = shift;
    warn('Shutting down.');
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

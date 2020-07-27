package BOM::Backoffice::Script::Riskd;

use Moose;
no indirect;

use Time::Duration::Concise::Localize;
use BOM::Config::Runtime;

use BOM::RiskReporting::Dashboard;
use BOM::RiskReporting::MarkedToModel;
use DataDog::DogStatsd::Helper qw(stats_gauge);
use Syntax::Keyword::Try;

use constant INTERVAL => 37;

has rest_period => (
    is         => 'ro',
    isa        => 'Time::Duration::Concise::Localize',
    lazy_build => 1,
);

sub _build_rest_period {
    return Time::Duration::Concise::Localize->new(interval => INTERVAL . 's');
}

has last_run => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_last_run {
    return +{
        mtm       => time - 2 * INTERVAL,    # we assume there was a previous successful run at the beginning, to prevent sending 0 as elapsed time
        dashboard => time - INTERVAL,
    };
}

sub run {
    my $self = shift;
    my (%msgs, %old_msgs);
    local $SIG{__WARN__} = sub {
        my $msg = shift;
        if (!$old_msgs{$msg} && !$msgs{$msg}) {
            CORE::warn "$msg\n";
        }
        $msgs{$msg} = 1;
    };

    while (1) {
        %old_msgs = %msgs;
        %msgs     = ();
        try {
            BOM::RiskReporting::MarkedToModel->new->generate;
            $self->send_log('MTM');
        }
        catch {
            warn "Failure in BOM::RiskReporting::MarkedToModel: $@\n";
        }
        $self->rest;

        try {
            BOM::RiskReporting::Dashboard->new->generate;
            $self->send_log('Dashboard');
        }
        catch {
            warn "Failure in BOM::RiskReporting::Dashboard: $@\n";
        }

        $self->rest;
    }

    return 255;
}

=head1 METHODS

=head2 send_log

Sends the elapsed time since the previous successful run of each process to DataDog
and updates C<last_run> for the next round.

=cut

sub send_log {
    my ($self, $type) = @_;
    my $last_run = $self->last_run;
    my $now      = time;

    stats_gauge('risk_reporting.run', $now - $last_run->{lc $type}, {tags => ["tag:$type"]});
    $last_run->{lc $type} = $now;

    return;
}

=head2 rest

Checks for possible config updates and delays the next process run for 'INTERVAL' seconds.

=cut

sub rest {
    my $self     = shift;
    my $how_long = $self->rest_period;

    BOM::Config::Runtime->instance->app_config->check_for_update;    # We're a long-running process. See if config changed underneath us.
    sleep($how_long->seconds);

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

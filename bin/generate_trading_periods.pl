#!/etc/rmg/bin/perl -w
package BOM::Product::PredefinedOfferings;

use Moose;
with 'App::Base::Daemon';

use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods next_generation_epoch);
use Parallel::ForkManager;
use Time::HiRes;
use Date::Utility;

sub documentation {
    return qq/This daemon generates predefined trading periods for selected underlying symbols at XX:45 and XX:00./;
}

sub daemon_run {
    my $self = shift;

    my @selected_symbols = BOM::Product::Contract::PredefinedParameters::supported_symbols;
    my $fm               = Parallel::ForkManager->new(scalar(@selected_symbols));

    while (1) {
        foreach my $symbol (@selected_symbols) {
            $fm->start and next;
            generate_trading_periods($symbol);
            $fm->finish;
        }
        $fm->wait_all_children;

        my $next = next_generation_epoch(Date::Utility->new);
        my $sleep_interval = $next - Time::HiRes::time;

        Time::HiRes::sleep($sleep_interval);
    }

    $self->_daemon_run;
}

sub handle_shutdown {
    my $self = shift;
    warn('Shutting down');
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

package main;
use strict;

exit BOM::Product::PredefinedOfferings->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;

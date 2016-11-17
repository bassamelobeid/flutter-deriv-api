#!/etc/rmg/bin/perl -w
package BOM::Product::PredefinedOfferings;

use Moose;
with 'App::Base::Daemon';

use BOM::Product::Contract::PredefinedParameters qw(generate_predefined_offerings);
use Time::HiRes;
use Date::Utility;

sub documentation {
    return qq/This daemon generates predefined offerings for selected underlying symbols at the 45th minute of every hour./;
}

sub daemon_run {
    my $self = shift;

    my @selected_symbols = qw(frxUSDJPY);

    while (1) {
        foreach my $symbol (@selected_symbols) {
            generate_predefined_offerings($symbol);
        }

        my $now            = Date::Utility->new;
        my $current_minute = $now->minute;
        my $next_gen_epoch =
            ($current_minute < 45)
            ? Date::Utility->new->today->plus_time_interval($now->hour . 'h45m')->epoch
            : Date::Utility->new->today->plus_time_interval($now->hour + 1 . 'h')->epoch;
        my $sleep_interval = $next_gen_epoch - Time::HiRes::time;
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

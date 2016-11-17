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

        # $sleep_interval is the remaining seconds until the forthcoming HH:45 (if current minute is < 45) or the forthcoming HH:)) (if the current time is >= 45)

        # So $sleep_interval is explained in minutes for comfort :
        # hh:00 => $sleep_interval = 45 min
        # hh:03 => $sleep_interval = 42 min
        # hh:29 => $sleep_interval = 16 min
        # hh:44 => $sleep_interval = 1 min
        # hh:45 => $sleep_interval = 15 min
        # hh:54 => $sleep_interval = 6 min
        # hh:59 => $sleep_interval = 1 min
        # hh:00 => $sleep_interval = 45 min

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

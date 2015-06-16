#!/usr/bin/perl

package BOM::System::Script::CheckHolidayFiles;

=head1 NAME

BOM::System::Script::CheckHolidaysFIles

=head1 DESCRIPTION

To check if the holidays file is outdated

=cut

use Moose;

use BOM::Platform::Runtime;
with 'App::Base::Script';
with 'BOM::Utility::Logging';
use BOM::Market::Underlying;
use BOM::Market::UnderlyingDB;
use Date::Utility;
use Mail::Sender;

sub script_run {
    my $self = shift;

    my @all = ('forex', 'indices', 'commodities');
    my @underlying_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market       => \@all,
        contract_category => 'ANY',
    );
    my @exchanges;
    my $today_since_epoch  = Date::Utility::today->days_since_epoch;
    my @outdated_exchanges = ('OUTDATED EXCHANGES');
    my @updated_exchanges  = ('UPDATED EXCHANGES');

    foreach my $symbol (@underlying_symbols) {
        my $exchange                      = BOM::Market::Underlying->new($symbol)->exchange;
        my @holidays                      = sort keys %{$exchange->{holidays}};
        my $last_holiday_date_since_epoch = pop @holidays;
        if ($last_holiday_date_since_epoch > $today_since_epoch and ($exchange->{offered} and $exchange->{offered} eq 'yes')) {
            push @outdated_exchanges, $exchange->symbol;
        } else {
            push @updated_exchanges, $exchange->symbol;
        }
    }

    my $body = "Holidays for the following exchange need update .Please update the relevant holiday file -- last holiday listed is before today.\n";
    $body .= join "\n", (@updated_exchanges, @outdated_exchanges);
    $body .= "NOTE: Please make sure you update the currency holidays too\n";

    if (scalar @outdated_exchanges > 0) {

        my $sender = Mail::Sender->new({
            smtp => 'localhost',
            from => 'Exchange notifications <exchange@binary.com>',
            to      => 'Quants <x-quants-alert@binary.com>',
            subject => "Exchanges holiday file needs update. "
        });
        $sender->MailMsg({msg => $body});
    }
    return 0;
}

sub documentation {
    return qq{
This script is to check and make sure holidays file is up to date
    };
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;
use strict;
exit BOM::System::Script::CheckHolidayFiles->new->run;


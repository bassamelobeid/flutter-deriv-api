#!/usr/bin/perl
package BOM::System::Script::UpdateCorpActions;

use Try::Tiny;
use List::MoreUtils qw(pairwise);

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use Bloomberg::FileDownloader;
use Bloomberg::CorporateAction;
use BOM::MarketData::Fetcher::CorporateAction;
use Quant::Framework::CorporateAction;
use BOM::Platform::Runtime;
use Mail::Sender;
use DataDog::DogStatsd::Helper qw(stats_gauge);

sub documentation {
    return 'a script that updates corporates actions retrieved from Bloomberg';
}

sub script_run {
    my $self = shift;

    my @files = Bloomberg::FileDownloader->new->grab_files({file_type => 'corporate_actions'});
    my $parser = Bloomberg::CorporateAction->new();
    my %report;
    foreach my $file (@files) {
        my %grouped_actions = $parser->process_data($file);
        foreach my $symbol (keys %grouped_actions) {
            my $corp = Quant::Framework::CorporateAction->new(
                symbol           => $symbol,
                actions          => $grouped_actions{$symbol},
                chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::System::Chronicle::get_chronicle_writer());

            try {
                $corp->save;
                $report{$symbol}->{success}   = 1;
                $report{$symbol}->{cancelled} = scalar(keys %{$corp->cancelled_actions});
                $report{$symbol}->{new}       = scalar(keys %{$corp->new_actions});
            }
            catch {
                $report{$symbol}->{success} = 0;
                $report{$symbol}->{reason}  = $_;
            };
        }
    }

    my $dm        = BOM::MarketData::Fetcher::CorporateAction->new;
    my $full_list = $dm->get_underlyings_with_corporate_action;
    my %disabled_list;

    foreach my $symbol (keys %$full_list) {
        my $records = $full_list->{$symbol};
        my @string;
        foreach my $id (keys %$records) {
            if ($records->{$id}->{suspend_trading}) {
                my $comment = $records->{$id}->{comment} || 'none';
                my $string = $records->{$id}->{description} . ' [' . $comment . '] ';
                push @string, $string;
            }
        }
        $disabled_list{$symbol}->{disabled} = $symbol . '. Reason: ' . join ',', @string if @string;
    }

    _update_disabled_symbol_list(\%disabled_list);

    if (%report) {
        my $successes = scalar grep { $report{$_}->{success} } keys %report;
        my $failures  = scalar grep { not $report{$_}->{success} } keys %report;

        stats_gauge('corporate_action_updates', $successes);
    }

    $self->return_value();
}

sub _update_disabled_symbol_list {
    my $list     = shift;
    my @new_list = keys %$list;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions(\@new_list);
    BOM::Platform::Runtime->instance->app_config->save_dynamic;

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

package main;
use strict;

exit BOM::System::Script::UpdateCorpActions->new->run;

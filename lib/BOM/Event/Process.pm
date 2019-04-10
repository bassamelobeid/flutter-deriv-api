package BOM::Event::Process;

use strict;
use warnings;

no indirect;

use DataDog::DogStatsd::Helper qw(stats_inc);
use JSON::MaybeUTF8 qw(:v1);
use Try::Tiny;

use BOM::Event::Actions::Client;
use BOM::Event::Actions::Customerio;
use BOM::Event::Actions::CustomerStatement;
use BOM::Event::Actions::MT5;
use BOM::Event::Actions::Client;

=head1 NAME

BOM::Event::Process - Process events

=head1 SYNOPSIS

    BOM::Event::Process::process($event_to_be_processed)

=head1 DESCRIPTION

This class responsibility is to process events. It has action to method mapping.
Based on type of event its associated method is invoked.

=cut

my $action_mapping = {
    register_details         => \&BOM::Event::Actions::Customerio::register_details,
    email_consent            => \&BOM::Event::Actions::Customerio::email_consent,
    email_statement          => \&BOM::Event::Actions::CustomerStatement::email_statement,
    sync_user_to_MT5         => \&BOM::Event::Actions::MT5::sync_info,
    store_mt5_transaction    => \&BOM::Event::Actions::MT5::redis_record_mt5_transfer,
    new_financial_mt5_signup => \&BOM::Event::Actions::MT5::new_financial_mt5_signup,
    anonymize_client         => \&BOM::Event::Actions::Anonymization::start,
    send_mt5_disable_csv     => \&BOM::Event::Actions::MT5::send_mt5_disable_csv,
    document_upload          => \&BOM::Event::Actions::Client::document_upload,
    ready_for_authentication => \&BOM::Event::Actions::Client::ready_for_authentication,
    client_verification      => \&BOM::Event::Actions::Client::client_verification,
    account_closure          => \&BOM::Event::Actions::Client::account_closure
};

=head1 METHODS

=head2 get_action_mappings

Returns available action mappings

=cut

sub get_action_mappings {
    return $action_mapping;
}

=head2 process

Process event passed by invoking corresponding method from action mapping

=head3 Required parameters

=over 4

=item * event_to_be_processed : emitted event ( {type => action, details => {}}, $queue_name )

=back

=cut

sub process {
    # event is of form { type => action, details => {} }

    my $event_to_be_processed = shift;
    my $queue_name            = shift;

    my $event_type = $event_to_be_processed->{type} // '';

    # don't process if type is not supported as of now
    unless (exists get_action_mappings()->{$event_type}) {
        warn 'failed to map to the correct function';
        return undef;
    }

    unless (exists $event_to_be_processed->{details}) {
        warn 'event does not contain any details';
        return undef;
    }

    my $response = 0;
    try {
        $response = get_action_mappings()->{$event_type}->($event_to_be_processed->{details});
        stats_inc(lc "$queue_name.processed.success");
    }
    catch {
        stats_inc(lc "$queue_name.processed.failure");
    };

    return $response;
}

1;

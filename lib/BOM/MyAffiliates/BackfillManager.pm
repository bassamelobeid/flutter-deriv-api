package BOM::MyAffiliates::BackfillManager;

=head1 NAME

BOM::MyAffiliates::BackfillManager

=head1 DESCRIPTION

This class manages the back-filling of partial affiliate info
held in client details or in our client affiliate exposures.

=head1 SYNOPSIS

    my $backfill_manager = BOM::MyAffiliates::BackfillManager->new;
    $backfill_manager->backfill_client_info;

=cut

use strict;
use warnings;
use Moose;
use Date::Utility;
use BOM::Database::AutoGenerated::Rose::ClientAffiliateExposure;
use BOM::Platform::Runtime;
use BOM::Platform::Client;
use BOM::MyAffiliates;
use Try::Tiny;
use BOM::Database::DataMapper::CollectorReporting;

has '_available_broker_codes' => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub {
        my @codes = BOM::Platform::Runtime->instance->broker_codes->all_codes;
        # do not process FOG or any virtual broker code
        @codes = grep { $_ !~ /^(?:FOG|VRT)/ } @codes;

        return \@codes;
    },
);

has '_myaffiliates' => (
    is         => 'ro',
    isa        => 'BOM::MyAffiliates',
    lazy_build => 1
);
sub _build__myaffiliates { return BOM::MyAffiliates->new }

=head1 METHODS

=head2 backfill_promo_codes

=cut

sub backfill_promo_codes {
    my $self = shift;
    my @report;

    foreach my $broker (@{$self->_available_broker_codes}) {
        my @clients = BOM::Platform::Client->by_promo_code(
            broker_code             => $broker,
            checked_in_myaffiliates => 'f'
        );

        foreach my $client (@clients) {
            try {
                push @report, $self->_process_client_with_promo_code($client);
            }
            catch {
                push @report, $client->loginid . ': Died when processing with error [' . $_ . ']';
            };
        }
    }

    @report = ('No clients processed.') if not @report;

    return @report;
}

=head2 is_backfill_pending($date)

Checks if there is any client whose promocode still needs to be
backfilled into the MyAffiliates platform up to the given date

$date should be either a Date::Utility object or a string parseable by it :-)

=cut

sub is_backfill_pending {
    my ($self, $date_str) = @_;
    return scalar $self->clients_pending_backfill($date_str);
}

=head2 clients_pending_backfill($date)

Returns an array of clients whose promocodes still needs to be
backfilled into the MyAffiliates platform for the given date

$date should be either a Date::Utility object or a string parseable by it :-)

=cut

sub clients_pending_backfill {
    my ($self, $date) = @_;
    $date = Date::Utility->new($date)->truncate_to_day;

    return map {
        grep { $date->is_same_as(Date::Utility->new($_->date_joined)->truncate_to_day) } BOM::Platform::Client->by_promo_code(
            broker_code             => $_,
            checked_in_myaffiliates => 'f'
            )
    } @{$self->_available_broker_codes};
}

#
# Does the actual processing of a client (that has a promo code).
# Any exceptions thrown will be caught by the calling code.
#
sub _process_client_with_promo_code {
    my ($self, $client) = @_;
    my $report_line;
    my $promo_code_myaffiliates_id = $self->_myaffiliates->get_myaffiliates_id_for_promo_code($client->promo_code);

    if ($promo_code_myaffiliates_id) {
        # Those are the rules for processing promocodes additions and replacements:
        # sub_promo = promocode from a subordinate affiliate
        # promo     = promocode from a regular affiliate
        #
        #        status    | uses promocode |  token from? |        summary
        #                                                  | replace current token?
        #   -funded -token |     promo      |   promo      |          Y
        #   -funded -token |     sub_promo  |   sub_promo  |          Y
        #   -funded +token |     promo      |   promo      |          Y
        #   -funded +token |     sub_promo  |   token      |          N
        #   +funded -token |     promo      |  -token      |          N
        #   +funded -token |     sub_promo  |  -token      |          N
        #   +funded +token |     promo      |   token      |          N
        #   +funded +token |     sub_promo  |   token      |          N
        #
        #   ** There is also some promocodes which require funding and it might be the
        #   case that the client funds before calling CS to use the promocode.
        #   In that situation the account will be considered as +funded on the system
        #   even tho the funding was part of the promocode deal.  An acceptable approximation
        #   would be to consider the account -funded if the first funding happened within 3
        #   days of the promocode usage.
        my $existing_myaffiliates_id;
        if (my $existing_token = $client->myaffiliates_token) {
            $existing_myaffiliates_id = $self->_myaffiliates->get_affiliate_id_from_token($existing_token);
        }

        if ($client->has_funded) {
            $report_line = $client->loginid . ': Account already funded, not updating token';
        } elsif (not $existing_myaffiliates_id) {
            my $promo_code_token = $self->_myaffiliates->get_token({affiliate_id => $promo_code_myaffiliates_id});
            $client->myaffiliates_token($promo_code_token);
            $client->myaffiliates_token_registered(0);
            $report_line = $client->loginid . ': had no token and was not funded. Usage of promocode added token ' . $promo_code_token;
        } elsif ($existing_myaffiliates_id != $promo_code_myaffiliates_id
            and not $self->_myaffiliates->is_subordinate_affiliate($promo_code_myaffiliates_id))
        {
            my $promo_code_token = $self->_myaffiliates->get_token({affiliate_id => $promo_code_myaffiliates_id});
            $client->myaffiliates_token($promo_code_token);
            $client->myaffiliates_token_registered(0);
            $report_line =
                  $client->loginid
                . ': had token but was not funded. Usage of promocode '
                . $client->promo_code
                . ' replaced token with '
                . $promo_code_token;
        } else {
            $report_line = $client->loginid . ': Already tracked by token, so not updating with subordinate promocode token.';
        }
    } else {
        $report_line = $client->loginid . ': promo code is not linked to an affiliate.';
    }
    $client->promo_code_checked_in_myaffiliates(1);
    $client->save;

    return $report_line;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

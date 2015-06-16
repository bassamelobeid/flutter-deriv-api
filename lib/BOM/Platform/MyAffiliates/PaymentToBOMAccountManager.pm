package BOM::Platform::MyAffiliates::PaymentToBOMAccountManager;

=head1 NAME

BOM::Platform::MyAffiliates::PaymentToBOMAccountManager

=head1 SYNOPSIS

    my $manager = BOM::Platform::MyAffiliates::PaymentToBOMAccountManager->new(from => $from_date, to => $to_date);

=cut

use strict;
use warnings;
use Moose;
use Carp;
use IO::File;
use Data::Dumper qw( Dumper );
use Text::CSV;
use Text::Trim;
use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use BOM::Utility::CurrencyConverter qw(amount_from_to_currency);
use BOM::Platform::Runtime;
use BOM::Platform::Client;
use BOM::Platform::MyAffiliates;
use Try::Tiny;

=head1 ATTRIBUTES

=head2 from, to

Deal with transactions between these From and To Date::Utilitys. Required.

=cut

has ['from', 'to'] => (
    is       => 'ro',
    isa      => 'Date::Utility',
    required => 1,
);

=head1 METHODS

=head2 get_csv_file_locs

Returns an array of paths to files on the server where the payment CSV files
are located. Can then be passed to our mailing code for emailing out etc.

Also returns paths to files containing error reports.

=cut

sub get_csv_file_locs {
    my $self = shift;

    my $api = BOM::Platform::MyAffiliates->new;

    my @BOM_account_transactions = $api->fetch_BOM_account_transactions(
        'FROM_DATE' => $self->from->date_yyyymmdd,
        'TO_DATE'   => $self->to->date_yyyymmdd,
    );

    my $transactions_for_server = _split_transactions_by_destination_dealing_server(@BOM_account_transactions);

    return $self->_write_csv_files($transactions_for_server);
}

sub _split_transactions_by_destination_dealing_server {
    my @BOM_account_transactions = @_;
    my $transactions_for_server  = {};

    foreach my $transaction (@BOM_account_transactions) {
        my $BOM_account = _get_BOM_loginid_from_transaction($transaction);

        # Ok, the following is not a server name. I basically want to hold onto transactions
        # that we can't process, so that I can report them as erroneous later. The naming
        # doesn't quite fit the underlying concept, but works.
        my $server = 'LOGIN_EXTRACTION_ERRORS';
        if ($BOM_account =~ /^([A-Z]+)\d+$/) {
            my $broker = $1;
            $server = BOM::Platform::Runtime->instance->broker_codes->dealing_server_for($broker)->canonical_name;
        }

        if (not ref $transactions_for_server->{$server}) {
            $transactions_for_server->{$server} = [];
        }

        push @{$transactions_for_server->{$server}}, $transaction;
    }

    return $transactions_for_server;
}

sub _get_BOM_loginid_from_transaction {
    my $transaction = shift;

    my $details = $transaction->{USER_PAYMENT_TYPE}->{PAYMENT_DETAILS}->{DETAIL};

    if (ref($details) eq 'ARRAY') {
        foreach my $detail (@{$details}) {
            if ($detail->{DETAIL_NAME} and $detail->{DETAIL_NAME} eq 'bom_id') {
                return $detail->{DETAIL_VALUE};
            }
        }
    }
    return;
}

sub _write_csv_files {
    my ($self, $transactions_for_server) = @_;
    my @csv_file_locs;
    my @parse_errors;

    local $\ = "\n";    # because my print statements do not punch a record separator

    foreach my $server (keys %{$transactions_for_server}) {
        my $file_loc        = $self->_get_file_loc($server);
        my $transaction_set = $transactions_for_server->{$server};

        open my $fh, '>', $file_loc or die "Cannot open $file_loc: $!";

        if ($server eq 'LOGIN_EXTRACTION_ERRORS') {
            print $fh Dumper($transaction_set);
            close $fh;
        } else {
            foreach my $transaction (@{$transaction_set}) {
                try {
                    print $fh _get_csv_line_from_transaction($transaction);
                }
                catch {
                    push @parse_errors, $_;
                };
            }
            close $fh;
        }
        push @csv_file_locs, $file_loc;
    }

    if (scalar @parse_errors) {
        my $parse_errors_file_loc = $self->_get_file_loc('PARSE_ERRORS');

        open my $fh, '>', $parse_errors_file_loc or die "Cannot open $parse_errors_file_loc: $!";

        map { print $fh $_ } @parse_errors;
        close $fh;

        push @csv_file_locs, $parse_errors_file_loc;
    }

    return @csv_file_locs;
}

sub _get_file_loc {
    my ($self, $report_name) = @_;

    my $from_string = $self->from->datetime_yyyymmdd_hhmmss;
    $from_string =~ s/[^\d]//g;
    my $to_string = $self->to->datetime_yyyymmdd_hhmmss;
    $to_string =~ s/[^\d]//g;

    my $file_extension = ($report_name =~ /^(?:LOGIN_EXTRACTION_ERRORS|PARSE_ERRORS)$/) ? 'txt' : 'csv';

    return
          BOM::Platform::Runtime->instance->app_config->system->directory->tmp
        . '/BOM_account_affiliate_payment_'
        . $report_name . '_'
        . $from_string . '_'
        . $to_string . '.'
        . $file_extension;
}

sub _get_csv_line_from_transaction {
    my $transaction = shift;

    # loginid
    my $loginid = _get_BOM_loginid_from_transaction($transaction);
    die 'Could not extract BOM loginid from transaction. Full transaction details: ' . Dumper($transaction) unless $loginid;
    my $client = BOM::Platform::Client::get_instance({loginid => $loginid});
    if (not $client) {
        die 'Could not instantiate client from extracted BOM loginid. Full transaction details: ' . Dumper($transaction);
    }

# amount:
    my $USD_amount = $transaction->{'AMOUNT'};
# since this was a debit from the affiliate MyAffiliates account, the amount comes through negative
    if (not defined $USD_amount or $USD_amount >= 0) {
        croak 'Amount[' . $USD_amount . '] is invalid. Full transaction details: ' . Dumper($transaction);
    }
    $USD_amount = abs $USD_amount;
    my $preferred_currency = $client->currency;
    my $preferred_currency_amount = roundnear(0.01, amount_from_to_currency($USD_amount, 'USD', $preferred_currency));

    my $month_str = _get_month_from_transaction($transaction);
    if (not $month_str) {
        croak 'Could not extract month from transaction. Full transaction details: ' . Dumper($transaction);
    }

    my $comment = 'Payment from RMG ' . $month_str;

# got everything, so lets make the CSV line:
    my $csv = Text::CSV->new;
    $csv->combine($loginid, 'credit', 'affiliate_reward', $preferred_currency, $preferred_currency_amount, $comment);
    my $string = trim $csv->string;

    return trim $csv->string;
}

sub _get_month_from_transaction {
    my $transaction = shift;

    my $occurred = $transaction->{'OCCURRED'} || '';
    my $month_str = '';

    if ($occurred =~ /^(\d{4}-\d{2}-\d{2})/) {
        my $date = Date::Utility->new($1);
        $month_str = $date->month_as_string . ' ' . $date->year;
    }

    return $month_str;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

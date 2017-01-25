package BOM::MyAffiliates::PaymentToAccountManager;

=head1 NAME

BOM::MyAffiliates::PaymentToAccountManager

=head1 SYNOPSIS

    my $manager = BOM::MyAffiliates::PaymentToAccountManager->new(from => $from_date, to => $to_date);

=cut

use strict;
use warnings;
use Moose;
use IO::File;
use Try::Tiny;
use Data::Dumper qw( Dumper );
use Text::CSV;
use Text::Trim;
use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use List::MoreUtils qw(any);
use Postgres::FeedDB::CurrencyConverter qw(amount_from_to_currency);
use BOM::Platform::Runtime;
use Client::Account;
use BOM::MyAffiliates;
use LandingCompany::Registry;

has ['from', 'to'] => (
    is       => 'ro',
    isa      => 'Date::Utility',
    required => 1,
);

has 'tmp_dir' => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

# Returns an array of paths to files on the server where the payment CSV files
# are located. Can then be passed to our mailing code for emailing out etc.
# Also returns paths to files containing error reports.

sub get_csv_file_locs {
    my $self = shift;

    my $api = BOM::MyAffiliates->new;

    my @account_transactions = $api->fetch_account_transactions(
        'FROM_DATE' => $self->from->date_yyyymmdd,
        'TO_DATE'   => $self->to->date_yyyymmdd,
    );

    my $txn_for_company = _split_txn_by_landing_company(@account_transactions);

    return $self->_write_csv_files($txn_for_company);
}

sub _split_txn_by_landing_company {
    my @account_transactions = @_;
    my $txn_for              = {};

    foreach my $transaction (@account_transactions) {
        my $loginid = _get_loginid_from_txn($transaction);

        # Ok, the following is not a landing_company name. I basically want to hold onto transactions
        # that we can't process, so that I can report them as erroneous later. The naming
        # doesn't quite fit the underlying concept, but works.
        my $company = 'LOGIN_EXTRACTION_ERRORS';
        $loginid =~ /^([A-Z]+)\d+$/;
        $company = LandingCompany::Registry::get_by_broker($1)->short;

        if (not ref $txn_for->{$company}) {
            $txn_for->{$company} = [];
        }
        push @{$txn_for->{$company}}, $transaction;
    }

    return $txn_for;
}

sub _get_loginid_from_txn {
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
    my ($self, $txn_for_company) = @_;
    my @csv_file_locs;
    my @parse_errors;

    local $\ = "\n";    # because my print statements do not punch a record separator

    foreach my $company (keys %{$txn_for_company}) {
        my $file_loc        = $self->_get_file_loc($company);
        my $transaction_set = $txn_for_company->{$company};

        open my $fh, '>', $file_loc or die "Cannot open $file_loc: $!";

        if ($company eq 'LOGIN_EXTRACTION_ERRORS') {
            print $fh Dumper($transaction_set);
            close $fh;
        } else {
            foreach my $transaction (@{$transaction_set}) {
                try {
                    print $fh _get_csv_line_from_txn($transaction);
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

    return $self->tmp_dir . '/affiliate_payment_' . $report_name . '_' . $from_string . '_' . $to_string . '.' . $file_extension;
}

sub _get_csv_line_from_txn {
    my $transaction = shift;

    # loginid
    my $loginid = _get_loginid_from_txn($transaction);
    die 'Could not extract BOM loginid from transaction. Full transaction details: ' . Dumper($transaction) unless $loginid;
    my $client = Client::Account::get_instance({loginid => $loginid});
    if (not $client) {
        die 'Could not instantiate client from extracted BOM loginid. Full transaction details: ' . Dumper($transaction);
    }

    # amount:
    my $USD_amount = $transaction->{'AMOUNT'};
    # since this was a debit from the affiliate MyAffiliates account, the amount comes through negative
    if (not defined $USD_amount or $USD_amount >= 0) {
        die 'Amount[' . $USD_amount . '] is invalid. Full transaction details: ' . Dumper($transaction);
    }
    $USD_amount = abs $USD_amount;
    my $preferred_currency = $client->currency;
    my $preferred_currency_amount = roundnear(0.01, amount_from_to_currency($USD_amount, 'USD', $preferred_currency));

    my $month_str = _get_month_from_transaction($transaction);
    if (not $month_str) {
        die 'Could not extract month from transaction. Full transaction details: ' . Dumper($transaction);
    }

    my $comment = 'Payment from Binary Services Ltd ' . $month_str;

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

sub _build_tmp_dir {
    return BOM::Platform::Runtime->instance->app_config->system->directory->tmp;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

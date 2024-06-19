#!/usr/bin/env perl

=head1 NAME

    transfer_between_client_accounts.pl

=head1 SYNOPSIS

    perl transfer_between_client_accounts.pl -f <csv_file> -c <Source Currency>

    Where <Source Currency> is the currency from which source client account balance needs to be transferred to the destination client account

    eg:
    perl transfer_between_client_accounts.pl -f <csv_file> -c UST
    Where UST is the currency for which source client balance needs to be transferred to the destination client account

    #To disable the source client account after transferring the balance to the destination client account
    perl transfer_between_client_accounts.pl -f <csv_file> -c <Currency> -da 1

    #for Dry Run
    perl transfer_between_client_accounts.pl -f <csv_file> -c <Currency> -dr 1
    This will just print the details of 5 clients with their current balance and destination currency

    #To adjust log level to show info logs aswell do (Default log level is warning):
    perl transfer_between_client_accounts.pl -f <csv_file> -c <Currency> -l info

    # expected csv format
    source_loginid,destination_loginid
    CR90000004,CR90000002
    CR90000446,CR90000005

=head1 OPTIONS

The following options are mandatory:

=over 4

=item B<-f, --csv_file_path>

The path to the CSV file containing the source and destination client account IDs.

=item B<-c, --input_currency>

The -c or --input_currency option specifies the currency in which the source client account balance should be transferred to the destination client account based on destination currency. 
The currency code should be provided as a three-letter code, such as USD, EUR, UST.

=back

The following options are optional:

=over 4

=item B<-dr, --dry_run>

If set to 1, the script will perform a dry run and print the details of 5 clients with their current balance and destination currency.

=item B<-l, --log_level>

The log level to use for logging. Valid values are 'debug', 'info', 'warning', 'error', and 'fatal'. The default log level is 'warning'.

=back

=item B<-da, --disable_account>

If set to 1, the script will disable the source client account after transferring the balance to the destination client account.

=back

=cut

use strict;
use warnings;

use Getopt::Long;
use Log::Any::Adapter qw(Stderr), log_level => 'warning';
use Log::Any     qw($log);
use Pod::Usage   qw(pod2usage);
use Text::CSV_XS qw( csv );
use Syntax::Keyword::Try;
use ExchangeRates::CurrencyConverter qw(convert_currency);
use Format::Util::Numbers            qw( financialrounding );
use Time::Piece;

use BOM::User::Client;

GetOptions(
    "f|csv_file_path=s"    => \my $csv_file_path,
    "dr|dry_run=i"         => \my $dry_run,
    "c|input_currency=s"   => \my $input_currency,
    "l|log_level=s"        => sub { Log::Any::Adapter->set('Stderr', log_level => $_[1]) },
    "da|disable_account=i" => \my $disable_account,
);

# Basic requirement for the script to work
pod2usage(1) unless ($csv_file_path && $input_currency);

=head2 get_client_details

    Simple function to accept a csv file path and return its contents as an array of hashrefs

    Input: csv file path
    Returns array of hashrefs of data in a csv file

=item *  C<file_path> - CSV file path with the source and destination loginids

=cut

sub get_client_details {
    my $file_path = shift;

    my $aoh = csv(
        in      => $file_path,
        headers => "auto"
    );

    return $aoh;
}

my ($dry_run_counter, $success_counter, $error_counter) = (0, 0, 0);

=head2 transfer_client_balance

    Handler function that will call the transfer function and provide the loginids, handle error and success responses
    It will also write the response to a csv file

    Input: csv file path
    Returns csv file with the response of the transfer

=item *  C<file_path> - CSV file path with the source and destination loginids

=cut

sub transfer_client_balance {
    my ($file_path, $status_code) = @_;

    my $client_records = get_client_details($file_path);

    printf("Count of the clients: %s\n", scalar @$client_records);
    if ($dry_run) {
        printf("Dry run started\n");
    }

    return unless scalar @$client_records;

    my @response_to_csv = ();

    for my $record (@$client_records) {
        try {
            my $response = transfer(
                source_loginid      => $record->{source_loginid},
                destination_loginid => $record->{destination_loginid},
            );

            if (ref($response) eq 'HASH' and $response->{remark} eq 'Success') {
                $log->infof(
                    'Client %s balance of %s %s transfered to %s',
                    $record->{source_loginid},
                    $response->{source_balance},
                    $response->{source_currency},
                    $record->{destination_loginid});
                push(
                    @response_to_csv,
                    [
                        $record->{source_loginid},         "balance amount of ",
                        $response->{source_balance},       $response->{source_currency},
                        " Converted to ",                  $response->{balance_transfered},
                        $response->{destination_currency}, " transferred to ",
                        $record->{destination_loginid}, ($response->{disable_account} ? "account has been disabled" : "")]);
                $success_counter++;
            } elsif (ref($response) eq 'HASH' and $response->{remark} eq 'dry run completed') {
                printf("Dry run completed \n");
                last;
            }
        } catch ($err) {
            chomp($err);
            $error_counter++;
            $log->errorf('An error occurred for client %s: Error : %s', $record->{source_loginid}, $err);
            push(@response_to_csv, [$record->{source_loginid}, $err]);

        }
    }
    printf("Total number of client transfers succedded : %s, Failures : %s\n", $success_counter, $error_counter);
    my $timestamp   = localtime->epoch;
    my $output_file = "transfer_output_$timestamp.csv";
    csv(
        in  => \@response_to_csv,
        out => $output_file
    ) unless $dry_run;
}

=head2 transfer

    This function will transfer the balance from source client to destination client
    It will also convert the amount to the destination client currency

    Input: source and destination loginids
    Returns hashref for the response object which contains information like source balance, destination currency, balance transfered

=item *  C<source_loginid> - Loginid to transfer the balance from

=item * C<destination_loginid> - Loginid to transfer the balance to

=cut

sub transfer {
    my (%param) = @_;

    my $source_client      = BOM::User::Client->new({loginid => $param{source_loginid}});
    my $destination_client = BOM::User::Client->new({loginid => $param{destination_loginid}});
    my %response;

    die 'No source client found: ' . $param{source_loginid} . "\n"           unless $source_client;
    die 'No destination client found: ' . $param{destination_loginid} . "\n" unless $destination_client;

    #getting source client balance and currency
    my $account_balance_source = $source_client->default_account->balance;
    my $source_currency        = $source_client->currency;

    die 'Invalid currency for source client (Does not match input currency)' . "\n"
        if ($source_currency ne $input_currency);

    #Failsafe to check destination loginid against source client sibling loginids
    my @sibling_loginids = $source_client->user->bom_real_loginids;
    die 'Destination loginid is not a sibling of source client' . "\n"
        unless (grep { $_ eq $param{destination_loginid} } @sibling_loginids);

    #getting destination client currency
    my $destination_currency = $destination_client->currency;

    if ($dry_run) {
        printf(
            "For client %s balance is %s and will be transferred to account %s with currency %s \n",
            $param{source_loginid}, $account_balance_source, $param{destination_loginid},
            $destination_currency
        );
        $dry_run_counter++;
        if ($dry_run_counter == 5) {
            %response = (remark => 'dry run completed');
            return \%response;
        }

        return;
    }

    die 'No balance for source client' . "\n" if ($account_balance_source <= 0);

    #debiting the amount from source client
    try {
        $source_client->payment_legacy_payment(
            currency     => $source_currency,
            amount       => -$account_balance_source,
            remark       => "Closing $source_currency Account",
            payment_type => 'adjustment',
        );

    } catch ($err) {
        die 'Unable to debit the amount from source client Error : ' . $err . "\n";
    }

    my $rounded_off_amount;
    #Converting the amount to relevant currency based on the destination client
    try {
        my $converted_amount = convert_currency($account_balance_source, $source_currency, $destination_currency);
        $rounded_off_amount = financialrounding('amount', $destination_currency, $converted_amount);
    } catch ($err) {
        die 'Unable to convert the amount from source client Error : ' . $err . "\n";
    }

    #crediting the amount to destination client
    try {
        $destination_client->payment_legacy_payment(
            currency     => $destination_currency,
            amount       => $rounded_off_amount,
            remark       => "Adjustment for $source_currency account closure",
            payment_type => 'adjustment',
        );
    } catch ($err) {
        die "Unable to credit $account_balance_source $source_currency converted to $rounded_off_amount $destination_currency to destination client:"
            . $param{destination_loginid}
            . ' Error : '
            . $err . "\n";
    }

    if ($disable_account) {
        if ($source_client->status->disabled) {
            $log->infof('Account %s is already disabled', $param{source_loginid});
        } else {
            try {
                $source_client->status->set('disabled', 'system', "$source_currency currency suspension");
            } catch ($err) {
                die 'Unable to disable the source client Error : ' . $err . "\n";
            }
        }
    }

    %response = (
        source_balance       => $account_balance_source,
        source_currency      => $source_currency,
        destination_currency => $destination_currency,
        balance_transfered   => $rounded_off_amount,
        remark               => 'Success',
        disable_account      => $disable_account,
    );

    return \%response;
}

transfer_client_balance($csv_file_path);

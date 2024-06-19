#!/etc/rmg/bin/perl
package main;

=head1 NAME

crypto_credit_wrong_currency_deposits.cgi

=head1 DESCRIPTION

Handles AJAX requests for crediting clients.

=cut

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeXS;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use BOM::Cryptocurrency::BatchAPI;
my $batch = BOM::Cryptocurrency::BatchAPI->new();

my $json = JSON::MaybeXS->new;

my $credit                = request()->param('credit');
my $correct_currency_code = request()->param('correct_currency_code');
my $wrong_currency_code   = request()->param('wrong_currency_code');
my $amount                = request()->param('amount');
my $transaction_hash      = trim(request()->param('transaction_hash'));
my $to_address            = trim(request()->param('to_address'));

if ($credit) {

    $batch->add_request(
        id     => 'process_wrong_currency_deposit',
        action => 'deposit/process_wrong_currency_deposit',
        body   => {
            address               => $to_address,
            correct_currency_code => $correct_currency_code,
            wrong_currency_code   => $wrong_currency_code,
            transaction_hash      => $transaction_hash,
            amount                => $amount,
        },
    );
    $batch->process();
    my $credit_res = $batch->get_response_body('process_wrong_currency_deposit');

    print $json->encode({is_successful => $credit_res->{is_successful}});

}


#!/usr/bin/perl

use strict;
use warnings;

use BOM::Database::ClientDB;
use BOM::Transaction;
use Syntax::Keyword::Try;

my $date = shift @ARGV // die 'date must be specified';
my $vr   = BOM::Database::ClientDB->new({broker_code => 'VRTC'});
# source 3 is app id for riskd
my $source = 3;

my @all_expired_unsold = $vr->db->dbic->run(
    fixup => sub {
        $_->selectrow_array(
            q{SELECT DISTINCT acc.client_loginid
                FROM bet.financial_market_bet_open fmbo
                    JOIN transaction.account acc ON fmbo.account_id=acc.id
                WHERE settlement_time < ? AND is_sold is false;},
            {}, $date
        );
    });

# sell expired but unsold contracts
foreach my $loginid (@all_expired_unsold) {
    try {
        BOM::Transaction::sell_expired_contracts({
            client => BOM::User::Client->new({loginid => $loginid}),
            source => $source,
        });
    } catch {
        warn "failed to sell all expired contracts for $loginid. Skipping ...";
    };
}

my $mlt_open = $vr->db->dbic->run(
    fixup => sub {
        $_->selectall_arrayref(
            q{SELECT acc.client_loginid, fmbo.id
                FROM bet.financial_market_bet_open fmbo
                    JOIN transaction.account acc ON fmbo.account_id=acc.id
                    JOIN betonmarkets.client cl ON cl.loginid=acc.client_loginid 
                WHERE fmbo.bet_class != 'multiplier' AND cl.residence IN ('be', 'hu' ,'fi' ,'it' ,'fr' ,'nl' ,'lv' ,'cz' ,'ie' ,'es' ,'cy' ,'lt' ,'gb' ,'ro' ,'bg' ,'lu' ,'hr' ,'ee' ,'pl' ,'si' ,'gr' ,'pt' ,'sk' ,'de' ,'se' ,'at' ,'dk');}
        );
    });

foreach my $data (@$mlt_open) {
    my ($loginid, $fmb_id) = @$data;
    try {
        my $client = BOM::User::Client->new({loginid => $loginid});

        my $clientdb = BOM::Database::ClientDB->new({
            client_loginid => $loginid,
            operation      => 'replica',
        });

        my @fmbs = @{$clientdb->getall_arrayref('select * from bet_v1.get_open_contract_by_id(?)', [$fmb_id])};

        my $fmb = $fmbs[0];

        my $contract_parameters = {
            shortcode       => $fmb->{short_code},
            currency        => $client->currency,
            landing_company => $client->landing_company->short,
        };

        $contract_parameters->{limit_order} = BOM::Transaction::Utility::extract_limit_orders($fmb)
            if $fmb->{bet_class} =~ /^(multiplier|accumulator)$/;

        BOM::Transaction->new({
                purchase_date       => time,
                client              => $client,
                contract_parameters => $contract_parameters,
                contract_id         => $fmb_id,
                price               => 0,
                source              => $source,
            })->sell(skip_validation => 1);
    } catch {
        warn "Failed to sell contract " . $fmb_id;
    };
}

#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use HTML::Entities;

use List::Util qw( first );
use Try::Tiny;

use BOM::User::Client;

use Cache::RedisDB;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Config::Runtime;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Cookie;
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Manually Settle Contracts');

Bar('Manually Settle Contracts');

my $rt = BOM::Config::Runtime->instance;

my $broker_db = BOM::Database::ClientDB->new({
        broker_code => request()->param('broker'),
    })->db;

# We're going to presume things won't change too much underneath us.
# If you're here because this presumption was wrong, please simply
# reassign this via the function just before display.
my $expired_unsold = current_unsaleable($broker_db);

if (request()->param('perform_actions')) {
    try {
        my $staff_name = BOM::Backoffice::Auth0::get_staffname();
        die 'Do not know who you are; cannot proceed' unless $staff_name;
        foreach my $todo (grep { /^fmb_/ } (keys %{request()->params})) {
            my $action = request()->param($todo);
            next if ($action eq 'skip');
            my $fmb_id = $todo;
            $fmb_id =~ s/^fmb_(\d+)$/$1/;
            my $bet_info = first { $_->{fmb_id} == $fmb_id } @$expired_unsold;
            die $fmb_id . '  cannot be settled with this tool.' unless $bet_info;

            BOM::Database::Helper::FinancialMarketBet->new({
                    transaction_data => {
                        staff_loginid => $staff_name,
                    },
                    bet_data => {
                        id         => $fmb_id,
                        sell_price => $action eq 'win' ? $bet_info->{payout} : 0,
                        sell_time  => Date::Utility->new->db_timestamp,
                        is_expired => 1,
                        quantity   => 1,
                    },
                    account_data => {
                        client_loginid => $bet_info->{loginid},
                        currency_code  => $bet_info->{currency}
                    },
                    db => $broker_db
                })->sell_bet;

            if ($action eq 'cancel') {
                # For cancelled bets, now adjust their account for the purchase price
                my $client = BOM::User::Client::get_instance({'loginid' => $bet_info->{loginid}});
                my $remark = 'Adjustment contract purchase ref ' . $bet_info->{ref};
                $client->payment_legacy_payment(
                    currency     => $bet_info->{currency},
                    amount       => $bet_info->{buy_price},
                    remark       => $remark,
                    staff        => $staff_name,
                    payment_type => 'adjustment_purchase',
                );
            }
        }
    }
    catch {
        print '<h1>ERROR! Could not complete ' . encode_entities($_) . '</h1>';
    };
}

my $cancel_info = {};
$cancel_info->{unsettled}   = current_unsaleable($broker_db);
$cancel_info->{broker_code} = request()->param('broker');
BOM::Backoffice::Request::template()->process('backoffice/settle_contracts.html.tt', $cancel_info);

code_exit_BO();

sub current_unsaleable {
    my $broker_db = shift;

    my $query = qq{ SELECT * FROM expired_unsold_bets() };
    my %possibles = %{$broker_db->dbic->run(fixup => sub { $_->selectall_hashref($query, 'financial_market_bet_id') })};

    return [
        sort { $a->{bb_lookup} cmp $b->{bb_lookup} }
        grep { exists $possibles{$_->{fmb_id}} } @{Cache::RedisDB->get('AUTOSELL', 'ERRORS') // []}];
}


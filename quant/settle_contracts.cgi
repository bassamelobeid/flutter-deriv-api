#!/usr/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;

use List::Util qw( first );
use Try::Tiny;
use Mail::Sender;

use Cache::RedisDB;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet;
use BOM::Platform::Helper::Model::FinancialMarketBet;
use BOM::Platform::Runtime;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('Manually Settle Contracts');

Bar('Manually Settle Contracts');

my $rt = BOM::Platform::Runtime->instance;

if (
    my $err_msg =
      (!request()->is_logged_into_bo)                      ? 'Not Logged into BO'
    : (!$rt->hosts->localhost->has_role('dealing_server')) ? 'Only to be run on dealing servers.'
    :                                                        ''
    )
{
    print('<h1>' . $err_msg . '</h1>');
    code_exit_BO();
}

my $localhost = $rt->hosts->localhost;

if ($localhost->has_role('master_live_server')) {
    die "This tool can't be accessed from Master Live Server. It can only be accessed from dealing server's BO";
}

my $broker_db    = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
                broker_code => request()->param('broker_code'),
    })->db;

# We're going to presume things won't change too much underneath us.
# If you're here because this presumption was wrong, please simply
# reassign this via the function just before display.
my $expired_unsold = current_unsaleable($broker_db);

if (request()->param('perform_actions')) {
    try {
        my $staff_name = request()->bo_cookie->clerk;
        die 'Do not know who you are; cannot proceed' unless $staff_name;
        foreach my $todo (grep { /^fmb_/ } (keys %{request()->params})) {
            my $action = request()->param($todo);
            next if ($action eq 'skip');
            my $fmb_id = $todo;
            $fmb_id =~ s/^fmb_(\d+)$/$1/;
            my $bet_info = first { $_->{fmb_id} == $fmb_id } @$expired_unsold;
            die $fmb_id . '  cannot be settled with this tool.' unless $bet_info;
            my $client = BOM::Platform::Client::get_instance({'loginid' => $bet_info->{loginid}});
            my $fmb =
                BOM::Platform::Data::Persistence::DataMapper::FinancialMarketBet->new({broker_code => $client->broker})->get_fmb_by_id([$fmb_id])
                ->[0];

            my $bet = produce_contract($fmb, $bet_info->{currency});
            my $fmb_helper = BOM::Platform::Helper::Model::FinancialMarketBet->new({
                bet => $fmb,
                db  => $broker_db,
            });

            my $sell_time = BOM::Utility::Date->new->db_timestamp;
            if ($action eq 'cancel') {
                # First we sell off for 0.
                $fmb_helper->sell_bet({
                    sell_price    => 0,
                    sell_time     => $sell_time,
                    staff_loginid => $staff_name,
                });
                # Now adjust their account for the purchase price
                my $remark = 'Adjustment bet purchase ref ' . $bet_info->{ref};
                $client->payment_legacy_payment(
                    currency     => $bet_info->{currency},
                    amount       => $bet_info->{buy_price},
                    remark       => $remark,
                    staff        => $staff_name,
                    payment_type => 'adjustment_purchase',
                );
            } elsif ($action eq 'loss') {
                # Here we just the open position for 0
                $fmb_helper->sell_bet({
                    sell_price    => 0,
                    sell_time     => $sell_time,
                    staff_loginid => $staff_name,
                });

            } elsif ($action eq 'win') {
                # Here we just the open position for full payout
                $fmb_helper->sell_bet({
                    sell_price    => $bet_info->{payout},
                    sell_time     => $sell_time,
                    staff_loginid => $staff_name,
                });
            }

        }
    }
    catch {
        print '<h1>ERROR! Could not complete ' . $_ . '</h1>';
    };
}

my $cancel_info = {};
$cancel_info->{unsettled} = current_unsaleable($broker_db);
BOM::Platform::Context::template->process('backoffice/settle_contracts.html.tt', $cancel_info);

code_exit_BO();

sub current_unsaleable {
    my $broker_db = shift;

    my $query = qq{ SELECT * FROM expired_unsold_bets() };
    my %possibles = %{$broker_db->dbh->selectall_hashref($query, 'financial_market_bet_id')};

    return [
        sort { $a->{bb_lookup} cmp $b->{bb_lookup} }
        grep { exists $possibles{$_->{fmb_id}} } @{Cache::RedisDB->get('AUTOSELL', 'ERRORS') // []}];
}


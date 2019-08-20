#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no indirect;

use Date::Utility;
use Format::Util::Numbers qw(roundcommon);
use Machine::Epsilon;
use HTML::Entities;

use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Finance::Asset::Market::Registry;
use BOM::ContractInfo;
use Try::Tiny;
use BOM::Product::ContractFactory qw(produce_contract);
use Performance::Probability qw(get_performance_probability);

use f_brokerincludeall;
BOM::Backoffice::Sysinit::init();

my $loginID = uc(request()->param('loginID') // '');
my $encoded_loginID = encode_entities($loginID);

PrintContentType();
BrokerPresentation($encoded_loginID . ' Contracts Analysis', '', '');

if ($loginID !~ /^(\D+)(\d+)$/) {
    print "<div class='errorfield Grey3Candy'>Error: Wrong loginID ($encoded_loginID) could not get client instance</div>";
    code_exit_BO();
}

my $client = BOM::User::Client::get_instance({
    'loginid'    => $loginID,
    db_operation => 'replica'
});
if (not $client) {
    print "<div class='errorfield Grey3Candy'>Error: Wrong loginID ($encoded_loginID) could not get client instance</div>";
    code_exit_BO();
}

### Sold Contracts ###
my $page = trim(request()->param('page')) || 1;
my $all_in_one_page = trim(request()->checkbox_param('all_in_one_page'));
#$limit = 0 is treated as LIMIT ALL
#default pagination limit is 50. 51 is for checking wether there is any need to paginate.
my $limit = ($all_in_one_page) ? 0 : 51;
my $offset = ($all_in_one_page) ? 0 : ($limit - 1) * ($page - 1);

##Get instance of financial market bet data mapper
my $clientdb = BOM::Database::ClientDB->new({
    client_loginid => $client->loginid,
});
Bar($loginID . " - Contracts");
my $financial_market_data_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
    client_loginid => $client->loginid,
    currency_code  => $client->currency,
    db             => $clientdb->db,
});

##Initialize and Validate given first and last purchase times (format: "yyyy-mm-dd hh:mi:ss")
my $error;
my %params;
my $first_purchase_time            = trim(request()->param('first_purchase_time'));
my $last_purchase_time             = trim(request()->param('last_purchase_time'));
my $date_format_regex              = qr/\b[0-9]{4}-\b[0-9]{2}-\b[0-9]{2}$/;
my $datetime_without_seconds_regex = qr/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$/;
if ($first_purchase_time) {
    #Convert "YYYY-MM-DD HH:MI" into "YYYY-MM-DD HH:MI:00" format to prevent buggy behaviour of Date::Utility
    $first_purchase_time .= ":00" if ($first_purchase_time =~ $datetime_without_seconds_regex);
    $first_purchase_time = Date::Utility->new($first_purchase_time)->datetime_yyyymmdd_hhmmss;
}

if ($last_purchase_time) {
    if ($last_purchase_time =~ $date_format_regex) {
        $last_purchase_time = Date::Utility->new($last_purchase_time)->plus_time_interval('86399s')->datetime_yyyymmdd_hhmmss;
    } elsif ($last_purchase_time =~ $datetime_without_seconds_regex) {
        #Convert "YYYY-MM-DD HH:MM" into "YYYY-MM-DD HH:MM:00" format to prevent buggy behaviour of Date::Utility
        $last_purchase_time .= ":00";
        $last_purchase_time = Date::Utility->new($last_purchase_time)->datetime_yyyymmdd_hhmmss;
    } else {
        $last_purchase_time = Date::Utility->new($last_purchase_time)->datetime_yyyymmdd_hhmmss;
    }
}

##Fetch sold contracts based on the input conditions if validation of inputs is passed.
my $sold_contracts = [];
%params = (
    $first_purchase_time ? (first_purchase_time => $first_purchase_time) : (),
    $last_purchase_time  ? (last_purchase_time  => $last_purchase_time)  : (),
    limit  => $limit,
    offset => $offset
);
$sold_contracts = try {
    $financial_market_data_mapper->get_sold_contracts(%params)
}
catch {
    $error = $_;
};

##Handle pagination
my $has_newer_page      = ($page > 1) ? 1 : 0;
my $has_older_page      = 0;
my $sold_contracts_size = scalar(@{$sold_contracts});
if ($sold_contracts_size) {
    if (!$all_in_one_page && $first_purchase_time && $last_purchase_time) {
        if ($sold_contracts_size >= $limit) {
            $has_older_page = 1;
            #default pagination limit is 50
            delete $sold_contracts->[-1];
        }
    }
}

### Performance Probability ###
my $do_calculation = request()->param('calc_performance_probability');

my @buy_price;
my @payout_price;
my @start_time;
my @sell_time;
my @underlying_symbol;
my @bet_type;
my @exit_tick_epoch;
my @barriers;
my $cumulative_pnl = 0;

my $performance_probability;
my $inv_performance_probability;

if (defined $do_calculation && $sold_contracts_size) {

    foreach my $contract (@{$sold_contracts}) {
        my $start_epoch = Date::Utility->new($contract->{start_time})->epoch;
        my $sell_epoch  = Date::Utility->new($contract->{sell_time})->epoch;

        if (   $contract->{bet_type} eq 'CALL'
            or $contract->{bet_type} eq 'PUT'
            or $contract->{bet_type} eq 'CALLE'
            or $contract->{bet_type} eq 'PUTE'
            or $contract->{bet_type} =~ /^DIGIT/)
        {

            my $c = try { produce_contract($contract->{short_code}, 'USD') } catch { undef };
            next unless $c;

            if ($c->exit_tick) {

                push @exit_tick_epoch, $c->exit_tick->epoch;

            } else {

                push @exit_tick_epoch, $c->underlying->tick_at($contract->{sell_time}, {allow_inconsistent => 1})->epoch;
            }

            push @barriers,          $c->barrier->as_absolute;
            push @start_time,        $start_epoch;
            push @sell_time,         $sell_epoch;
            push @buy_price,         $contract->{buy_price};
            push @payout_price,      $contract->{payout_price};
            push @bet_type,          $contract->{bet_type};
            push @underlying_symbol, $contract->{underlying_symbol};

            $cumulative_pnl = $cumulative_pnl + ($contract->{sell_price} - $contract->{buy_price});
        }
    }

    if (scalar(@start_time) > 0) {
        $performance_probability = Performance::Probability::get_performance_probability({
            payout          => \@payout_price,
            bought_price    => \@buy_price,
            pnl             => $cumulative_pnl,
            types           => \@bet_type,
            underlying      => \@underlying_symbol,
            start_time      => \@start_time,
            sell_time       => \@sell_time,
            exit_tick_epoch => \@exit_tick_epoch,
            barriers        => \@barriers,
        });

        $inv_performance_probability = roundcommon(0.01, 1 / ($performance_probability + machine_epsilon()));
        $performance_probability     = (1 - $performance_probability) * 100;
        $performance_probability     = roundcommon(0.001, $performance_probability);
    }
}

### Open Contracts ###
my $open_contracts = get_open_contracts($client);
foreach my $contract (@$open_contracts) {
    $contract->{purchase_time} = Date::Utility->new($contract->{purchase_time})->datetime_yyyymmdd_hhmmss;
}
#Sort open contracts according to desceding order of purchase time
@$open_contracts = sort { $b->{purchase_time} cmp $a->{purchase_time} } @$open_contracts;

### Template ###
BOM::Backoffice::Request::template()->process(
    'backoffice/account/profit_table.html.tt',
    {
        sold_contracts              => $sold_contracts,
        open_contracts              => $open_contracts,
        markets                     => [Finance::Asset::Market::Registry->instance->display_markets],
        email                       => $client->email,
        full_name                   => $client->full_name,
        loginid                     => $client->loginid,
        first_purchase_time         => $first_purchase_time,
        last_purchase_time          => $last_purchase_time,
        page                        => $page,
        all_in_one_page             => $all_in_one_page,
        currency                    => $client->currency,
        residence                   => request()->brand->countries_instance->countries->country_from_code($client->residence),
        contract_details            => \&BOM::ContractInfo::get_info,
        performance_probability     => $performance_probability,
        inv_performance_probability => $inv_performance_probability,
        has_newer_page              => $has_newer_page,
        has_older_page              => $has_older_page,
        error                       => $error
    }) || die BOM::Backoffice::Request::template()->error();

code_exit_BO();

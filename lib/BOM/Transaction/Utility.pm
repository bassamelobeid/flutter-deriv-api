package BOM::Transaction::Utility;

use strict;
use warnings;
no indirect;

use Syntax::Keyword::Try;
use Log::Any qw($log);

use Date::Utility;
use List::Util qw(min max);
use Encode;
use JSON::MaybeXS;
use JSON::MaybeUTF8 qw(:v1);

use BOM::Platform::Event::Emitter;
use BOM::Config::Redis;
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::Config;

# the mejority of contracts are sold by expiryd, within 30s.
# the 5m ttl is for the few that end up at riskd.
use constant KEY_RETENTION_SECOND => 300;
use constant POC_PARAMETERS       => 'POC_PARAMETERS';

my $json = JSON::MaybeXS->new;

=head2 update_poc_parameters_ttl

Utility method to set expiry of redis key to KEY_RETENTION_SECOND seconds.

Note that $redis->del is not used because POC_PARAMETERS might still be
used by other processes to send final contract details to client.

=cut

sub update_poc_parameters_ttl {
    my ($contract_id, $client) = @_;

    my $redis_pricer_shared = BOM::Config::Redis::redis_pricer_shared_write;
    my $redis_key           = join '::', (POC_PARAMETERS, $contract_id, $client->landing_company->short);

    # we don't delete this right away because some service like pricing queue or transaction stream might still rely
    # on the contract parameters. We will give additional KEY_RETENTION_SECOND seconds for this to be done.
    $redis_pricer_shared->expire($redis_key, KEY_RETENTION_SECOND);

    return;
}

sub build_poc_parameters {
    my ($client, $fmb) = @_;

    my $sell_time;
    my $purchase_time = 0 + Date::Utility->new($fmb->{purchase_time})->epoch;
    $sell_time = 0 + Date::Utility->new($fmb->{sell_time})->epoch if $fmb->{sell_time};

    my $transaction_ids = {buy => $fmb->{buy_transaction_id}};
    $transaction_ids->{sell} = $fmb->{sell_transaction_id} if ($fmb->{sell_transaction_id});

    my $contract_parameters = {
        app_markup_percentage => 0,                                 # we charge app_markup on buy side only
        short_code            => $fmb->{short_code},
        contract_id           => $fmb->{id},
        currency              => $client->currency,
        is_sold               => $fmb->{is_sold} ? 1 : 0,           # JSON::PP::Boolean to 0 or 1
        is_expired            => $fmb->{is_expired},
        sell_price            => $fmb->{sell_price},
        buy_price             => $fmb->{buy_price},
        landing_company       => $client->landing_company->short,
        account_id            => $fmb->{account_id},
        purchase_time         => $purchase_time,
        sell_time             => $sell_time,
        transaction_ids       => $transaction_ids,
        symbol                => $fmb->{underlying_symbol},
        contract_type         => $fmb->{bet_type},
    };

    # country code is required for china because we have special offerings conditions.
    if ($client->residence eq 'cn') {
        $contract_parameters->{country_code} = $client->residence;
    }

    if ($fmb->{bet_class} eq 'multiplier') {
        $contract_parameters->{limit_order} = extract_limit_orders($fmb);
    }

    return $contract_parameters;
}

=head2 set_poc_parameters

Utility method to set proposal open contract (POC) parameters when a contract is purchased, updated or sold.

=cut

sub set_poc_parameters {
    my ($poc_parameters, $expiry_epoch) = @_;

    my $redis_pricer_shared = BOM::Config::Redis::redis_pricer_shared_write;
    my $redis_key           = join '::', (POC_PARAMETERS, $poc_parameters->{contract_id}, $poc_parameters->{landing_company});

    my $default_expiry = 86400;
    if (defined $expiry_epoch) {
        my $seconds_to_expiry = $expiry_epoch - time;
        # add KEY_RETENTION_SECOND seconds after expiry,
        # to cater for sell transaction delay due to settlement conditions.
        my $ttl = max($seconds_to_expiry, 0) + KEY_RETENTION_SECOND;
        $default_expiry = min($default_expiry, int($ttl));
    }

    if ($default_expiry <= 0) {
        warn "CONTRACT_PARAMS is not set for $redis_key because of invalid TTL";
    }

    my %hash = (
        price_daemon_cmd => 'bid',
        %$poc_parameters,
    );

    $redis_pricer_shared->set($redis_key, _serialized_args(\%hash), 'EX', $default_expiry) if $default_expiry > 0;
    return;
}

sub build_poc_pricer_args {
    my $poc_parameters = shift;
    return 'PRICER_ARGS::'
        . encode_json_utf8([
            price_daemon_cmd => 'bid',
            landing_company  => $poc_parameters->{landing_company},
            contract_id      => $poc_parameters->{contract_id},
            account_id       => $poc_parameters->{account_id},
            symbol           => $poc_parameters->{underlying_symbol},
            contract_type    => $poc_parameters->{contract_type},
        ]);
}

=head2 extract_limit_orders

use this function to parse parameters like stop_out and take_profit from financial_market_bet

=cut

sub extract_limit_orders {
    my $contract_params = shift;

    my %orders = ();

    my @supported_order = qw(stop_out take_profit stop_loss);
    if (ref $contract_params eq 'BOM::Database::AutoGenerated::Rose::FinancialMarketBet') {
        my $child      = $contract_params->{multiplier};
        my $basis_spot = $child->basis_spot;
        my $commission = $child->commission;
        foreach my $order (@supported_order) {
            # when the order date is defined, there's an order
            my $order_date = join '_', ($order, 'order_date');
            if ($child->$order_date) {
                my $order_amount = join '_', ($order, 'order_amount');
                $orders{$order} = {
                    order_type   => $order,
                    basis_spot   => $basis_spot,
                    order_date   => $child->$order_date->epoch,
                    order_amount => $child->$order_amount,
                    commission   => $commission,
                };
            }
        }

        if ($child->cancellation_price) {
            $orders{cancellation} = {
                price        => $child->cancellation_price,
                is_cancelled => $child->is_cancelled
            };
        }
    } elsif (ref $contract_params eq 'HASH') {
        my $basis_spot = $contract_params->{basis_spot};
        my $commission = $contract_params->{commission};
        foreach my $order (@supported_order) {
            my $order_date = join '_', ($order, 'order_date');
            if ($contract_params->{$order_date}) {
                my $order_amount = join '_', ($order, 'order_amount');
                $orders{$order} = {
                    order_type   => $order,
                    basis_spot   => $basis_spot,
                    order_date   => $contract_params->{$order_date},
                    order_amount => $contract_params->{$order_amount},
                    commission   => $commission,
                };
            }
        }

        if ($contract_params->{cancellation_price}) {
            $orders{cancellation} = {
                price        => $contract_params->{cancellation_price},
                is_cancelled => $contract_params->{is_cancelled}};
        }
    } else {
        die 'Invalid contract parameters';
    }

    return \%orders;
}

sub _serialized_args {
    my $copy = {%{+shift}};

    # We want to handle similar contracts together, so we do this and sort by
    # key in the price_queue.pl daemon
    my @arr = ('short_code', delete $copy->{short_code});
    foreach my $k (sort keys %$copy) {
        push @arr, ($k, $copy->{$k});
    }

    return Encode::encode_utf8($json->encode([map { !defined($_) ? $_ : ref($_) ? $_ : "$_" } @arr]));
}

=head2 report_validation_stats

Utility method to send buy/sell validation stats to DataDog.

=cut

sub report_validation_stats {
    my ($contract, $which, $valid) = @_;

    # This should all be fast, since everything should have been pre-computed.

    my @bool_attrs = qw(is_intraday is_forward_starting is_atm_bet);
    my $stats_name = 'pricing_validation.' . $which . '.';

    # These attempt to be close to the Transaction stats without compromising their value.
    # It may be worth adding a free-form 'source' identification, but I don't want to go
    # down that road just yet.
    my $tags = {
        tags => [
            'rmgenv:' . BOM::Config::env,
            'contract_class:' . $contract->code,
            map { substr($_, 3) . ':' . ($contract->$_ ? 'yes' : 'no') } (@bool_attrs)]};

    stats_inc($stats_name . 'attempt', $tags);
    if ($valid) {
        stats_inc($stats_name . 'success', $tags);
    } else {
        # We can be a tiny bit slower here as we're already reporting an error
        my $error = $contract->primary_validation_error->message;
        $error =~ s/(?<=[^A-Z])([A-Z])/ $1/g;    # camelCase to words
        $error =~ s/\[[^\]]+\]//g;               # Bits between [] should be dynamic
        $error = join('_', split /\s+/, lc $error);
        push @{$tags->{tags}}, 'reason:' . $error;
        stats_inc($stats_name . 'failure', $tags);
    }

    return;
}
1;

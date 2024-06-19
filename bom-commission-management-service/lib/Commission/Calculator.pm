package Commission::Calculator;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use DataDog::DogStatsd::Helper qw(stats_inc);
use Date::Utility;
use BOM::User::Client;
use BOM::Config::Runtime;
use Format::Util::Numbers qw(financialrounding);
use YAML::XS              qw(LoadFile);
use POSIX                 qw(ceil);

our $VERSION = '0.1';

=head1 NAME

Commission::Calculator - calculates the daily commission for all affiliates based on their clients deals

=head1 SYNOPSIS

 use IO::Async::Loop;
 use Commission::Calculator;
 $loop->add(
    my $calculator = Commission::Calculator->new(
        db_service => 'commission01',
        date => 'YYYY-MM-DD'
    )
 );

$calculator->calculate()->get();

=head1 DESCRIPTION

Getting registered deals from DB and calculate commission for each deal 
based on various factors. Some factors are being extracted from deal record 
and some from config files

=cut

no indirect;

use Future::AsyncAwait;
use Future::Utils qw(fmap0);
use Syntax::Keyword::Try;
use Log::Any qw($log);
use Database::Async;
use Database::Async::Engine::PostgreSQL;
use Net::Async::Redis;

# we will not use exchange rates older than 1 day
use constant EXCHANGE_RATES_DELAY_THRESHOLD => 86400;

# to not use exchange rates older than 2 days for weekends
use constant WEEKEND_EXCHANGE_RATES_DELAY_THRESHOLD => 172800;

=head2 date

The date string supported by L<Date::Utility>

=head2 start_date

A date derived from $self->date. Look period is 2 days.

=head2 per_page_limit

The number of deal to fetch from commission database per page. Default to 200.

=head2 concurrency_limit

Number of concurrent database pages. Default to 10

=head2 db_service

A postgres service based on https://www.postgresql.org/docs/current/libpq-pgservice.html

=head2 _dbic

Commission database

=head2 _exchange_rates

Exchange rates for convertion from deal currency to IB account currency

=head2 cfd_provider

CFD platform provider. E.g. dxtrade

=head2 affiliate_provider

External affiliate platform provider. E.g. myaffiliate

=head2 _clientdbs

Returns a hash reference of client databases by broker code

=head2 redis_exchangerates

C<Net::Async::Redis> instance of exchange rate redis

=head2 redis_exchangerates_config

Default to '/exc/rmg/redis-exchangerates.yml'

=head2 from_date

The date to start the calculation from, in yyyy-mm-dd format. Useful for back calculating commissions

=head2 cfd_product_name

Returns the name of the CFD product based on the cfd_provider

=cut

sub date      { shift->{date} }
sub from_date { shift->{from_date} }

sub start_date {
    my $self = shift;
    # if from_date is provided, use it. Useful for back calculating commissions
    if ($self->from_date) {
        return Date::Utility->new($self->from_date)->db_timestamp;
    }
    my $end = Date::Utility->new($self->date);
    return $end->minus_time_interval('2d')->db_timestamp;
}
sub per_page_limit             { shift->{per_page_limit} }
sub concurrency_limit          { shift->{concurrency_limit} }
sub db_service                 { shift->{db_service} }
sub cfd_provider               { shift->{cfd_provider} }
sub affiliate_provider         { shift->{affiliate_provider} }
sub redis_exchangerates        { shift->{redis_exchangerates} }
sub redis_exchangerates_config { shift->{redis_exchangerates_config} }
sub _dbic                      { shift->{_dbic} }
sub _clientdbs                 { shift->{_clientdbs} // {} }
sub _exchange_rates            { shift->{_exchange_rates} }
sub cfd_product_name           {
    my $self = shift;
    my %cfd_product_name = ( dxtrade => "DerivX", ctrader => "cTrader");
    return $cfd_product_name{$self->cfd_provider};
}

=head2 new

Create a new instance
Providing date and db_service is required
$calculator = Commission::Calculator->new(%args);

=over 4

=item * C<$args{date}> - a date in yyyy-mm-dd format to calculate the commissions for

=item * C<$args{db_service}> - a postgres service based on https://www.postgresql.org/docs/current/libpq-pgservice.html

=item * C<$args{per_page_limit}> - optional (default: 200) - number of deals to fetch from DB per page

=item * C<$args{concurrency_limit}> 

optional (default: 10) - number of concurrent database pages and deals to calculate commission for
10 means almost 100 concurrent processes, 10 concurrent deal batches and each batch 10 concurrent deals

=item * C<$args{decimal_point}> - optional (default: 4) - number of decimal points for the calculated commission

=item * C<$args{from_date}> - The date to start the calculation from, in yyyy-mm-dd format. Useful for back calculating commissions

=back

return a L<Commission::Calculator> blessed object

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        date                       => $args{date},
        per_page_limit             => $args{per_page_limit}    || 200,
        concurrency_limit          => $args{concurrency_limit} || 10,
        db_service                 => $args{db_service}        || 'commission01',
        cfd_provider               => $args{cfd_provider},
        affiliate_provider         => $args{affiliate_provider},
        redis_exchangerates_config => $args{redis_exchange_rates_config} || '/etc/rmg/redis-exchangerates.yml',
        from_date                  => $args{from_date},
    };

    die "Please provide a valid date in yyyy-mm-dd format"
        if not defined $self->{date}
        or $self->{date} !~ /\d{4}\-\d{2}\-\d{2}/;

    die "Please provide a valid 'from_date' parameter in yyyy-mm-dd format that is not in the future"
        if $self->{from_date} && Date::Utility->new($self->{from_date})->epoch() > Date::Utility->new()->epoch();

    die "Please provide or db_service (e.g. commission01) arguments"
        if not defined $self->{db_service};

    die "cfd_provider is required for commission calculation" unless $self->{cfd_provider};

    die "affiliate_provider is required for commission calculation" unless $self->{affiliate_provider};

    return bless $self, $class;
}

=head2 _add_to_loop

=cut

sub _add_to_loop {
    my $self = shift;

    my %parameters = (
        pool => {
            max => 1,
        },
        engine => {service => $self->db_service},
        type   => 'postgresql',
    );

    $self->{_dbic} = Database::Async->new(%parameters);

    $self->add_child($self->_dbic);

    my $redis_config = LoadFile($self->redis_exchangerates_config);

    # when password is empty string, should turn it to undef, otherwise Net::Async::Redis will report an error
    my $redis = Net::Async::Redis->new(
        host => $redis_config->{read}{host},
        port => $redis_config->{read}{port},
        auth => $redis_config->{read}{password} || undef,
    );

    $self->{redis_exchangerates} = $redis;
    $self->add_child($redis);
}

=head2 _exchange_rate

To retrieve exchange rates for converting a one current to another currency
$self->_exchange_rate('GBP', 'USD');

=over 4

=item + C<$exchange_from> - base currency

=item + C<$exchange_to> - currency you wish to exchange to

=back

Return the exchange rate in numerical format

=cut

sub _exchange_rate {
    my ($self, $exchange_from, $exchange_to) = @_;

    $exchange_from = uc $exchange_from;
    $exchange_to   = uc $exchange_to;

    return {
        quote => 1,
        epoch => time
    } if $exchange_from eq $exchange_to;

    my $key = join '_', ($exchange_from, $exchange_to);

    return $self->{_exchange_rates}{$key};

}

=head1 calculate

Perform the commission calculation for all the deals in the given date

=cut

async sub calculate {
    my $self = shift;

    # If calculation is not enabled, then we will not proceed
    unless ($self->_config->enable) {
        $log->infof("Commission calculation is disabled for %s", $self->cfd_provider);
        return;
    }

    await $self->_load_exchange_rates();

    # Get the count of deals
    my $date_deals = await $self->_get_effective_deals_count();

    if ($date_deals == 0) {
        $log->infof("No deals to process on from %s to %s", $self->start_date, $self->date);
        return;
    }

    # The ceil function is used to round up the result to the nearest integer.
    my $no_of_pages = ceil($date_deals / $self->per_page_limit);
    # minimum of 1
    $no_of_pages = 1 if $no_of_pages < 1;

    await fmap0 {
        my ($page) = @_;

        return $self->_calculate_page($page);
    }
    foreach        => [1 .. $no_of_pages],
        concurrent => $self->concurrency_limit;

    await $self->_make_affiliate_payment() if $self->_config->enable_auto_payment;
}

=head2 _calculate_page

Perform the commission calculation for each deal in the retrieved page

=cut

async sub _calculate_page {
    my ($self, $page) = @_;

    my $deals = await $self->_get_deals_per_page($page);

    return await fmap0(
        async sub {
            my ($deal) = @_;

            my $target_symbol = $deal->{symbol};

            my $target_currency = $deal->{payment_currency};
            my $exchange_rate   = $self->_exchange_rate($deal->{currency}, $target_currency);

            if (not defined $exchange_rate) {
                stats_inc(
                    'cms.no_exchange_rate',
                    $self->_prepare_statsd_tag(
                        cfd_provider => $deal->{provider},
                        currency     => $deal->{currency}));

                $log->errorf(
                    "No exchange rate found with deal %s for %s (%s)",
                    $deal->{id}, $deal->{currency} . '-' . $target_currency,
                    $deal->{provider});
                return;
            }

            # TODO: Once we get information for account_type from stream, we will replace this.
            my $commission_rate = await $self->_get_commission_rate('standard', $target_symbol);

            if (not defined $commission_rate) {
                stats_inc(
                    'cms.no_commission_rate',
                    $self->_prepare_statsd_tag(
                        cfd_provider => $deal->{provider},
                        account_type => $deal->{account_type},
                        symbol       => $deal->{symbol},
                    ));

                $log->errorf("No commission rate found for symbol %s on %s deal from %s", $deal->{symbol}, $deal->{account_type}, $deal->{provider});
                return;
            }

            my $commission_type = $self->_get_commission_type($target_symbol);
            if (not defined $deal->{$commission_type}) {
                stats_inc(
                    'cms.invalid_commission_type',
                    $self->_prepare_statsd_tag(
                        cfd_provider    => $deal->{provider},
                        commission_type => $commission_type
                    ));

                $log->errorf("Invalid commission type [%s] for cfd_provider [%s]", $commission_type, $deal->{provider});
                return;
            }

            # Commission calculated is in the quoted currency of the underlying symbol.
            # Basically, if the symbol is USD/JPY, the commission would be denoted in JPY XX. This, then has to be converted to the account currency of the affiliate.
            my $base_commission = $commission_rate * $deal->{$commission_type} * $deal->{price};
            my $commission      = $base_commission * $exchange_rate->{quote};

            my %commission_params = (
                deal_id             => $deal->{id},
                provider            => $deal->{provider},
                affiliate_client_id => $deal->{affiliate_client_id},
                account_type        => $deal->{account_type},
                commission_type     => $commission_type,
                base_symbol         => $deal->{symbol},
                mapped_symbol       => $target_symbol,
                volume              => $deal->{volume},
                spread              => $deal->{spread},
                price               => $deal->{price},
                base_currency       => $deal->{currency},
                target_currency     => $target_currency,
                exchange_rate       => $exchange_rate->{quote},
                exchange_rate_ts    => $exchange_rate->{epoch},
                applied_commission  => $commission_rate,
                base_amount         => $base_commission,
                amount              => $commission,
                performed_at        => $deal->{performed_at},
                calculated_at       => Date::Utility->new->db_timestamp,
            );

            try {
                my $commission_id = await $self->_store_calculated_commission(%commission_params);

                $commission_params{id} = $commission_id;
            } catch {
                stats_inc(
                    'cms.commission_not_inserted',
                    $self->_prepare_statsd_tag(
                        deal         => $deal->{id},
                        cfd_provider => $deal->{provider},
                        commission   => sprintf("USD%s", $commission),
                    ));

                $log->errorf("Error saving commission for deal %s: %s", $deal->{id}, $_);
                return;
            }
        },
        foreach    => $deals,
        concurrent => $self->concurrency_limit,
    );
}

=head2 _make_affiliate_payment

Credit the affiliate Deriv's account with commission payment

=cut

async sub _make_affiliate_payment {
    my $self = shift;

    my $deals;

    try {
        $deals =
            await $self->_dbic->query(q{select * from transaction.get_commission_by_affiliate($1,$2)}, $self->cfd_provider, $self->affiliate_provider)
            ->row_hashrefs->as_arrayref;
    } catch ($e) {
        await $self->_warn_and_reconnect('get_commission_payment_by_cfd_provider', $e);
    }

    unless ($deals) {
        $log->infof("No commissions found for payment on %s", $self->date);
        return;
    }

    $log->debugf("payments %s", $deals);

    my %group;
    foreach my $record ($deals->@*) {
        # we do not double pay
        next if $record->{payment_id};
        $group{$record->{payment_loginid}}{$record->{target_currency}}{amount} += $record->{commission_amount};
        push @{$group{$record->{payment_loginid}}{$record->{target_currency}}{ids}}, $record->{deal_id};
    }

    unless (%group) {
        $log->infof("No new payments made on %s for %s deals found", $self->date, scalar(@$deals));
        return;
    }

    my $payment_date = Date::Utility->new;

    foreach my $payment_loginid (keys %group) {
        my $client = BOM::User::Client->new({loginid => uc $payment_loginid});
        unless ($client) {
            $log->warnf("Unknown payment id [%s]", $payment_loginid);
            next;
        }

        foreach my $currency (keys $group{$payment_loginid}->%*) {
            # There's a chance where affiliate payment details are being updated after the commission is being calculated with the old target currency.
            # In this case, we will do the conversion
            my $commission_amount = $group{$payment_loginid}{$currency}{amount};
            if ($client->currency ne $currency) {
                my $exchange_rate = $self->_exchange_rate($currency, $client->currency);
                $commission_amount = $commission_amount * $exchange_rate->{quote};
            }

            my $clientdb       = $self->_get_clientdb($client);
            my $payment_params = {
                account_id           => $client->account->id,
                amount               => financialrounding('price', $client->currency, $commission_amount),
                payment_gateway_code => 'affiliate_reward',
                payment_type_code    => 'affiliate_reward',
                staff_loginid        => 'commission-auto-pay',
                status               => 'OK',
                remark               => sprintf("Payment from %s %s-%s", $self->cfd_product_name, $payment_date->day_of_month, $payment_date->month_as_string),
            };

            if ($payment_params->{amount} <= 0) {
                $log->infof("Commission for payment loginid [%s] is less than 1 cent [%s]. Payment will be accrued to the next day.",
                    $payment_loginid, $commission_amount);
                next;
            }

            # perform transaction
            try {
                my @bind_params = (
                    @$payment_params{
                        qw/account_id amount payment_gateway_code payment_type_code
                            staff_loginid payment_time transaction_time status
                            remark transfer_fees quantity source/
                    },
                    undef,    # child table
                    undef,    # transaction details
                );
                await $clientdb->query('begin')->void;
                my ($txn) =
                    await $clientdb->query(q{SELECT t.* from payment.add_payment_transaction($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) t},
                    @bind_params)->row_hashrefs->as_list;
                # update commission records with txn id
                my $deal_ids = join ',', $group{$payment_loginid}{$currency}{ids}->@*;
                $deal_ids = '{' . $deal_ids . '}';
                await $self->_dbic->query(q{SELECT * FROM transaction.update_commission_payment_id($1,$2)}, $txn->{id}, $deal_ids)->void;

                await $clientdb->query('commit')->void;
            } catch ($e) {
                try {
                    await $clientdb->query('rollback')->void;
                } catch ($rollback_e) {
                    $log->warnf("Failed to rollback transaction [%s]", $rollback_e);
                }
            }
        }
    }

}

=head2 _get_clientdb

Returns a client db instance of C<Database::Async>

=over 4

=item * C<$client> - C<BOM::User::Client> instance

=back

=cut

sub _get_clientdb {
    my ($self, $client) = @_;

    my $broker_code = lc $client->broker_code;

    return $self->{_clientdbs}{$broker_code} if $self->{_clientdbs}{$broker_code};

    my $service = $broker_code . '01';

    my %parameters = (
        pool => {
            max => 1,
        },
        engine => {service => $service},
        type   => 'postgresql',
    );

    my $db = Database::Async->new(%parameters);
    $self->add_child($db);
    # cache it
    $self->{_clientdbs}{$broker_code} = $db;

    return $db;
}

=head2 _get_effective_deals_count

Returns the number of deals for $self->date

=cut

async sub _get_effective_deals_count {
    my $self = shift;

    my $count = 0;

    try {
        $count = await $self->_dbic->query(q{SELECT * FROM transaction.get_deals_count_for_period($1,$2,$3)},
            $self->start_date, $self->date, $self->cfd_provider)->single;
    } catch ($e) {
        await $self->_warn_and_reconnect('get_deals_count_for_period', $e);
    }

    return $count;
}

=head2 _get_deals_per_page

Returns deals by page.

=over 4

=item * C<$page> - page number

=back

=cut

async sub _get_deals_per_page {
    my ($self, $page) = @_;

    my $deals = [];

    # The offset is calculated by taking the remainder of the page number divided by the concurrency limit and multiplying it by the per-page limit.
    my $offset = ($page - 1) % $self->concurrency_limit * $self->per_page_limit;

    try {
        $deals = await $self->_dbic->query(q{SELECT * FROM transaction.get_deals_for_period($1, $2, $3, $4, $5)},
            $self->start_date, $self->date, $self->cfd_provider, $self->per_page_limit, $offset)->row_hashrefs->as_arrayref;
        $log->debugf("deals received for date[%s] for cfd_provider[%s]: %s", $self->date, $self->cfd_provider, $deals);
    } catch ($e) {
        await $self->_warn_and_reconnect('get_deals_for_period', $e);
    }

    return $deals;
}

=head2 _store_calculated_commission

Saves calculated commission parameters

=over 4

=item * C<$commission{deal_id}> - deal id

=item * C<$commission{cfd_provider}> - external trading platform

=item * C<$commission{affiliate_client_id}> - the reference to affiliate.affiliate_client table in commission database

=item * C<$commission{market_type}> - financial, synthetic or stp

=item * C<$commission{base_symbol}> - external underlying symbol

=item * C<$commission{mapped_symbol}> - the corresponding underlying symbol definition by deriv

=item * C<$commission{volume}> - volume in unit

=item * C<$commission{spread}> - spread at the time of deal purchase

=item * C<$commission{price}> - the price of the underlying symbol

=item * C<$commission{base_currency}> - the currency that the commission is calculated in

=item * C<$commission{target_currency}> - the affiliate.payment_currency

=item * C<$commission{exchange_rate}> - the exchange rate used to convert commission calculated in base currency to affiliate.payment_currency

=item * C<$commission{exchange_rate_ts}> - the timestamp when the exchange rate is taken

=item * C<$commission{applied_commission}> - the commission rate applied on the deal

=item * C<$commission{base_amount}> - the commission amount in deal's base currency

=item * C<$commission{amount}> - the commission amount in the affiliate.payment_currency

=item * C<$commission{performed_at}> - deal execution timestamp

=item * C<$commission{calculated_at}> - commission calculated timestamp

=item * C<$commission{commission_type}> - the commission schema used. Currently supports only spread and volume based calculation

=back

Returns deal id

=cut

async sub _store_calculated_commission {
    my ($self, %commission) = @_;

    my $deal_id;

    try {
        $deal_id = await $self->_dbic->query(
            q{SELECT * FROM transaction.add_new_commission($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19)},
            $commission{deal_id},             $commission{provider},
            $commission{affiliate_client_id}, $commission{account_type},
            $commission{commission_type},     $commission{base_symbol},
            $commission{mapped_symbol},       $commission{volume},
            $commission{spread},              $commission{price},
            $commission{base_currency},       $commission{target_currency},
            $commission{exchange_rate},       Date::Utility->new($commission{exchange_rate_ts})->db_timestamp,
            $commission{applied_commission},  $commission{base_amount},
            $commission{amount},              $commission{performed_at},
            $commission{calculated_at},
        )->single;
    } catch ($e) {
        await $self->_warn_and_reconnect('add_new_commission', $e);
    }

    return $deal_id;
}

=head2 _prepare_statsd_tag

=cut

sub _prepare_statsd_tag {
    my $self = shift;
    my %args = @_;

    my @tags = ();

    for my $tag (keys %args) {
        push @tags, sprintf("%s:%s", $tag, $args{$tag});
    }

    return {tags => \@tags};
}

=head2 _warn_and_reconnect

Reconnect to commission database.

=cut

async sub _warn_and_reconnect {
    my ($self, $context, $e) = @_;

    my $msg = ref $e ? $e->message : $e;
    $log->debugf("expection throw while executing %s. Error: %s", $context, $msg);

    # reconnect
    $self->remove_child($self->_dbic);
    $self->add_child(
        $self->{_dbic} = Database::Async->new(
            pool     => {max => 1},
            encoding => 'utf8',
            type     => 'postgresql',
            engine   => {service => $self->db_service},
        ));
}

=head2 _config_commission_rate

Commission rate config for symbol

=cut

async sub _config_commission_rate {
    my $self = shift;

    return $self->{_config_commission_rate} if $self->{_config_commission_rate};

    my $commission_config =
        await $self->_dbic->query(q{select * from affiliate.get_commission_by_provider($1)}, $self->cfd_provider)->row_hashrefs->as_arrayref;
    my $rate;
    foreach my $config ($commission_config->@*) {
        $rate->{$config->{account_type}}{$config->{mapped_symbol}}{$config->{type}} = $config->{commission_rate};
    }

    $self->{_config_commission_rate} = $rate;

    return $rate;
}

=head2 _get_commission_rate

Get commission rate for account type and symbol

=over 4

=item * C<$account_type> - account grouping (E.g. standard or stp)
=item * C<$target_symbol> - underlying symbol (E.g. frxUSDJPY)

=back

=cut

async sub _get_commission_rate {
    my ($self, $account_type, $target_symbol) = @_;

    my $commission_config = await $self->_config_commission_rate();
    my $commission_type   = $self->_get_commission_type($target_symbol);

    $log->debugf("commission type %s", $commission_type);

    return $commission_config->{$account_type}{$target_symbol}{$commission_type};
}

=head2 _config

commission config

=cut

sub _config {
    my $self = shift;

    my $cfd_provider = $self->cfd_provider;
    if ($cfd_provider eq 'mt5') {
        return BOM::Config::Runtime->instance->app_config->quants->mt5_affiliate_commission;
    } elsif ($cfd_provider eq 'dxtrade') {
        return BOM::Config::Runtime->instance->app_config->quants->dxtrade_affiliate_commission;
    } elsif ($cfd_provider eq 'ctrader') {
        return BOM::Config::Runtime->instance->app_config->quants->ctrader_affiliate_commission;
    } else {
        $log->infof("Unable to get commission config for CFD provider - %s", $self->cfd_provider);
        return;
    }
}

=head2 _get_commission_type

commission type by symbol

=cut

sub _get_commission_type {
    my ($self, $symbol) = @_;

    # we can't use instrument->type as of now because CFD contains a mixture of indices, synthetic & commidities
    my $market = ($symbol =~ /^(?:Vol|Jump|Crash|Boom|RB\s\d+)/ or $symbol =~ /Basket$/) ? 'synthetic' : 'financial';

    # TODO: this should be change to $symbol_config->{is_generated} when it is released
    return $self->_config->type->synthetic if $market eq 'synthetic';
    return $self->_config->type->financial;
}

=head2 _load_exchange_rates

Load exchange rate and inverted exchange rates from redis.

=cut

async sub _load_exchange_rates {
    my $self = shift;

    my %rates;
    my $redis = $self->redis_exchangerates;
    my $keys  = await $redis->keys('exchange_rates::*');
    # Sunday is the 0th day of the week
    my $day_of_week = Date::Utility->new->day_of_week;
    foreach my $key ($keys->@*) {
        my $data = await $redis->hmget($key, 'quote', 'offer_to_clients', 'epoch');
        my ($quote, $offer_to_clients, $exchange_epoch) = $data->@*;
        my $exchange_rates_delay_threshold = $day_of_week ? EXCHANGE_RATES_DELAY_THRESHOLD : WEEKEND_EXCHANGE_RATES_DELAY_THRESHOLD;
        if ($offer_to_clients and $exchange_epoch and time - $exchange_epoch < $exchange_rates_delay_threshold) {
            $key =~ s/exchange_rates:://;
            $rates{$key} = {
                quote => $quote,
                epoch => $exchange_epoch
            };
            my ($foreign, $quoted) = split '_', $key;
            my $inverted_key = join '_', ($quoted, $foreign);
            $rates{$inverted_key} = {
                quote => 1 / $quote,
                epoch => $exchange_epoch
            };
        }
    }

    $self->{_exchange_rates} = \%rates;

}

1;

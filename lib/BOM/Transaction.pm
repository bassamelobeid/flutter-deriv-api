package BOM::Transaction;

use Moose;

no indirect;

use Encode;
use Data::Dumper;
use Error::Base;
use Path::Tiny;
use Scalar::Util qw(blessed);
use Time::HiRes qw(tv_interval gettimeofday time);
use JSON::MaybeXS;
use Date::Utility;
use ExpiryQueue qw( enqueue_new_transaction enqueue_multiple_new_transactions );
use Try::Tiny;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing stats_count);

use Brands;
use BOM::User::Client;
use Finance::Asset::Market::Types;
use Finance::Contract::Category;
use Format::Util::Numbers qw/formatnumber financialrounding/;
use List::Util qw(min);

use BOM::Config;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use Finance::Contract::Longcode qw( shortcode_to_parameters );
use BOM::Platform::Context qw(localize request);
use BOM::Config::RedisReplicated;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::Account;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Database::Model::Account;
use BOM::Database::Model::DataCollection::QuantsBetVariables;
use BOM::Database::Model::Constants;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Database::Helper::RejectedTrade;
use BOM::Database::ClientDB;
use BOM::Transaction::CompanyLimits;
use BOM::Transaction::Validation;

=head1 NAME

    BOM::Transaction

=cut

my $json = JSON::MaybeXS->new;

=head2 action_type

This can be either 'buy' or 'sell'.

=cut

has action_type => (
    is       => 'rw',
    init_arg => undef,
);

has [qw(requested_amount recomputed_amount)] => (
    is         => 'ro',
    init_arg   => undef,
    lazy_build => 1,
);

has request_type => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_request_type {
    my $self = shift;

    # certain contract types do not have payout so we will be comparing stake for these contracts.
    return 'payout' if ($self->action_type eq 'buy' and $self->amount_type eq 'stake' and $self->contract->is_non_zero_payout);
    return 'price';
}

sub _build_requested_amount {
    my $self = shift;

    my $type = $self->request_type;
    return $self->$type;
}

sub _build_recomputed_amount {
    my $self = shift;

    # certain contract types do not have payout so we will be comparing stake for these contracts.
    return $self->contract->payout if $self->request_type eq 'payout';
    return $self->action_type eq 'buy' ? $self->contract->ask_price : $self->contract->bid_price;
}

sub adjust_amount {
    my ($self, $amount) = @_;

    my $type = $self->request_type;

    if ($type eq 'payout') {
        # We override contract just for the sake of having correct contract shortly.
        # TODO: improve this by not having to re-create contract for this.
        my $contract = make_similar_contract(
            $self->contract,
            {
                amount_type => 'payout',
                amount      => $amount
            });
        $self->contract($contract);
    }

    return $self->$type($amount);
}

=head2 get_price_move

This function is record slippage amount (price or payout) for a particular contract into $transaction->price_slippage
attribute in BOM::Transaction object.

slippage amount under different situations could benefit the user or the company. For ease of reporting,
we will convert slippage amount to reflect the following:

- postive slippage: company's gain
- negative slippage: company's loss

slippage amount is calculated with the following formula:

$slippage = $requested - $recomputed

Buying a contract:

- When $transaction->request_type eq 'price'

    A positive slippage (in ask price) means profit for the company. For example:

    User requested to buy the contract for 10 USD. When it reaches our server, the recomputed ask price of the contract is now 9 USD. In this case, slippage (10 USD - 9 USD) is 1 USD.
    The contract is sold at 10USD (theoretically sold at a more expensive price)

    On the other hand, a negative slippage  means loss for the company. The logic is the same, we sold the contract at a cheaper price.

- When $transaction->request_type eq 'payout'

    A positive slippage (in payout price) means loss for the company. For example:

    User wanted to stake 5 USD to win a 10 USD payout. So, the requested payout is 10 USD. When it reaches our server, the recomputed payout of the contract is now 9 USD.
    In this case, payout slippage (10 USD - 9 USD) is 1 USD. We are giving user 1 USD more than what it should be, hence a company loss.

    On the other hand, a negative payout slippage means profit for the company.

Selling a contract:

When you're selling a contract, the requested and recomputed amount are always going to be in bid price space.

A positive slippage (in bid price) means loss for the company and vice versa.

=cut

sub get_price_move {
    my $self = shift;

    my $action_type  = $self->action_type;
    my $request_type = $self->request_type;

    die 'action_type is not defined' unless $action_type;

    my $amount = $self->requested_amount - $self->recomputed_amount;

    # invert slippage amount to reflect company's position
    if (($action_type eq 'buy' and $request_type eq 'payout') or $action_type eq 'sell') {
        $amount *= -1;
    }

    return $amount;
}

sub record_slippage {
    my ($self, $amount) = @_;

    return $self->price_slippage(financialrounding('price', $self->contract->currency, $amount));
}

has client => (
    is  => 'ro',
    isa => 'BOM::User::Client',
);

has multiple => (
    is  => 'ro',
    isa => 'Maybe[ArrayRef]',
);

has contract_parameters => (
    is => 'rw',
);

has contract => (
    is         => 'rw',
    lazy_build => 1,
);

has contract_details => (
    is => 'rw',
);

has transaction_details => (
    is => 'rw',
);

sub _build_contract {
    my $self  = shift;
    my $param = $self->contract_parameters;

    if ($param->{shortcode}) {
        $param = shortcode_to_parameters($param->{shortcode}, $param->{currency});
        $param->{landing_company} = $self->contract_parameters->{landing_company};
        $param->{limit_order} = $self->contract_parameters->{limit_order} if $self->contract_parameters->{limit_order};
    }
    return produce_contract($param);
}

has price => (
    is  => 'rw',
    isa => 'Maybe[Num]',
);

=head2 price_slippage

 positive price slippage means contract was bought or sold to the client in company's favour.

 We absorb price slippage on either side up to 50% of contract commission.

=cut

has price_slippage => (
    is      => 'rw',
    default => 0,
);

has transaction_record => (
    is         => 'ro',
    isa        => 'BOM::Database::AutoGenerated::Rose::Transaction',
    lazy_build => 1,
);

sub _build_transaction_record {
    my $self = shift;
    my $id = $self->transaction_id || die 'transaction not written yet';
    return $self->client->default_account->find_transaction(query => [id => $id])->[0];
}

has balance_after => (
    is  => 'rw',
    isa => 'Maybe[Num]',
);

has limits => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { +{} },
);

has payout => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_payout {
    my $self = shift;
    return $self->contract->payout;
}

=head2 amount_type

amount_type can either be 'payout' or 'stake'. This works for all existing contract types.

=cut

has amount_type => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_amount_type {
    my $self = shift;

    my $param = $self->contract_parameters;
    my $amount_type;
    # shortcode is generated internally and not part of buy parameter. When is part of the $self->contract_parameters,
    # this is an existing contract.
    if ($param->{shortcode}) {
        $amount_type = shortcode_to_parameters($param->{shortcode}, $param->{currency})->{amount_type};
    }

    # lookbacks does not require amount_type and amount as it's input, but internally we would
    # still want to compare the ask price
    $amount_type = 'payout' unless $self->contract->category->require_basis;
    die 'amount_type is required' unless defined $amount_type;
    die 'amount_type can only be stake or payout' unless ($amount_type eq 'stake' or $amount_type eq 'payout');

    return $amount_type;
}

has comment => (
    is      => 'rw',
    isa     => 'ArrayRef',
    default => sub { [] },
);

has staff => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_staff {
    my $self = shift;
    return $self->client->loginid;
}

has transaction_id => (
    is  => 'rw',
    isa => 'Int',
);

### For sell operations only
has reference_id => (
    is  => 'rw',
    isa => 'Int',
);

has contract_id => (
    is  => 'rw',
    isa => 'Int',
);

has execute_at_better_price => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

# calling server should capture time of request
has purchase_date => (
    is       => 'rw',
    isa      => 'date_object',
    coerce   => 1,
    required => 1
);

has source => (
    is  => 'ro',
    isa => 'Maybe[Int]',
);

has transaction_parameters => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {}; },
);

sub BUILDARGS {
    my (undef, $args) = @_;

    if (exists $args->{price}) {
        $args->{transaction_parameters}->{price} = $args->{price};
    }
    if (exists $args->{payout}) {
        $args->{transaction_parameters}->{payout} = $args->{payout};
    }
    return $args;
}

my %known_errors;              # forward declaration
sub sell_expired_contracts;    # forward declaration

sub stats_start {
    my $self = shift;
    my $what = shift;

    my $client   = $self->client;
    my $contract = $self->contract;

    my $broker      = lc($client->broker_code);
    my $virtual     = $client->is_virtual ? 'yes' : 'no';
    my $rmgenv      = BOM::Config::env;
    my $bet_class   = $BOM::Database::Model::Constants::BET_TYPE_TO_CLASS_MAP->{$contract->code};
    my $lc          = $client->landing_company->short;
    my $market_name = $contract->market->name;
    my $tags =
        {tags => ["broker:$broker", "virtual:$virtual", "rmgenv:$rmgenv", "contract_class:$bet_class", "landing_company:$lc", "market:$market_name"]};

    if ($what eq 'buy' or $what eq 'batch_buy') {
        push @{$tags->{tags}}, "amount_type:" . lc($self->amount_type), "expiry_type:" . ($contract->fixed_expiry ? 'fixed' : 'duration');
    } elsif ($what eq 'sell') {
        push @{$tags->{tags}}, "sell_type:manual";
    }
    stats_inc("transaction.$what.attempt", $tags);

    # End of 2019 we found out that we are stacking IO loops on top of each other. At the time, the
    # normal stack depth at this point during a buy transaction was 49. But sometimes we saw stack
    # depths of up to 600. The following code allows sysadmins to create a directory
    # (/var/lib/binary/BOM::Transaction) to turn on logging of the stack depth to datadog. If the
    # directory is also writable and the stack depth exceeds 70, a stack trace is written to a file
    # in that directory. At the time of this writing, each file uses on average 10kb of disk space.
    # This code generates at most 1000 files depending on the PID. Older files will be overwritten.
    # So, the file system needs to provide about 10MB of free space.
    if (-d (my $fn = '/var/lib/binary/BOM::Transaction')) {
        my $stack_depth = 1;
        1 while defined scalar caller($stack_depth += 10);
        1 until defined scalar caller --$stack_depth;

        # For a given set of tags these curves should be absolutely flat!
        DataDog::DogStatsd::Helper::stats_gauge("transaction.$what.stack_depth", $stack_depth, $tags);

        if ($stack_depth > 70 and -w $fn) {
            my $basename = $$ % 1000;
            $fn .= "/$basename.stacktrace";
            if (open my $fh, '>', $fn) {
                $stack_depth = 1;
                my ($buf, $pack, $file, $line) = ('');
                $buf .= "$pack / $file ($line)\n" while ($pack, $file, $line) = caller $stack_depth++;
                print $fh $buf;
                close $fh;
            }
        }
    }

    return +{
        start   => [gettimeofday],
        tags    => $tags,
        virtual => $virtual,
        rmgenv  => $rmgenv,
        what    => $what,
    };
}

sub stats_validation_done {
    my $self = shift;
    my $data = shift;

    $data->{validation_done} = [gettimeofday];

    return;
}

# Given a generic error, try to turn it into a tag-friendly string which
# might be the same across multiple failures.
sub _normalize_error {
    my $error = shift;

    if (my $whatsit = blessed $error) {
        if ($whatsit eq 'Error::Base') {
            my $type = $error->get_type;    # These are nice short camelCase descriptions
            $error = (
                       $type eq 'InvalidtoBuy'
                    or $type eq 'InvalidtoSell'
            ) ? $error->get_mesg : $type;    # In these special cases, we'd like to get the underlying contract message, instead.
        } elsif ($whatsit eq 'MooseX::Role::Validatable::Error') {
            $error = $error->message;        # These should be sentence-like.
        } else {
            $error = "$error";               # Assume it's stringifiable.
        }
    }

    $error =~ s/(?<=[^A-Z])([A-Z])/ $1/g;    # camelCase to words
    $error =~ s/\[[^\]]+\]//g;               # Bits between [] should be dynamic
    $error = join('_', split /\s+/, lc $error);

    return $error;
}

sub stats_stop {
    my ($self, $data, $error, $extra) = @_;

    my $what = $data->{what};
    my $tags = $data->{tags};

    if ($error) {
        stats_inc("transaction.$what.failure", {tags => [@{$tags->{tags}}, 'reason:' . _normalize_error($error)]});

        return $error;
    }

    my $now = [gettimeofday];
    stats_timing("transaction.$what.elapsed_time", 1000 * tv_interval($data->{start},           $now), $tags);
    stats_timing("transaction.$what.db_time",      1000 * tv_interval($data->{validation_done}, $now), $tags);
    stats_inc("transaction.$what.success", $tags);

    if ($what eq 'batch_buy') {
        my @tags = grep { !/^(?:broker|virtual):/ } @{$tags->{tags}};
        for my $broker (keys %$extra) {
            my $xd = $extra->{$broker};
            my $tags = {tags => ["broker:" . lc($broker), "virtual:" . ($broker =~ /^VR/ ? "yes" : "no"), @tags]};
            stats_count("transaction.buy.attempt", $xd->{attempt}, $tags);
            stats_count("transaction.buy.success", $xd->{success}, $tags);
        }
        return;
    }
    return;
}

sub calculate_max_open_bets {
    my $self   = shift;
    my $client = shift;

    return $client->get_limit_for_open_positions;
}

sub calculate_limits {
    my $self = shift;
    my $client = shift || $self->client;

    my %limits;

    my $static_config = BOM::Config::quants;

    my $contract = $self->contract;
    my $currency = $contract->currency;

    # Client related limit set in client's management page in the backoffice.
    # It is normally used to stop trading activities of a client.
    $limits{max_balance} = $client->get_limit_for_account_balance;
    my $lim = $self->calculate_max_open_bets($client);
    $limits{max_open_bets} = $lim if defined $lim;
    $limits{max_payout_open_bets} = $client->get_limit_for_payout;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    unless ($client->is_virtual) {
        # only pass true values if global limit checks are enabled.
        # actual checks happens in the database

        foreach my $check_name (qw(global_potential_loss global_realized_loss)) {
            my $method       = 'enable_' . $check_name;
            my $alert_method = $check_name . '_alert_threshold';
            if ($app_config->quants->$method) {
                my $threshold = $app_config->quants->$alert_method;
                $limits{$check_name} = {
                    per_market                   => 1,
                    per_symbol                   => 1,
                    per_market_warning_threshold => $threshold,
                    per_symbol_warning_threshold => $threshold,
                };
            }
        }

        foreach my $check_name (qw(user_potential_loss user_realized_loss)) {
            my $method       = 'enable_' . $check_name;
            my $alert_method = $check_name . '_alert_threshold';
            if ($app_config->quants->$method) {
                my $threshold = $app_config->quants->$alert_method;
                $limits{$check_name}{per_user}          = 1;
                $limits{$check_name}{warning_threshold} = $threshold;
            }
        }
    }

    defined($lim = $client->get_limit_for_daily_losses)
        and $limits{max_losses} = $lim;
    defined($lim = $client->get_limit_for_7day_turnover)
        and $limits{max_7day_turnover} = $lim;
    defined($lim = $client->get_limit_for_7day_losses)
        and $limits{max_7day_losses} = $lim;
    defined($lim = $client->get_limit_for_30day_turnover)
        and $limits{max_30day_turnover} = $lim;
    defined($lim = $client->get_limit_for_30day_losses)
        and $limits{max_30day_losses} = $lim;

    $limits{max_turnover} = $client->get_limit_for_daily_turnover;

    my $rp = $contract->risk_profile;
    my @cl_rp = $rp->get_client_profiles($client->loginid, $client->landing_company->short);

    if ($contract->is_binary) {
        # TODO: comebine this with BOM::Product::QuantsConfig
        push @{$limits{specific_turnover_limits}}, @{$rp->get_turnover_limit_parameters(\@cl_rp)};
    } else {
        $limits{lookback_open_position_limit} = $static_config->{lookback_limits}{open_position_limits}{$currency};
        my @non_binary_custom_limits = $rp->get_non_binary_limit_parameters(\@cl_rp);

        my @limits_arr = map { $_->{non_binary_contract_limit} } grep { exists $_->{non_binary_contract_limit}; } @{$non_binary_custom_limits[0]};
        my $custom_limit = min(@limits_arr);
        $limits{lookback_open_position_limit} = $custom_limit if defined $custom_limit;
    }

    return \%limits;
}

sub prepare_bet_data_for_buy {
    my $self = shift;

    my $contract = $self->contract;

    if ($self->purchase_date->is_after($contract->date_start)) {
        my $d1 = $self->purchase_date->datetime_yyyymmdd_hhmmss;
        my $d2 = $contract->date_start->datetime_yyyymmdd_hhmmss;
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'ContractAlreadyStarted',
            -mesg              => "buy at $d1 too late for $d2 contract",
            -message_to_client => BOM::Platform::Context::localize("Start time is in the past."));
    }

    my $bet_class = $BOM::Database::Model::Constants::BET_TYPE_TO_CLASS_MAP->{$contract->code};

    $self->price(financialrounding('price', $contract->currency, $self->price));

    my $bet_params = {
        quantity          => 1,
        short_code        => scalar $contract->shortcode,
        buy_price         => $self->price,
        remark            => $self->comment->[0] || '',
        underlying_symbol => scalar $contract->underlying->symbol,
        bet_type          => scalar $contract->code,
        bet_class         => $bet_class,
        purchase_time     => scalar $self->purchase_date->db_timestamp,
        start_time        => scalar $contract->date_start->db_timestamp,
        expiry_time       => scalar $contract->date_expiry->db_timestamp,
        settlement_time   => scalar $contract->date_settlement->db_timestamp,
        payout_price      => scalar $self->payout,
    };

    $bet_params->{expiry_daily} = 1 if $contract->expiry_daily;
    $bet_params->{fixed_expiry} = 1 if $contract->fixed_expiry;
    if ($contract->tick_expiry) {
        $bet_params->{tick_expiry} = 1;
        $bet_params->{tick_count}  = scalar $contract->tick_count;
    }

    if ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_HIGHER_LOWER_BET) {
        # only store barrier in the database if it is defined.
        # asian contracts have barriers at/after expiry.
        if ($contract->has_user_defined_barrier) {
            $bet_params->{$contract->barrier->barrier_type . '_barrier'} = $contract->barrier->supplied_barrier;
        }
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_DIGIT_BET) {
        $bet_params->{prediction} = $contract->sentiment;
        $bet_params->{last_digit} = $contract->barrier->supplied_barrier;
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_RANGE_BET) {
        $bet_params->{$contract->high_barrier->barrier_type . '_higher_barrier'} = $contract->high_barrier->supplied_barrier;
        $bet_params->{$contract->low_barrier->barrier_type . '_lower_barrier'}   = $contract->low_barrier->supplied_barrier;
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_TOUCH_BET) {
        $bet_params->{$contract->barrier->barrier_type . '_barrier'} = $contract->barrier->supplied_barrier;
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_LOOKBACK_OPTION) {
        $bet_params->{multiplier} = $contract->multiplier;
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_RESET_BET) {
        if ($contract->barrier) {
            $bet_params->{$contract->barrier->barrier_type . '_barrier'} = $contract->barrier->supplied_barrier;
        }
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_CALLPUT_SPREAD) {
        $bet_params->{$contract->high_barrier->barrier_type . '_high_barrier'} = $contract->high_barrier->supplied_barrier;
        $bet_params->{$contract->low_barrier->barrier_type . '_low_barrier'}   = $contract->low_barrier->supplied_barrier;
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_HIGH_LOW_TICK) {
        if ($contract->selected_tick) {
            $bet_params->{selected_tick} = $contract->selected_tick;
        }
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_RUNS) {
        $bet_params->{selected_tick}    = $contract->selected_tick;
        $bet_params->{relative_barrier} = $contract->supplied_barrier;
    } elsif ($bet_params->{bet_class} eq $BOM::Database::Model::Constants::BET_CLASS_MULTIPLIER) {
        $bet_params->{multiplier}            = $contract->multiplier + 0;
        $bet_params->{basis_spot}            = $contract->stop_out->basis_spot + 0;
        $bet_params->{stop_out_order_date}   = $contract->stop_out->order_date->db_timestamp;
        $bet_params->{stop_out_order_amount} = $contract->stop_out->order_amount;

        # take profit is optional. Same goes to stop loss.
        if ($contract->take_profit) {
            $bet_params->{take_profit_order_date}   = $contract->take_profit->order_date->db_timestamp;
            $bet_params->{take_profit_order_amount} = $contract->take_profit->order_amount;
        }

        if ($contract->stop_loss) {
            $bet_params->{stop_loss_order_date}   = $contract->stop_loss->order_date->db_timestamp;
            $bet_params->{stop_loss_order_amount} = $contract->stop_loss->order_amount;
        }
    } else {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'UnsupportedBetClass',
            -mesg              => "Unsupported bet class $bet_params->{bet_class}",
            -message_to_client => BOM::Platform::Context::localize("Unsupported bet class [_1].", $bet_params->{bet_class}),
        );
    }
    my $quants_bet_variables;
    if (my $comment_hash = $self->comment->[1]) {
        $quants_bet_variables = BOM::Database::Model::DataCollection::QuantsBetVariables->new({
            data_object_params => $comment_hash,
        });
    }

    return (
        undef,
        {
            transaction_data => {
                staff_loginid => $self->staff,
                source        => $self->source,
                app_markup    => $self->contract->app_markup_dollar_amount,
            },
            bet_data             => $bet_params,
            quants_bet_variables => $quants_bet_variables,
        });
}

sub prepare_buy {
    my ($self, $skip) = @_;

    if ($self->multiple) {
        for my $m (@{$self->multiple}) {
            next if $m->{code};
            my $c = try { BOM::User::Client->new({loginid => $m->{loginid}}) };
            unless ($c) {
                $m->{code}  = 'InvalidLoginid';
                $m->{error} = BOM::Platform::Context::localize('Invalid loginid');
                next;
            }

            $m->{client} = $c;
            $m->{limits} = $self->calculate_limits($m->{client});
        }
    }

    return $self->prepare_bet_data_for_buy if $skip;
    my @clients = ($self->client);
    if ($self->multiple) {
        @clients = map { $_->{client} } grep { ref $_->{client} } @{$self->multiple};
    } else {
        $self->limits($self->calculate_limits);
    }
    my $error_status = BOM::Transaction::Validation->new({
            transaction => $self,
            clients     => \@clients,
        })->validate_trx_buy();

    return $error_status if $error_status;

    $self->comment(
        _build_pricing_comment({
                contract => $self->contract,
                price    => $self->price,
                ($self->requested_amount)
                ? (requested_price => $self->requested_amount)
                : (),    # requested_price could be ask price or payout. Since this field is embedded in database schema, I don't want to change it.
                ($self->recomputed_amount)
                ? (recomputed_price => $self->recomputed_amount)
                : (),    # recomputed_price could be ask price or payout. Since this field is embedded in database schema, I don't want to change it.
                ($self->price_slippage)
                ? (price_slippage => $self->price_slippage)
                : (),    # price_slippage is the slippage of ask price or payout price.
                action => 'buy'
            })) unless (@{$self->comment});

    return $self->prepare_bet_data_for_buy;
}

sub buy {
    my ($self, %options) = @_;

    $self->action_type('buy');
    my $stats_data = $self->stats_start('buy');

    my $client = $self->client;

    my ($error_status, $bet_data) = $self->prepare_buy($options{skip_validation});
    return $self->stats_stop($stats_data, $error_status) if $error_status;

    $self->stats_validation_done($stats_data);
    my $clientdb = BOM::Database::ClientDB->new({broker_code => $client->broker_code});

    # only fetch fmbid when necessary
    my $fmbid;
    if ($self->contract->category_code eq 'multiplier') {
        $fmbid = $clientdb->get_next_fmbid();
        $bet_data->{bet_data}{fmb_id} = $fmbid;
    }

    my $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new(
        %$bet_data,
        account_data => {
            client_loginid => $client->loginid,
            currency_code  => $self->contract->currency,
        },
        limits => $self->limits,
        db     => $clientdb->db,
    );

    my $error = 1;
    my ($fmb, $txn);

    my $company_limits = BOM::Transaction::CompanyLimits->new(
        contract_data   => $bet_data->{bet_data},
        landing_company => $client->landing_company,
        currency        => $self->contract->currency,
    );

    try {
        $company_limits->add_buys($client);
        # Some contracts require more information besides shortcode to fully defined the contract.
        # To avoid race condition between transaction stream and contract parameters setting,
        # we will set contract parameters before buy.
        my $contract_params = {
            shortcode => $self->contract->shortcode,
            currency  => $client->currency,
            sell_time => undef,
            is_sold   => 0,
            $self->contract->can('available_orders') ? (limit_order => $self->contract->available_orders) : (),
            expiry_time => $self->contract->date_expiry->epoch,
        };

        if ($fmbid) {
            $contract_params->{contract_id} = $fmbid;
            set_contract_parameters($contract_params, $client);
        }

        ($fmb, $txn) = $fmb_helper->buy_bet;

        unless ($fmbid) {
            $contract_params->{contract_id} = $fmb->{id};
            set_contract_parameters($contract_params, $client);
        }

        $self->contract_details($fmb);
        $self->transaction_details($txn);
        $error = 0;
    }
    catch {
        # if $error_status is defined, return it
        # otherwise the function re-throws the exception
        stats_inc('database.consistency.inverted_transaction', {tags => ['broker_code:' . $client->broker_code]});
        my $contract_id = $fmbid // (defined $fmb ? $fmb->{id} : undef);
        delete_contract_parameters($contract_id, $client) if $contract_id;
        $company_limits->reverse_buys($client);
        $error_status = $self->_recover($_);
    };
    return $self->stats_stop($stats_data, $error_status) if $error_status;

    return $self->stats_stop(
        $stats_data,
        Error::Base->cuss(
            -quiet             => 1,
            -type              => 'GeneralError',
            -mesg              => 'Cannot perform database action',
            -message_to_client => BOM::Platform::Context::localize('A general error has occurred.'),
        )) if $error;

    $self->stats_stop($stats_data);

    $self->balance_after($txn->{balance_after});
    $self->transaction_id($txn->{id});
    $self->contract_id($fmb->{id});

    $client->increment_social_responsibility_values({
            turnover     => $fmb->{buy_price},
            num_contract => 1
        }) if $client->landing_company->social_responsibility_check_required;

    enqueue_new_transaction(_get_params_for_expiryqueue($self));    # For soft realtime expiration notification.

    return;
}

# expected parameters:
# $self->multiple
#   an array of hashes. Elements with a key "code" are ignored. They are
#   thought to be already erroneous. Otherwise the element should contain
#   a "loginid" key.
#   The following keys are added:
#   * client: the BOM::User::Client object corresponding to the loginid
#   * limits: a hash representing the betting limits of this client
#   * fmb and txn: the FMB and transaction records that have been written
#     to the database in case of success
#   * code and error: in case of an error during the transaction these keys
#     contain the error description corresponding to the usual -type and
#     -message_to_client members of an Error::Base object.
# $self->contract
#   the contract
# $self->staff
# $self->source
# ...
#
# set or modified during operation:
# $self->price
#   the price
# @{$self->multiple}
#   see above
#
# return value:
#   - empty list on success. Success means the database function has been called.
#     It does not mean any contract has been bought.
#   - an Error::Base object indicates that something more fundamental went wrong.
#     For instance the contract's start date may be in the past.
#
# Exceptions:
#   The function may throw exceptions. However, it is guaranteed that after
#   contract validation no exception whatsoever is thrown. That means there
#   is no way for a contract to be bought but not reported back to the caller.

sub batch_buy {
    my ($self, %options) = @_;

    # we do not support batch buy for multiplier
    if ($self->contract->category_code eq 'multiplier') {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'UnsupportedBatchBuy',
            -mesg              => "Multiplier not supported in batch_buy",
            -message_to_client => localize('MULTUP and MULTDOWN are not supported.'),
        );
    }

    # TODO: shall we allow this operation only if $self->client is real-money?
    #       Or allow virtual $self->client only if all other clients are also
    #       virtual?
    $self->action_type('buy');
    my $stats_data = $self->stats_start('batch_buy');

    my ($error_status, $bet_data) = $self->prepare_buy($options{skip_validation});

    return $self->stats_stop($stats_data, $error_status) if $error_status;

    $self->stats_validation_done($stats_data);

    my %per_broker;
    for my $m (@{$self->multiple}) {
        if ($m->{code}) {
            $m->{message_to_client} = $m->{error} if defined $m->{error};
            next;
        }

        push @{$per_broker{$m->{client}->broker_code}}, $m;
    }

    my %stat = map { $_ => {attempt => 0 + @{$per_broker{$_}}} } keys %per_broker;

    for my $broker (keys %per_broker) {
        my $list = $per_broker{$broker};
        # with hash key caching introduced in recent perl versions
        # the "map sort map" pattern does not make sense anymore.

        # this sorting is to prevent deadlocks in the database
        @$list = sort { $a->{loginid} cmp $b->{loginid} } @$list;

        my @general_error = ('UnexpectedError', BOM::Platform::Context::localize('An unexpected error occurred'));

        try {
            my $currency   = $self->contract->currency;
            my $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new(
                %$bet_data,
                # great readablility provided by our tidy rules
                account_data => [map                                      { +{client_loginid => $_->{loginid}, currency_code => $currency} } @$list],
                limits       => [map                                      { $_->{limits} } @$list],
                db           => BOM::Database::ClientDB->new({broker_code => $broker})->db,
            );

            my @clients = map { $_->{client} } @$list;
            my $company_limits = BOM::Transaction::CompanyLimits->new(
                contract_data   => $bet_data->{bet_data},
                landing_company => $clients[0]->landing_company,
                currency        => $self->contract->currency,
            );
            $company_limits->add_buys(@clients);

            my $success = 0;
            my $result  = $fmb_helper->batch_buy_bet;
            for my $el (@$list) {
                my $res = shift @$result;
                if (my $ecode = $res->{e_code}) {
                    # map DB errors to client messages
                    if (my $ref = $known_errors{$ecode}) {
                        my $error = (
                            ref $ref eq 'CODE'
                            ? $ref->($self, $el->{client}, $res->{e_description})
                            : $ref
                        );
                        $el->{code}              = $error->{-type};
                        $el->{error}             = $error->{-message_to_client};
                        $el->{message_to_client} = $error->{-message_to_client};
                    } else {
                        @{$el}{qw/code message_to_client/} = @general_error;
                    }
                } else {
                    $el->{fmb} = $res->{fmb};
                    $el->{txn} = $res->{txn};
                    $success++;
                }
            }

            $company_limits->reverse_buys(map { $_->{client} } grep { defined $_->{error} } @$list);

            $stat{$broker}->{success} = $success;
            enqueue_multiple_new_transactions(_get_params_for_expiryqueue($self), _get_list_for_expiryqueue($list));
        }
        catch {
            warn __PACKAGE__ . ':(' . __LINE__ . '): ' . $_;    # log it

            for my $el (@$list) {
                @{$el}{qw/code error/} = @general_error unless $el->{code} or $el->{fmb};
            }
        };
    }

    $self->stats_stop($stats_data, undef, \%stat);

    return;
}

sub prepare_bet_data_for_sell {
    my $self = shift;
    my $contract = shift || $self->contract;

    $self->price(financialrounding('price', $contract->currency, $self->price));

    my $bet_params = {
        id         => scalar $self->contract_id,
        sell_price => scalar $self->price,
        sell_time  => scalar $contract->date_pricing->db_timestamp,
        quantity   => 1,
        $contract->category_code eq 'asian' && $contract->is_after_settlement
        ? (absolute_barrier => scalar $contract->barrier->as_absolute)
        : (),
    };

    # we need to verify child table for multiplier to avoid cases where a contract
    # is sold while it is being updated via a difference process.
    if ($contract->category_code eq 'multiplier') {
        $bet_params->{verify_child} = _get_info_to_verify_child($self->contract_id, $contract);
    }
    my $quants_bet_variables;
    if (my $comment_hash = $self->comment->[1]) {
        $quants_bet_variables = BOM::Database::Model::DataCollection::QuantsBetVariables->new({
            data_object_params => $comment_hash,
        });
    }

    return (
        undef,
        {
            transaction_data => {
                staff_loginid => $self->staff,
                source        => $self->source,
            },
            bet_data             => $bet_params,
            quants_bet_variables => $quants_bet_variables,
        });
}

sub prepare_sell {
    my ($self, $skip) = @_;

    if ($self->multiple) {
        for my $m (@{$self->multiple}) {
            next if $m->{code};
            my $c = try { BOM::User::Client->new({loginid => $m->{loginid}}) };
            unless ($c) {
                $m->{code}  = 'InvalidLoginid';
                $m->{error} = BOM::Platform::Context::localize('Invalid loginid');
                next;
            }

            $m->{client} = $c;
        }
    }

    return $self->prepare_bet_data_for_sell if $skip;

    ### Prepare clients list, get uniq only...
    my @clients = ($self->client);
    if ($self->multiple) {
        @clients = map { $_->{client} } grep { ref $_->{client} } @{$self->multiple};
    }

    my $error_status = BOM::Transaction::Validation->new({
            transaction => $self,
            clients     => \@clients,
        })->validate_trx_sell();

    return $error_status if $error_status;

    $self->comment(
        _build_pricing_comment({
                contract => $self->contract,
                price    => $self->price,
                ($self->requested_amount)
                ? (requested_price => $self->requested_amount)
                : (),    # requested_price is bid price send by user.
                ($self->recomputed_amount)
                ? (recomputed_price => $self->recomputed_amount)
                : (),    # recomputed_price is recomputed bid price
                ($self->price_slippage)
                ? (price_slippage => $self->price_slippage)
                : (),    # price_slippage is the difference between the requested bid price and the recomputed bid price.
                action => 'sell'
            })) unless @{$self->comment};

    return $self->prepare_bet_data_for_sell;
}

sub sell {
    my ($self, %options) = @_;

    $self->action_type('sell');
    my $stats_data = $self->stats_start('sell');

    my ($error_status, $bet_data) = $self->prepare_sell($options{skip_validation});
    return $self->stats_stop($stats_data, $error_status) if $error_status;

    my $client = $self->client;

    $bet_data->{account_data} = {
        client_loginid => $client->loginid,
        currency_code  => $self->contract->currency,
    };

    $bet_data->{bet_data}{is_expired} = $self->contract->is_expired;
    $self->stats_validation_done($stats_data);

    my $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new(
        %$bet_data,
        db => BOM::Database::ClientDB->new({broker_code => $client->broker_code})->db,
    );

    my $error = 1;
    my ($fmb, $txn, $buy_txn_id);
    try {
        ($fmb, $txn, $buy_txn_id) = $fmb_helper->sell_bet;
        delete_contract_parameters($fmb->{id}, $client) if $fmb->{id};
        $error = 0;
    }
    catch {
        # if $error_status is defined, return it
        # otherwise the function re-throws the exception
        $error_status = $self->_recover($_);
    };
    return $self->stats_stop($stats_data, $error_status) if $error_status;

    return $self->stats_stop(
        $stats_data,
        Error::Base->cuss(
            -quiet             => 1,
            -type              => 'GeneralError',
            -mesg              => 'Cannot perform database action',
            -message_to_client => BOM::Platform::Context::localize('A general error has occurred.'),
        )) if $error;

    return $self->stats_stop(
        $stats_data,
        Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NoOpenPosition',
            -mesg              => 'No such open contract.',
            -message_to_client => BOM::Platform::Context::localize('This contract was not found among your open positions.'),
        )) unless defined $txn->{id} && defined $buy_txn_id;

    $self->stats_stop($stats_data);

    $self->balance_after($txn->{balance_after});
    $self->transaction_id($txn->{id});
    $self->reference_id($buy_txn_id);

    if ($client->landing_company->social_responsibility_check_required) {
        my $loss = $fmb->{buy_price} - $fmb->{sell_price};

        $client->increment_social_responsibility_values({
            losses => $loss > 0 ? $loss : 0,
        });
    }

    BOM::Transaction::CompanyLimits->new(
        contract_data   => $fmb,
        currency        => $self->contract->currency,
        landing_company => $client->landing_company,
    )->add_sells($client);

    return;
}

sub sell_by_shortcode {
    my ($self, %options) = @_;

    $self->action_type('sell');
    my $stats_data = $self->stats_start('sell');

    if ($self->contract->category_code eq 'multiplier') {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'UnsupportedBatchBuy',
            -mesg              => "Multiplier not supported in sell_by_shortcode",
            -message_to_client => localize('MULTUP and MULTDOWN are not supported.'),
        );
    }

    my ($error_status, $bet_data) = $self->prepare_sell($options{skip});
    $bet_data->{bet_data}{is_expired} = $self->contract->is_expired;
    return $self->stats_stop($stats_data, $error_status) if $error_status;

    $self->stats_validation_done($stats_data);

    my $currency = $self->contract->currency;

    my %per_broker;
    for my $m (@{$self->multiple}) {
        if ($m->{code}) {
            $m->{message_to_client} = $m->{error} if defined $m->{error};
            next;
        }
        push @{$per_broker{$m->{client}->broker_code}}, $m;
    }

    my %stat = map { $_ => {attempt => 0 + @{$per_broker{$_}}} } keys %per_broker;

    for my $broker (keys %per_broker) {
        my $list    = $per_broker{$broker};
        my $success = 0;
        # with hash key caching introduced in recent perl versions
        # the "map sort map" pattern does not make sense anymore.

        # this sorting is to prevent deadlocks in the database
        @$list = sort { $a->{loginid} cmp $b->{loginid} } @$list;

        my $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new(
            %$bet_data,
            account_data => [map                                      { +{client_loginid => $_->{loginid}, currency_code => $currency} } @$list],
            db           => BOM::Database::ClientDB->new({broker_code => $broker})->db,
        );
        try {
            my $res = $fmb_helper->sell_by_shortcode($self->contract->shortcode);

            foreach my $r (@$list) {
                my $res_row = shift @$res;
                if (my $ecode = $res_row->{e_code}) {
                    # map DB errors to client messages
                    if (my $ref = $known_errors{$ecode}) {
                        my $error = (
                            ref $ref eq 'CODE'
                            ? $ref->($self, $r->{client}, $res_row->{e_description})
                            : $ref
                        );
                        $r->{code}              = $error->{-type};
                        $r->{message_to_client} = $error->{-message_to_client};
                        $r->{error}             = $error->{-message_to_client};

                    } else {
                        @{$r}{qw/code error/} = ('UnexpectedError' . $ecode, BOM::Platform::Context::localize('An unexpected error occurred'));
                    }
                } else {
                    $r->{tnx}       = $res_row->{txn};
                    $r->{fmb}       = $res_row->{fmb};
                    $r->{buy_tr_id} = $res_row->{buy_tr_id};

                    my $client = $r->{client};

                    # We cannot batch add sells; buy price may vary even with the same short code
                    BOM::Transaction::CompanyLimits->new(
                        contract_data   => $res_row->{fmb},
                        currency        => $self->contract->currency,
                        landing_company => $client->landing_company,
                    )->add_sells($client);

                    $success++;
                }
            }
            $stat{$broker}->{success} = $success;
        }
        catch {
            warn __PACKAGE__ . ':(' . __LINE__ . '): ' . $_;    # log it
            for my $el (@$list) {
                @{$el}{qw/code error/} = ('UnexpectedError', BOM::Platform::Context::localize('An unexpected error occurred'))
                    unless $el->{code} or $el->{fmb};
            }
        };
    }

    $self->stats_stop($stats_data, undef, \%stat);

    return;
}

=head1 METHODS

=head2 C<< $self->_recover($error) >>

This function tries to recover from an unsuccessful buy/sell.
It may decide to retry the operation. And it may decide to
sell expired bets before doing so.

=head4 Parameters

=over 4

=item * C<< $error >>
the error exception thrown by BOM::Platform::Data::Persistence::DB::_handle_errors

=back

=head3 Return Value

L<Error::Base> object
which means an unrecoverable but expected condition has been found.
Typically that means a precondition, like sufficient balance, was
not met.

=head3 Exceptions

In case of an unexpected error, the exception is re-thrown unmodified.

=cut

%known_errors = (
    BI001 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $limit = formatnumber('amount', $currency, $client->get_limit_for_daily_turnover);

        my $error_message =
            BOM::Platform::Context::localize('Purchasing this contract will cause you to exceed your daily turnover limit of [_1][_2].',
            $currency, $limit);

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'DailyTurnoverLimitExceeded',
            -mesg              => "Client has exceeded a daily turnover of $currency$limit",
            -message_to_client => $error_message,
        );
    },
    BI002 => sub {
        my $self   = shift;
        my $client = shift;

        my $limit = $self->calculate_max_open_bets($client);
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'OpenPositionLimit',
            -mesg              => "Client has reached the limit of $limit open positions.",
            -message_to_client => BOM::Platform::Context::localize(
                'Sorry, you cannot hold more than [_1] contracts at a given time. Please wait until some contracts have closed and try again.',
                $limit
            ),
        );
    },
    BI003 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $account  = BOM::Database::DataMapper::Account->new({
            client_loginid => $client->loginid,
            currency_code  => $currency,
        });

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'InsufficientBalance',
            -message           => 'Client\'s account balance was insufficient to buy bet.',
            -message_to_client => BOM::Platform::Context::localize(
                'Your account balance ([_1][_2]) is insufficient to buy this contract ([_1][_3]).',
                $currency,
                formatnumber('amount', $currency, $account->get_balance()),
                formatnumber('price',  $currency, $self->price)));
    },
    BI008 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $limit = formatnumber('amount', $currency, $client->get_limit_for_account_balance);

        my $account = BOM::Database::DataMapper::Account->new({
            client_loginid => $client->loginid,
            currency_code  => $currency,
        });
        my $balance = formatnumber('amount', $currency, $account->get_balance());

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'AccountBalanceExceedsLimit',
            -mesg              => 'Client balance is above the allowed limits',
            -message_to_client => BOM::Platform::Context::localize(
                'Sorry, your account cash balance is too high ([_1]). Your maximum account balance is [_2].', "$currency$balance",
                "$currency$limit"
            ),
        );
    },
    BI009 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $limit = formatnumber('amount', $currency, $client->get_limit_for_payout);

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'OpenPositionPayoutLimit',
            -mesg              => 'Client has reached maximum net payout for open positions',
            -message_to_client => BOM::Platform::Context::localize(
                'Sorry, the aggregate payouts of contracts on your account cannot exceed [_1][_2].',
                $currency, $limit
            ),
        );
    },
    BI010 => Error::Base->cuss(
        -quiet             => 1,
        -type              => 'PromoCodeLimitExceeded',
        -mesg              => 'Client won more than 25 times of the promo code amount',
        -message_to_client => BOM::Platform::Context::localize(
            'Your account has exceeded the trading limit with free promo code, please deposit if you wish to continue trading.'),
    ),
    BI011 => sub {
        my $self   = shift;
        my $client = shift;
        my $msg    = shift;

        my $limit_name = 'Unknown';
        $msg =~ /^.+: ([^,]+)/ and $limit_name = $1;

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'ProductSpecificTurnoverLimitExceeded',
            -mesg              => 'Exceeds turnover limit on ' . $limit_name,
            -message_to_client => BOM::Platform::Context::localize('You have exceeded the daily limit for contracts of this type.'),
        );
    },
    BI012 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $limit = formatnumber('amount', $currency, $client->get_limit_for_daily_losses);

        my $error_message = BOM::Platform::Context::localize('You have exceeded your daily limit on losses of [_1][_2].', $currency, $limit);

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'DailyLossLimitExceeded',
            -mesg              => "Client has exceeded his daily loss limit of $currency$limit",
            -message_to_client => $error_message,
        );
    },
    BI013 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $limit = formatnumber('amount', $currency, $client->get_limit_for_7day_turnover);

        my $error_message =
            BOM::Platform::Context::localize('Purchasing this contract will cause you to exceed your 7-day turnover limit of [_1][_2].',
            $currency, $limit);

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => '7DayTurnoverLimitExceeded',
            -mesg              => "Client has exceeded a 7-day turnover of $currency$limit",
            -message_to_client => $error_message,
        );
    },
    BI014 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $limit = formatnumber('amount', $currency, $client->get_limit_for_7day_losses);

        my $error_message = BOM::Platform::Context::localize('You have exceeded your 7-day limit on losses of [_1][_2].', $currency, $limit);

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => '7DayLossLimitExceeded',
            -mesg              => "Client has exceeded his 7-day loss limit of $currency$limit",
            -message_to_client => $error_message,
        );
    },
    # BI015 deprecated as spread is removed
    BI016 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $limit = formatnumber('amount', $currency, $client->get_limit_for_30day_turnover);

        my $error_message =
            BOM::Platform::Context::localize('Purchasing this contract will cause you to exceed your 30-day turnover limit of [_1][_2].',
            $currency, $limit);

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => '30DayTurnoverLimitExceeded',
            -mesg              => "Client has exceeded a 30-day turnover of $currency$limit",
            -message_to_client => $error_message,
        );
    },
    BI017 => sub {
        my $self   = shift;
        my $client = shift;

        my $currency = $self->contract->currency;
        my $limit = formatnumber('amount', $currency, $client->get_limit_for_30day_losses);

        my $error_message = BOM::Platform::Context::localize('You have exceeded your 30-day limit on losses of [_1][_2].', $currency, $limit);

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => '30DayLossLimitExceeded',
            -mesg              => "Client has exceeded his 30-day loss limit of $currency$limit",
            -message_to_client => $error_message,
        );
    },
    BI018 => sub {
        my $self   = shift;
        my $client = shift;

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => 'DailyProfitLimitExceeded',
            -mesg              => 'Exceeds daily profit limit',
            -message_to_client => BOM::Platform::Context::localize('No further trading is allowed for the current trading session.'),
        );
    },
    BI019 => sub {
        my $self   = shift;
        my $client = shift;
        my $msg    = shift;

        my $limit_name = 'Unknown';
        $msg =~ /^.+: ([^,]+)/ and $limit_name = $1;

        return Error::Base->cuss(
            -quiet             => 1,
            -type              => $limit_name . 'Exceeded',
            -mesg              => 'Exceeds open position limit on ' . $limit_name,
            -message_to_client => BOM::Platform::Context::localize('You have exceeded the open position limit for contracts of this type.'),
        );
    },
    BI050 => sub {
        my $self   = shift;
        my $client = shift;
        my $msg    = shift;

        Error::Base->cuss(
            -quiet             => 1,
            -type              => 'NoOpenPosition',
            -mesg              => $msg,
            -message_to_client => BOM::Platform::Context::localize('This contract was not found among your open positions.'),
        );
    },
    BI051 => sub {
        my $self   = shift;
        my $client = shift;
        my $msg    = shift;

        Error::Base->cuss(
            -quiet => 1,
            -type  => 'CompanyWideLimitExceeded',
            -mesg  => 'company-wide risk limit reached',
            -message_to_client =>
                BOM::Platform::Context::localize('No further trading is allowed on this contract type for the current trading session.'),
        );
    },
    BI104 => sub {
        my $msg = 'Transaction time is too old (check server time), ' . $_[2];

        warn $msg;

        Error::Base->cuss(
            -quiet             => 1,
            -type              => 'TransactionTimeTooOld',
            -mesg              => $msg,
            -message_to_client => BOM::Platform::Context::localize('Cannot create contract'),
        );
    },
    BI105 => sub {
        my $msg = 'Transaction time is too new (check server time), ' . $_[2];

        warn $msg;

        Error::Base->cuss(
            -quiet             => 1,
            -type              => 'TransactionTimeTooYoung',
            -mesg              => $msg,
            -message_to_client => BOM::Platform::Context::localize('Cannot create contract'),
        );
    },
    BI054 => Error::Base->cuss(
        -quiet             => 1,
        -type              => 'SymbolMissingInBetMarketTable',
        -mesg              => 'Symbol missing in bet.limits_market_mapper table',
        -message_to_client => BOM::Platform::Context::localize('Trading is suspended for this instrument.'),
    ),
    BI103 => Error::Base->cuss(
        -quiet             => 1,
        -type              => 'RoundingExceedPermittedEpsilon',
        -mesg              => 'Rounding exceed permitted epsilon',
        -message_to_client => BOM::Platform::Context::localize('Only a maximum of two decimal points are allowed for the amount.'),
    ),
    BI005 => Error::Base->cuss(
        -quiet             => 1,
        -type              => 'LookbackOpenPositionLimitExceeded',
        -mesg              => 'Lookback open positions limit exceeded',
        -message_to_client => BOM::Platform::Context::localize('Lookback open positions limit exceeded.'),
    ),
    BI020 => Error::Base->cuss(
        -quiet             => 1,
        -type              => 'PerUserPotentialLossLimitReached',
        -mesg              => 'per user potential loss limit reached',
        -message_to_client => BOM::Platform::Context::localize('This contract is currently unavailable due to market conditions'),
    ),
    BI022 => Error::Base->cuss(
        -quiet             => 1,
        -type              => 'PerUserRealizedLossLimitReached',
        -mesg              => 'per user realized loss limit reached',
        -message_to_client => BOM::Platform::Context::localize('This contract is currently unavailable due to market conditions'),
    ),
    BI023 => Error::Base->cuss(
        -quiet             => 1,
        -type              => 'SellFailureDueToUpdate',
        -mesg              => 'Contract is updated while attempting to sell',
        -message_to_client => BOM::Platform::Context::localize('Sell failed because contract was updated.'),
    ),
);

sub _recover {
    my $self   = shift;
    my $err    = shift;
    my $client = shift;
    if (blessed($self)) {
        $client //= $self->client;
    }

    if (ref($err) eq 'ARRAY') {    # special BINARY code
        my $ref = $known_errors{$err->[0]};
        return ref $ref eq 'CODE' ? $ref->($self, $client, $err->[1]) : $ref if $ref;
    } else {
        # TODO: recover from deadlocks & co.
    }
    die $err;
}

sub format_error {
    my ($self, %args) = @_;
    my $err           = $args{err};
    my $client        = $args{client};
    my $type          = $args{type} // 'InternalError';             # maybe caller know the type. If the err cannot be parsed, then we use this value
    my $msg           = Dumper($err);
    my $msg_to_client = $args{msg_to_client} // 'Internal Error';
    return try {
        return $self->_recover($err, $client);
    }
    catch {
        return Error::Base->cuss(
            -quiet             => 1,
            -type              => $type,
            -mesg              => $msg,
            -message_to_client => BOM::Platform::Context::localize($msg_to_client),
        );
    }
}

sub _build_pricing_comment {
    my $args = shift;

    my ($contract, $price, $action) = @{$args}{qw/contract price action/};

    my @comment_fields = @{$contract->pricing_details($action)};

    #NOTE The handling of sell whether the bid is sucess or not will be handle in next card
    # only manual sell and buy has a price
    push @comment_fields, (trade => $price) if $price;

    # Record price slippage, requested_price and recomputed_price in quants bet variable.
    # To always reproduce ask price, we would want to record the slippage allowed during transaction.
    push @comment_fields, map { defined $args->{$_} ? ($_ => $args->{$_}) : () } qw/price_slippage requested_price recomputed_price/;

    my $comment_str = sprintf join(' ', ('%s[%0.5f]') x (@comment_fields / 2)), @comment_fields;

    return [$comment_str, {@comment_fields}];
}

=head2 sell_expired_contracts

Static function: Sells expired contracts.
For contracts with missing market data, settle them manually for real money accounts, but sell with purchase price for virtual account
Returns: HashRef, with:
'total_credited', total amount credited to Client
'skip_contract', count for expired contracts that failed to be sold
'failures', the failure information

=cut

my %source_to_sell_type = (
    2 => 'expiryd',    # app id for `Binary.com expiryd.pl` in auth db => oauth.apps table
);

sub sell_expired_contracts {
    my $args          = shift;
    my $client        = $args->{client};
    my $source        = $args->{source};
    my $contract_ids  = $args->{contract_ids};
    my $collect_stats = $args->{collect_stats};

    my $currency = $client->currency;
    my $loginid  = $client->loginid;

    my $result = {
        skip_contract => $contract_ids ? (scalar @$contract_ids) : 0,
        total_credited      => 0,
        number_of_sold_bets => 0,
        failures            => [],
    };

    my $mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        client_loginid => $loginid,
        currency_code  => $currency,
        broker_code    => $client->broker_code,
        operation      => 'replica',
    });

    my $clientdb = BOM::Database::ClientDB->new({
        broker_code => $client->broker_code,
        operation   => 'replica',
    });
    my $bets =
          (defined $contract_ids)
        ? [map { $_->financial_market_bet_record } @{$mapper->get_fmb_by_id($contract_ids)}]
        : $clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)',
        [$client->loginid, $client->currency, ($args->{only_expired} ? 'true' : 'false')]);

    return $result unless $bets and @$bets;

    my $now = Date::Utility->new;
    my @bets_to_sell;
    my @quants_bet_variables;
    my @transdata;
    my %stats_attempt;
    my %stats_failure;

    for my $bet (@$bets) {
        my $contract;
        my $error;
        my $failure = {fmb_id => $bet->{id}};
        try {
            my $bet_params = shortcode_to_parameters($bet->{short_code}, $currency);
            if ($bet->{bet_class} eq 'multiplier') {
                # for multiplier, we need to combine information on the child table to complete a contract
                $bet_params->{limit_order} = extract_limit_orders($bet);
            }
            $contract = produce_contract($bet_params);
        }
        catch { $error = 1; };
        if ($error) {
            $failure->{reason} = 'Could not instantiate contract object';
            push @{$result->{failures}}, $failure;
            next;
        }

        # if contract is not expired, don't bother to do anything
        next unless $contract->is_expired;
        my $logging_class = $BOM::Database::Model::Constants::BET_TYPE_TO_CLASS_MAP->{$contract->code}
            or warn "No logging class found for contract type " . $contract->code;
        $logging_class //= 'INVALID';
        $stats_attempt{$logging_class}++;

        try {
            if ($contract->is_valid_to_sell) {
                @{$bet}{qw/sell_price sell_time is_expired/} =
                    ($contract->bid_price, $contract->date_pricing->db_timestamp, $contract->is_expired);
                $bet->{absolute_barrier} = $contract->barrier->as_absolute
                    if $contract->category_code eq 'asian' and $contract->is_after_settlement;

                if ($contract->category_code eq 'multiplier') {
                    $bet->{verify_child} = _get_info_to_verify_child($bet->{id}, $contract);
                }

                $bet->{quantity} = 1;
                push @bets_to_sell, $bet;
                push @transdata,
                    {
                    staff_loginid => 'AUTOSELL',
                    source        => $source,
                    };

                # price_slippage will not happen to expired contract, hence not needed.
                push @quants_bet_variables,
                    BOM::Database::Model::DataCollection::QuantsBetVariables->new({
                        data_object_params => _build_pricing_comment({
                                contract => $contract,
                                action   => 'autosell_expired_contract',
                            }
                        )->[1],
                    });

                # collect stats about expiryd process they should be removed later
                # expiryd only send one contract id so it's safe to return single value.
                # this a hack that should be removed later when examination is done.
                if ($collect_stats) {
                    $result->{contract_expiry_epoch} = $contract->exit_tick->epoch if $contract->exit_tick;
                    $result->{contract_expiry_epoch} = $contract->hit_tick->epoch if $contract->is_path_dependent and $contract->hit_tick;
                    $result->{bet_type}    = $bet->bet_type;
                    $result->{expiry_type} = $contract->expiry_type;
                }

            } elsif ($client->is_virtual and $now->epoch >= $contract->date_settlement->epoch + 3600) {
                # for virtual, if can't settle bet due to missing market data, sell contract with buy price
                @{$bet}{qw/sell_price sell_time is_expired/} = ($bet->{buy_price}, $now->db_timestamp, $contract->is_expired);
                $bet->{quantity} = 1;
                push @bets_to_sell, $bet;
                push @transdata,
                    {
                    staff_loginid => 'AUTOSELL',
                    source        => $source,
                    };
                #empty list for virtual
                push @quants_bet_variables,
                    BOM::Database::Model::DataCollection::QuantsBetVariables->new({
                        data_object_params => {},
                    });
            } else {
                my $cpve = $contract->primary_validation_error;
                if ($cpve) {
                    my ($error_msg, $reason) =
                         !($contract->is_expired and $contract->is_valid_to_sell)
                        ? ('NotExpired', 'not expired')
                        : (_normalize_error($cpve), $cpve->message);
                    $stats_failure{$logging_class}{$error_msg}++;
                    $failure->{reason} = $reason;
                } else {
                    $failure->{reason} = "Unknown failure in sell_expired_contracts, shortcode: " . $contract->shortcode;
                    warn 'validation error missing when contract is invalid to sell, shortcode['
                        . $contract->shortcode
                        . '] pricing time ['
                        . $contract->date_pricing->datetime . ']';
                }
                push @{$result->{failures}}, $failure;
            }
        }
        catch {
            my $err = $_;
            if ($err =~ /^Requesting for historical period data without a valid DB connection/) {
                # seems an issue in /Quant/Framework/EconomicEventCalendar.pm get_latest_events_for_period:
                # live pricing condition was not ok and get_for_period was called for
                # Data::Chronicle::Reader without dbic
                $err .= "Data::Chronicle::Reader get_for_period call without dbic: Details: contract shortcode: " . $contract->shortcode . "\n";
            }
            warn 'SellExpiredContract Exception: ' . __PACKAGE__ . ':(' . __LINE__ . '): ' . $err;    # log it
        };
    }

    my $broker    = lc($client->broker_code);
    my $virtual   = $client->is_virtual ? 'yes' : 'no';
    my $rmgenv    = BOM::Config::env;
    my $sell_type = (defined $source and exists $source_to_sell_type{$source}) ? $source_to_sell_type{$source} : 'expired';
    my @tags      = ("broker:$broker", "virtual:$virtual", "rmgenv:$rmgenv", "sell_type:$sell_type");

    for my $class (keys %stats_attempt) {
        stats_count("transaction.sell.attempt", $stats_attempt{$class}, {tags => [@tags, "contract_class:$class"]});
    }
    for my $class (keys %stats_failure) {
        for my $reason (keys %{$stats_failure{$class}}) {
            stats_count(
                "transaction.sell.failure",
                $stats_failure{$class}{$reason},
                {tags => [@tags, "contract_class:$class", "reason:" . _normalize_error($reason)]});
        }
    }

    return $result unless @bets_to_sell;    # nothing to do

    my $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new(
        transaction_data => \@transdata,
        bet_data         => \@bets_to_sell,
        account_data     => {
            client_loginid => $loginid,
            currency_code  => $currency
        },
        db                   => BOM::Database::ClientDB->new({broker_code => $client->broker_code})->db,
        quants_bet_variables => \@quants_bet_variables,
    );

    my $sold;
    try {
        $sold = $fmb_helper->batch_sell_bet;
        delete_contract_parameters($_->{id}, $client) for (@bets_to_sell);
    }
    catch {
        warn(ref eq 'ARRAY' ? "@$_" : "$_");
        return [];
    };

    if (not $sold or @bets_to_sell > @$sold) {
        # We missed some, let's figure out which ones they are.
        my %sold_fmbs = map { $_->{fmb}->{id} => 1 } @{$sold // []};
        my %missed;
        foreach my $bet (@bets_to_sell) {
            next if $sold_fmbs{$bet->{id}};    # Was not missed.
            $missed{$bet->{bet_class}}++;
            push @{$result->{failures}},
                {
                fmb_id => $bet->{id},
                reason => _normalize_error("TransactionFailure")};
        }
        foreach my $class (keys %missed) {
            stats_count("transaction.sell.failure", $missed{$class},
                {tags => [@tags, "contract_class:$class", "reason:" . _normalize_error("TransactionFailure")]});

        }
    }

    return $result unless $sold and @$sold;    # nothing has been sold

    my $skip_contract  = @$bets - @$sold;
    my $total_credited = 0;
    my %stats_success;

    my $total_losses = 0;

    my $sr_check_required = $client->landing_company->social_responsibility_check_required;

    for my $t (@$sold) {

        my $fmb = $t->{fmb};

        $total_credited += $t->{txn}->{amount};
        $stats_success{$fmb->{bet_class}}->[0]++;
        $stats_success{$fmb->{bet_class}}->[1] += $t->{txn}->{amount};

        if ($sr_check_required) {
            $total_losses += $fmb->{sell_price} + 0 ? 0 : $fmb->{buy_price};
        }

        BOM::Transaction::CompanyLimits->new(
            contract_data   => $fmb,
            currency        => $currency,
            landing_company => $client->landing_company,
        )->add_sells($client);
    }

    $client->increment_social_responsibility_values({
            losses => $total_losses,
        }) if $sr_check_required;

    for my $class (keys %stats_success) {
        stats_count("transaction.sell.success", $stats_success{$class}->[0], {tags => [@tags, "contract_class:$class"]});
    }

    $result->{skip_contract}       = $skip_contract;
    $result->{total_credited}      = $total_credited;
    $result->{number_of_sold_bets} = 0 + @$sold;

    return $result;
}

sub report {
    my $self = shift;
    return
          "Transaction Report:\n"
        . sprintf("%30s: %s\n", 'Client',                 $self->client)
        . sprintf("%30s: %s\n", 'Contract',               $self->contract->code)
        . sprintf("%30s: %s\n", 'Price',                  $self->price)
        . sprintf("%30s: %s\n", 'Payout',                 $self->payout)
        . sprintf("%30s: %s\n", 'Amount Type',            $self->amount_type)
        . sprintf("%30s: %s\n", 'Comment',                $self->comment->[0] || '')
        . sprintf("%30s: %s\n", 'Staff',                  $self->staff)
        . sprintf("%30s: %s",   'Transaction Parameters', Dumper($self->transaction_parameters))
        . sprintf("%30s: %s\n", 'Transaction ID',         $self->transaction_id || -1)
        . sprintf("%30s: %s\n", 'Purchase Date',          $self->purchase_date->datetime_yyyymmdd_hhmmss);
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
                };
            }
        }
    } elsif (ref $contract_params eq 'HASH') {
        my $basis_spot = $contract_params->{basis_spot};
        foreach my $order (@supported_order) {
            my $order_date = join '_', ($order, 'order_date');
            if ($contract_params->{$order_date}) {
                my $order_amount = join '_', ($order, 'order_amount');
                $orders{$order} = {
                    order_type   => $order,
                    basis_spot   => $basis_spot,
                    order_date   => $contract_params->{$order_date},
                    order_amount => $contract_params->{$order_amount},
                };
            }
        }
    } else {
        die 'Invalid contract parameters';
    }

    return \%orders;
}

sub _get_params_for_expiryqueue {
    my $self = shift;

    my $contract = $self->contract;

    my $hash = {
        purchase_price        => $self->price,
        transaction_reference => $self->transaction_id,
        held_by               => $self->client->loginid,
        contract_id           => $self->contract_id,
        in_currency           => $contract->currency,
        symbol                => $contract->underlying->symbol,
    };

    # These-are all non-exclusive conditions, we don't care if anything is
    # sold to which they all apply.
    $hash->{settlement_epoch} = $contract->date_settlement->epoch if $contract->category->has_user_defined_expiry;
    # if we were to enable back the intraday path dependent, the barrier saved
    # in expiry queue might be wrong, since barrier is set based on next tick.
    if ($contract->is_path_dependent) {
        # just check one barrier type since they are not allowed to be different.
        if ($contract->two_barriers) {
            if ($contract->high_barrier->barrier_type eq 'absolute') {
                $hash->{up_level}   = $contract->high_barrier->as_absolute;
                $hash->{down_level} = $contract->low_barrier->as_absolute;
            } else {
                $hash->{entry_tick_epoch}    = $contract->date_start->epoch + 1;
                $hash->{relative_up_level}   = $contract->supplied_high_barrier;
                $hash->{relative_down_level} = $contract->supplied_low_barrier;
            }
        } elsif ($contract->can('barrier')) {
            if ($contract->barrier and $contract->barrier->barrier_type eq 'absolute') {
                my $which_level = ($contract->barrier->as_difference > 0) ? 'up_level' : 'down_level';
                $hash->{$which_level} = $contract->barrier->as_absolute;
            } elsif ($contract->barrier) {
                $hash->{entry_tick_epoch} = $contract->date_start->epoch + 1;
                my $which_level = ($contract->barrier->pip_difference > 0) ? 'relative_up_level' : 'relative_down_level';
                $hash->{$which_level} = $contract->supplied_barrier;
            }
        }

        if ($contract->can('stop_out') and $contract->stop_out) {
            my $which_level = $contract->stop_out_side eq 'lower' ? 'down_level' : 'up_level';
            $hash->{$which_level} = $contract->underlying->pipsized_value($contract->stop_out->barrier_value);
        }

        if ($contract->can('take_profit') and $contract->take_profit) {
            my $which_level = $contract->take_profit_side eq 'lower' ? 'down_level' : 'up_level';
            $hash->{$which_level} = $contract->underlying->pipsized_value($contract->take_profit->barrier_value);
        }

        if ($contract->can('stop_loss') and $contract->stop_loss) {
            my $which_level = $contract->stop_loss_side eq 'lower' ? 'down_level' : 'up_level';
            $hash->{$which_level} = $contract->underlying->pipsized_value($contract->stop_loss->barrier_value);
        }
    }

    $hash->{tick_count} = $contract->tick_count if $contract->tick_expiry;

    return $hash;
}

sub _get_list_for_expiryqueue {
    my $full_list = shift;

    my @eq_list = ();
    foreach my $elm (@$full_list) {
        next if $elm->{code};
        push @eq_list,
            {
            contract_id           => $elm->{fmb}->{id},
            held_by               => $elm->{loginid},
            transaction_reference => $elm->{txn}->{id},
            };
    }

    return \@eq_list;
}

sub _get_info_to_verify_child {
    my ($contract_id, $contract) = @_;

    my $info = {
        financial_market_bet_id => $contract_id + 0,
        basis_spot              => $contract->basis_spot + 0,
        multiplier              => $contract->multiplier + 0,
    };

    foreach my $order (@{$contract->supported_orders}) {
        if ($contract->$order) {
            # make sure it is numeric
            $info->{$order . '_order_amount'} = $contract->$order->order_amount ? $contract->$order->order_amount + 0 : undef;
            # jsonb converts datatme to 2019-10-30T02:12:27 format
            # let's do the same here.
            my $order_date = $contract->$order->order_date->db_timestamp;
            $order_date =~ s/\s/T/;
            $info->{$order . '_order_date'} = $order_date;
        } else {
            # to match null in the child table
            $info->{$order . '_order_amount'} = undef;
            $info->{$order . '_order_date'}   = undef;
        }
    }

    return $info;

}

sub delete_contract_parameters {
    my ($contract_id, $client) = @_;

    my $redis_pricer = BOM::Config::RedisReplicated::redis_pricer;
    my $redis_key = join '::', ('CONTRACT_PARAMS', $contract_id, $client->landing_company->short);

    # we don't delete this right away because some service like pricing queue or transaction stream might still rely
    # on the contract parameters. We will give additional 10 seconds for this to be done.
    $redis_pricer->expire($redis_key, 10);

    return;
}

=head2 set_contract_parameters

Utility method to set contract parameters when a contract is purchased

=cut

sub set_contract_parameters {
    my ($contract_params, $client) = @_;

    my $redis_pricer = BOM::Config::RedisReplicated::redis_pricer;

    my %hash = (
        price_daemon_cmd => 'bid',
        short_code       => $contract_params->{shortcode},
        contract_id      => $contract_params->{contract_id},
        currency         => $contract_params->{currency},
        sell_time        => $contract_params->{sell_time},
        is_sold          => $contract_params->{is_sold} + 0,
        landing_company  => $client->landing_company->short,
    );

    # country code is needed in parameters for china because
    # we have special offerings conditions.
    $hash{country_code} = $client->residence if $client->residence eq 'cn';
    $hash{limit_order} = $contract_params->{limit_order} if $contract_params->{limit_order};

    my $redis_key = join '::', ('CONTRACT_PARAMS', $hash{contract_id}, $hash{landing_company});

    my $default_expiry = 86400;
    if (my $expiry = delete $contract_params->{expiry_time}) {
        my $contract_expiry = Date::Utility->new($expiry);
        # 10 seconds after expiry is to cater for sell transaction delay due to settlement conditions.
        $default_expiry = min($default_expiry, int($contract_expiry->epoch - time + 10));
    }

    return $redis_pricer->set($redis_key, _serialized_args(\%hash), 'EX', $default_expiry) if $default_expiry > 0;
    return;
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

no Moose;

__PACKAGE__->meta->make_immutable;

1;

=head1 TEST

    # run all test scripts #
    make test
    # run one script #
    prove t/BOM/001_structure.t
    # run one script with perl #
    perl -MBOM::Test t/BOM/001_structure.t

=cut

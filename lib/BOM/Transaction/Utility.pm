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

use BOM::Config::RedisReplicated;
use BOM::Platform::Event::Emitter;
use BOM::Config::RedisReplicated;

use Exporter 'import';
our @EXPORT_OK = qw(track_event TRACK_FMB_ATTR TRACK_CONTRACT_ATTR TRACK_TIME_ATTR);

use constant TRACK_FMB_ATTR => [
    qw(short_code underlying_symbol buy_price payout_price sell_price is_sold is_expired purchase_time start_time sell_time settlement_time expiry_time)
];
use constant TRACK_CONTRACT_ATTR  => [qw(supplied_barrier supplied_high_barrier supplied_low_barrier app_markup_percentage)];
use constant TRACK_TIME_ATTR      => [qw(purchase_time start_time sell_time settlement_time expiry_time)];
use constant KEY_RETENTION_SECOND => 60;

my $json = JSON::MaybeXS->new;

=head1 NAME

    BOM::Transaction::Helper

=cut

=head2 track_event

This method emits a tracking event on each successful 
buy/sell. For simplicity and easier reusability,
it handles a single buy/sell transaction on each call. 
As a result, it is supposed to be called multiple times on copy/batch
trading events. It accepts the following named parameters, without any return value:

=over

=item * C<event> - the event name that should be either B<buy> or B<sell>.

=item * C<fmb> - a B<FinancialMarketBet> database record of the trading event.

=item * C<transaction> - a B<Transaction> database record of the trading event.

=item * C<contract> - it's a `BOM::Product::Contract` object representing contract details.

=item * C<auto_expired> - 1: if the contract is sold automatically; 0: otherwise (for B<sell> events only).

=item * C<copy_trading> - 1: if the contract is bought by copy trading; 0: otherwise (for B<buy> events only).

=item * C<buy_source> - the source (or app_id) with which the contract had been bought (for B<sell> events only).

=back

=cut

sub track_event {
    my %args = @_;

    try {
        die 'Event name is missing' unless (my $event = $args{event});

        BOM::Platform::Event::Emitter::emit(
            $args{event},
            {
                loginid           => $args{loginid},
                contract_id       => $args{fmb}->{id},
                contract_type     => $args{contract}->code,
                contract_category => $args{contract}->category_code,
                balance_after     => $args{transaction}->{balance_after},
                source            => $args{transaction}->{source},
                transaction_id    => $args{transaction}->{id},
                $args{buy_source}   ? (buy_source   => $args{buy_source})   : (),
                $args{copy_trading} ? (copy_trading => $args{copy_trading}) : (),
                $args{auto_expired} ? (auto_expired => $args{auto_expired}) : (),
                $args{fmb}->%{TRACK_FMB_ATTR->@*},
                $args{contract}->%{TRACK_CONTRACT_ATTR->@*},
            });
    }
    catch {
        $log->warnf('Failed to emit event track: %s', $@);
    }
}

=head2 delete_contract_parameters

Utility method to set expiry of redis key to KEY_RETENTION_SECOND seconds.

Note that $redis->del is not used because CONTRACT_PARAMS might still be
used by other processes to send final contract details to client.

=cut

sub delete_contract_parameters {
    my ($contract_id, $client) = @_;

    my $redis_pricer = BOM::Config::RedisReplicated::redis_pricer;
    my $redis_key = join '::', ('CONTRACT_PARAMS', $contract_id, $client->landing_company->short);

    # we don't delete this right away because some service like pricing queue or transaction stream might still rely
    # on the contract parameters. We will give additional KEY_RETENTION_SECOND seconds for this to be done.
    $redis_pricer->expire($redis_key, KEY_RETENTION_SECOND);

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
        my $contract_expiry   = Date::Utility->new($expiry);
        my $seconds_to_expiry = $contract_expiry->epoch - time;
        # KEY_RETENTION_SECOND seconds after expiry is to cater for sell transaction delay due to settlement conditions.
        my $ttl = max($seconds_to_expiry, 0) + KEY_RETENTION_SECOND;
        $default_expiry = min($default_expiry, int($ttl));
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

1;

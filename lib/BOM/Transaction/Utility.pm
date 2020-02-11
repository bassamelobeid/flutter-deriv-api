package BOM::Transaction::Utility;

use strict;
use warnings;
no indirect;

use Syntax::Keyword::Try;
use Log::Any qw($log);

use Date::Utility;
use List::Util qw(min);
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
use constant TRACK_CONTRACT_ATTR => [qw(supplied_barrier supplied_high_barrier supplied_low_barrier app_markup_percentage)];
use constant TRACK_TIME_ATTR     => [qw(purchase_time start_time sell_time settlement_time expiry_time)];

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

1;

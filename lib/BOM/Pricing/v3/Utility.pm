package BOM::Pricing::v3::Utility;

use strict;
use warnings;
use feature 'state';

use DataDog::DogStatsd::Helper qw(stats_inc);
use JSON::MaybeUTF8 qw(decode_json_utf8);
use Try::Tiny;

use BOM::Config::RedisReplicated;
use BOM::Product::Contract;

sub create_error {
    my $args = shift;
    stats_inc("bom_pricing_rpc.v_3.error", {tags => ['code:' . $args->{code},]});
    return {
        error => {
            code              => $args->{code},
            message_to_client => $args->{message_to_client},
            $args->{continue_price_stream} ? (continue_price_stream => $args->{continue_price_stream}) : (),
            $args->{message}               ? (message               => $args->{message})               : (),
            $args->{details}               ? (details               => $args->{details})               : ()}};
}

=head2 update_price_metrics

Updates the price metrics in redis. Like the quantity processed
and the total timing.

=over 4

=item * C<relative_shortcode> - the relative shortcode to be used as field name

=item * C<timing> - the price timing

=back

=cut

sub update_price_metrics {
    my ($relative_shortcode, $timing) = @_;

    my $redis_pricer = BOM::Config::RedisReplicated::redis_pricer;

    $redis_pricer->hincrby('PRICE_METRICS::COUNT', $relative_shortcode, 1);
    $redis_pricer->hincrbyfloat('PRICE_METRICS::TIMING', $relative_shortcode, $timing);

    return;
}

=head2 create_relative_shortcode

Creates a relative shortcode using the contract parameters.

=over 4

=item * C<params> - Contract parameters

=back

Returns the relative shortcode.

=cut

sub create_relative_shortcode {
    my ($params, $current_spot) = @_;

    return BOM::Product::Contract::get_relative_shortcode(undef, $params->{short_code})
        if (exists $params->{short_code});

    $params->{date_start} //= 0;
    my $date_start = $params->{date_start} ? '0F' : '0';

    my $date_expiry;
    if ($params->{date_expiry}) {
        $date_expiry = ($params->{date_expiry} - ($params->{date_start} || time)) . 'F';
    } elsif (defined $params->{duration} and defined $params->{duration_unit}) {
        if ($params->{duration_unit} eq 't') {
            $date_expiry = $params->{duration} . 'T';
        } else {
            my %map_to_seconds = (
                s => 1,
                m => 60,
                h => 3600,
                d => 86400,
            );
            $date_expiry = $params->{duration} * $map_to_seconds{$params->{duration_unit}};
        }
    }

    $date_expiry //= 0;

    my @barriers = ($params->{barrier} // 'S0P', $params->{barrier2} // '0');

    if ($params->{contract_type} !~ /digit/i) {
        @barriers = map { BOM::Product::Contract::to_relative_barrier($_, $current_spot, $params->{symbol}) } @barriers;
    }

    return uc join '_', ($params->{contract_type}, $params->{symbol}, $date_start, $date_expiry, @barriers);
}

=head2 extract_from_channel_key

Extracts the hashref and string representations of a pub/sub
channel key

Returns:

(hashref, unprefixed_str)

=cut

sub extract_from_channel_key {
    my $key = shift // '';

    state $namespace_prefix = 'PRICER_KEYS::';
    state $ns_rs            = qr/^\Q$namespace_prefix/;
    state $error_key        = 'bom_pricing.v_3.utility.extract_error';

    if ($key =~ s/$ns_rs//) {
        if (my %params = try { @{decode_json_utf8($key // [])} }) {
            # This happy path is pretty buried. :(
            return (\%params, $key);
        }

        stats_inc($error_key, {tags => ['bad_json:' . $key]});
        return (+{}, $key);
    }

    stats_inc($error_key, {tags => ['bad_prefix:' . $key]});
    return (+{}, '');
}

1;

package BOM::Transaction::Utility;

use strict;
use warnings;

use BOM::Config::RedisReplicated;
use Date::Utility;
use List::Util qw(min);
use Encode;
use JSON::MaybeXS;

my $json = JSON::MaybeXS->new;

=head2 delete_contract_parameters

Utility method to set expiry of redis key to 10 seconds.

Note that $redis->del is not used because CONTRACT_PARAMS might still be
used by other processes to send final contract details to client.

=cut

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

1;

use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use Net::Async::Redis;
use IO::Async::Loop;

use Commission::Deal::DXTradeListener;
use Commission::Deal::CTraderListener;

my $mocked_ctrader_deal_listener = Test::MockModule->new('Commission::Deal::CTraderListener');

# This sub routine here is to mimic the deal listener initialization done at deal_listener.pl
sub mock_deal_listener {
    my ($provider) = shift;

    my %listener_class = (
        dxtrade => "DXTradeListener",
        ctrader => "CTraderListener",
    );

    return {error => 'Provider does not exists'} unless $listener_class{$provider};

    my $listener = "Commission::Deal::$listener_class{$provider}"->new(
        provider => $provider,
    );
}

subtest "Test deal_listener.pl script" => sub {

    subtest 'Test initialize for non-existent platform or provider' => sub {

        my $expected = {error => 'Provider does not exists'};

        my $output = mock_deal_listener('uknown');

        is_deeply($output, $expected, 'Expected return result - cannot start listener with non-existent platform or provider');

    };

    subtest 'Test initialize dxtrade listener' => sub {

        my $dxtrade = mock_deal_listener('dxtrade');
        isa_ok $dxtrade, 'Commission::Deal::DXTradeListener';

    };

    subtest 'Test initialize ctrader listener' => sub {

        my $ctrader = mock_deal_listener('ctrader');
        isa_ok $ctrader, 'Commission::Deal::CTraderListener';

    };

};

subtest 'test _load_affilite_client_map' => sub {
    my $affilite_client_map;

    my $listener = Commission::Deal::CTraderListener->new(
        redis_consumer_group => 'mygroup',
        redis_stream         => 'mystream',
        provider             => 'ctrader',
    );

    my @affilite_client = ({
            id             => 'CTR1000123',
            provider       => 'ctrader',
            binary_user_id => 1,
            affiliate_id   => 1,
            created_at     => '2023-06-28 10:00:00'
        },
        {
            id             => 'CTR1000456',
            provider       => 'ctrader',
            binary_user_id => 2,
            affiliate_id   => 1,
            created_at     => '2023-06-10 10:00:00'
        },
        {
            id             => 'CTR1000789',
            provider       => 'ctrader',
            binary_user_id => 3,
            affiliate_id   => 2,
            created_at     => '2023-06-11 10:00:00'
        });

    my $expected_affilite_client = {
        'CTR1000123' => 1,
        'CTR1000456' => 1,
        'CTR1000789' => 1
    };

    $mocked_ctrader_deal_listener->mock(
        '_load_affilite_client_map',
        sub {
            my (undef, $args) = @_;
            my $affilite_client = $args->{affilite_client};
            $affilite_client_map = {map { $_->{id} => 1 } $affilite_client->@*};
        });

    $listener->_load_affilite_client_map({affilite_client => \@affilite_client});

    is_deeply($affilite_client_map, $expected_affilite_client, 'affilite_client_map and expected_affilite_client are the same');
};

subtest 'test _process_deals' => sub {
    my @stored_deals = ();

    my $listener = Commission::Deal::CTraderListener->new(
        redis_consumer_group => 'mygroup',
        redis_stream         => 'mystream',
        provider             => 'ctrader',
    );

    my @dummy_deals = ({
            id                  => '123:1234',
            provider            => 'ctrader',
            affiliate_client_id => 1,
            account_type        => 'standard',
            symbol              => 'BTCUSD',
            volume              => 1,
            spread              => 0,
            price               => 6484.719,
            currency            => 'USD',
            payment_currency    => 'USD',
            performed_at        => '2021-06-28 10:00:00'
        },
        {
            id                  => '123:1235',
            provider            => 'ctrader',
            affiliate_client_id => 2,
            account_type        => 'standard',
            symbol              => 'BTCUSD',
            volume              => 1,
            spread              => 0,
            price               => 6484.719,
            currency            => 'USD',
            payment_currency    => 'USD',
            performed_at        => '2021-06-28 10:00:00'
        },
        {
            id                  => '123:1236',
            provider            => 'ctrader',
            affiliate_client_id => 3,
            account_type        => 'standard',
            symbol              => 'BTCUSD',
            volume              => 1,
            spread              => 0,
            price               => 6484.719,
            currency            => 'USD',
            payment_currency    => 'USD',
            performed_at        => '2021-06-28 10:00:00'
        });

    $mocked_ctrader_deal_listener->mock(
        '_process_deals',
        sub {
            my (undef, $args) = @_;
            push @stored_deals, $args;
        });

    foreach my $case (@dummy_deals) {
        $listener->_process_deals($case);
    }

    is_deeply(\@stored_deals, \@dummy_deals, 'dummy_deals and stored_deals are the same');
};

done_testing();

use strict;
use utf8;
use warnings;

use BOM::Platform::Token::API;
use BOM::Test::Data::Utility::AuthTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::User;
use Date::Utility;
use List::Util qw(reduce);
use MojoX::JSON::RPC::Client;
use Test::MockModule;
use Test::MockTime qw(:all);
use Test::Mojo;
use Test::Most;

set_absolute_time(Date::Utility->new('2024-05-23 00:15:00')->epoch);
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => Date::Utility->new->minus_time_interval('100d')->epoch,
});

my $endpoint = 'contracts_for_company';
my @params   = (
    $endpoint,
    {
        args => {
            contracts_for_company => 1,
            landing_company       => 'virtual',
        },
        country_code => 'id',
    },
);
my %platform = (
    dtrader     => 11780,
    deriv_go    => 23789,
    smarttrader => 1,
    binary_bot  => 1169,
);
my $rpc_ct = BOM::Test::RPC::QueueClient->new();

subtest "Request $endpoint for dtrader" => sub {
    $params[1]{source} = $platform{dtrader};

    my $result         = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    my %expected_count = (
        accumulator   => 1,
        callput       => 4,
        callputequal  => 2,
        callputspread => 2,
        digits        => 6,
        multiplier    => 2,
        touchnotouch  => 2,
        turbos        => 2,
        vanilla       => 4
    );
    my $total_count          = reduce { $a + $b } values %expected_count;
    my @available_categories = _get_contracts_list(@{$result->{available}});

    is_deeply [sort keys %{$result}],       [sort qw(available hit_count stash)], 'return contracts_for_company object';
    is_deeply [sort @available_categories], [sort keys %expected_count],          'all available categories are as expected';
    ok @{$result->{available}}, 'at least 1 contract is available';
    is $result->{hit_count}, $total_count, "total hit_count is $total_count";

    foreach my $cc (@available_categories) {
        my $got = grep { $_->{contract_category} eq $cc } @{$result->{available}};
        is $got, $expected_count{$cc}, "got $got contracts for $cc";
    }

    subtest "Request $endpoint without landing_company and logged out" => sub {
        delete $params[1]{args}{landing_company};

        my $result_no_lc = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
        is_deeply $result_no_lc, $result, 'result should be the same as virtual landing_company';
    };

    subtest "Request $endpoint for maltainvest and logged out" => sub {
        $params[1]{args}{landing_company} = 'maltainvest';

        my $result_maltainvest_logged_out = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
        my %expected_count                = (multiplier => 2);
        my @available_categories          = _get_contracts_list(@{$result_maltainvest_logged_out->{available}});

        is_deeply [sort @available_categories], [sort keys %expected_count], 'all available categories are as expected';
        cmp_ok $result_maltainvest_logged_out->{hit_count}, '<', $result->{hit_count}, "hit_count for maltainvest should be lower than virtual";

        foreach my $cc (@available_categories) {
            my $got = grep { $_->{contract_category} eq $cc } @{$result->{available}};
            is $got, $expected_count{$cc}, "got $got contracts for $cc";
        }
    };

    subtest "Request $endpoint for maltainvest but logged in to svg" => sub {
        my $email = 'test-binary' . rand(999) . '@binary.com';
        my $user  = BOM::User->create(
            email    => $email,
            password => "hello-world",
        );
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            binary_user_id => $user->id,
        });
        $client->email($email);
        $client->save;
        $user->add_client($client);

        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        $params[1]{token}                 = $token;
        $params[1]{token_details}         = {loginid => $client->loginid};
        $params[1]{args}{landing_company} = 'maltainvest';

        my $result_maltainvest_logged_into_svg = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
        my %expected_count                     = (
            accumulator   => 1,
            callput       => 4,
            callputequal  => 2,
            callputspread => 2,
            digits        => 6,
            multiplier    => 2,
            touchnotouch  => 2,
            turbos        => 2,
            vanilla       => 4
        );
        my $total_count          = reduce { $a + $b } values %expected_count;
        my @available_categories = _get_contracts_list(@{$result_maltainvest_logged_into_svg->{available}});

        is_deeply [sort @available_categories], [sort keys %expected_count], 'all available categories are as expected';
        is $result_maltainvest_logged_into_svg->{hit_count}, $total_count, "total hit_count is $total_count";

        foreach my $cc (@available_categories) {
            my $got = grep { $_->{contract_category} eq $cc } @{$result_maltainvest_logged_into_svg->{available}};
            is $got, $expected_count{$cc}, "got $got contracts for $cc";
        }
    };
};

subtest "Request $endpoint for deriv_go" => sub {
    $params[1]{source} = $platform{deriv_go};

    my $result_deriv_go = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    my %expected_count  = (
        accumulator   => 1,
        callput       => 4,
        callputequal  => 2,
        callputspread => 2,
        multiplier    => 2,
    );
    my $total_count          = reduce { $a + $b } values %expected_count;
    my @available_categories = _get_contracts_list(@{$result_deriv_go->{available}});

    is_deeply [sort @available_categories], [sort keys %expected_count], 'all available categories are as expected';
    is $result_deriv_go->{hit_count}, $total_count, "total hit_count is $total_count";

    foreach my $cc (@available_categories) {
        my $got = grep { $_->{contract_category} eq $cc } @{$result_deriv_go->{available}};
        is $got, $expected_count{$cc}, "got $got contracts for $cc";
    }
};

subtest "Request $endpoint for smarttrader" => sub {
    $params[1]{source} = $platform{smarttrader};

    my $result_smarttrader = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    my %expected_count     = (
        asian        => 2,
        callput      => 4,
        callputequal => 2,
        digits       => 6,
        endsinout    => 2,
        highlowticks => 2,
        lookback     => 3,
        reset        => 2,
        runs         => 2,
        staysinout   => 2,
        touchnotouch => 2,
    );
    my $total_count          = reduce { $a + $b } values %expected_count;
    my @available_categories = _get_contracts_list(@{$result_smarttrader->{available}});

    is_deeply [sort @available_categories], [sort keys %expected_count], 'all available categories are as expected';
    is $result_smarttrader->{hit_count}, $total_count, "total hit_count is $total_count";

    foreach my $cc (keys %expected_count) {
        my $got = grep { $_->{contract_category} eq $cc } @{$result_smarttrader->{available}};
        is $got, $expected_count{$cc}, "got $got contracts for $cc on smarttrader.";
    }
};

subtest "Request $endpoint for binary_bot" => sub {
    $params[1]{source} = $platform{binary_bot};

    my $result_binary_bot = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error->result;
    my %expected_count    = (
        asian        => 2,
        callput      => 4,
        callputequal => 2,
        digits       => 6,
        endsinout    => 2,
        highlowticks => 2,
        reset        => 2,
        runs         => 2,
        staysinout   => 2,
        touchnotouch => 2,
    );
    my $total_count          = reduce { $a + $b } values %expected_count;
    my @available_categories = _get_contracts_list(@{$result_binary_bot->{available}});

    is_deeply [sort @available_categories], [sort keys %expected_count], 'all available categories are as expected';
    is $result_binary_bot->{hit_count}, $total_count, "total hit_count is $total_count";

    foreach my $cc (keys %expected_count) {
        my $got = grep { $_->{contract_category} eq $cc } @{$result_binary_bot->{available}};
        is $got, $expected_count{$cc}, "got $got contracts for $cc on binary_bot.";
    }
};

sub _get_contracts_list {
    my @contract_obj_array = @_;
    my @available_categories;

    foreach my $contract_obj (@contract_obj_array) {
        push(@available_categories, $contract_obj->{contract_category})
            unless grep { $_ eq $contract_obj->{contract_category} } @available_categories;
    }

    return @available_categories;
}

done_testing();

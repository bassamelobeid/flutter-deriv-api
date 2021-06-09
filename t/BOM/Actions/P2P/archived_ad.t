use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::Event::Actions::P2P;
use Test::MockModule;
use Test::Deep;
use BOM::Test::Helper::P2P;
use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Event::Services::Track;
use BOM::Platform::Context qw(request);
use Format::Util::Numbers qw(financialrounding formatnumber);

BOM::Test::Helper::P2P::bypass_sendbird();
my $escrow = BOM::Test::Helper::P2P::create_escrow();
my $brand  = request()->brand->name;
my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
    amount => 100,
    type   => 'sell'
);
my (undef, $advert2) = BOM::Test::Helper::P2P::create_advert(
    amount         => 100,
    local_currency => 'pyg'
);

my $mock_segment = Test::MockModule->new('WebService::Async::Segment::Customer');
my @identify_args;
my @track_args;

$mock_segment->redefine(
    'track' => sub {
        my ($customer, %args) = @_;
        push @track_args, ($customer, \%args);
        return Future->done(1);
    });

subtest 'Archived ad' => sub {
    my $tests = [{
            payload => {
                archived_ads       => [1, 3],
                advertiser_loginid => undef
            },
            error => 'Missing advertiser loginid',
        },
        {
            payload => {
                archived_ads       => [1, 3],
                advertiser_loginid => 'CR0',
            },
            error => 'Client not found',
        },
        {
            payload => {
                archived_ads       => [],
                advertiser_loginid => $advertiser->loginid,
            },
            error => 'Empty ads',
        },
        {
            payload => {
                archived_ads       => [$advert->{id}, $advert2->{id}],
                advertiser_loginid => $advertiser->loginid,
            },
            error => undef,
        }];

    for my $test ($tests->@*) {
        my $payload = $test->{payload};

        if (my $error = $test->{error}) {
            throws_ok { BOM::Event::Actions::P2P::archived_ad($payload) } qr/$error/, "Expected exception thrown: $error";
        } else {
            lives_ok { BOM::Event::Actions::P2P::archived_ad($payload)->get } 'Event made it alive';

            my ($customer, $args) = @track_args;
            isa_ok $customer, 'WebService::Async::Segment::Customer', 'Expected identify result';

            cmp_deeply $args->{properties},
                {
                loginid => $advertiser->loginid,
                adverts => [map { $advertiser->_p2p_adverts(id => $_->{id}, limit => 1)->@* } ($advert, $advert2)],
                brand   => $brand,
                },
                'Expected properties sent';
        }
    }
};

done_testing();

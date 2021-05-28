use strict;
use warnings;

use Test::Fatal;
use Test::Deep;
use Test::More;
use Test::MockModule;
use BOM::Event::Actions::P2P;
use BOM::Test::Email;
use BOM::Platform::Context qw(request);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use Date::Utility;

BOM::Test::Helper::P2P::bypass_sendbird();

subtest 'Event processing return value' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount  => $amount,
        type    => 'sell',
        balance => 760,
    );
    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert->{id},
        amount    => $amount,
        balance   => 1000,
    );

    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});
    ok !BOM::Event::Actions::P2P::dispute_expired({
            broker_code => undef,
            order_id    => $order->{id},
            timestamp   => 1600000000,
        }
        ),
        'Not processed due to lack of broker code';

    ok !BOM::Event::Actions::P2P::dispute_expired({
            broker_code => 'CR',
            order_id    => undef,
            timestamp   => 1600000000,
        }
        ),
        'Not processed due to lack of an order id';

    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'buyer-confirmed');
    ok $client->broker_code, 'Client have a broker code';
    ok $order->{id}, 'We have an order id';

    ok !BOM::Event::Actions::P2P::dispute_expired({
            broker_code => $client->broker_code,
            order_id    => $order->{id},
            timestamp   => 1600000000,
        }
        ),
        'Not processed due to status changed';

    subtest 'Checking the email' => sub {
        my $mock = Test::MockModule->new('BOM::Event::Actions::P2P');
        my $email_args;
        my $dispute_reason = 'seller_not_released';
        my $order_id       = $order->{id};
        my $order_currency = $order->{local_currency};
        my $order_amount   = 0 + $order->{amount};
        my $timestamp      = 1600000000;
        my $disputed_at    = Date::Utility->new($timestamp)->datetime_ddmmmyy_hhmmss_TZ;

        $mock->mock(
            'send_email',
            sub {
                $email_args = shift;
                return $mock->original('send_email')->($email_args);
            });

        BOM::Test::Helper::P2P::set_order_disputable($client, $order_id);
        $client->p2p_create_order_dispute(
            id             => $order_id,
            dispute_reason => $dispute_reason,
        );

        mailbox_clear();
        ok BOM::Event::Actions::P2P::dispute_expired({
                broker_code => $client->broker_code,
                order_id    => $order_id,
                timestamp   => 1600000000,
            }
            ),
            'The order has been processed';

        my $msg = mailbox_search(subject => qr/P2P dispute expired/);
        ok $msg, "We've got an email";

        my $brand          = request()->brand;
        my $buyer_loginid  = $client->loginid;
        my $seller_loginid = $advertiser->loginid;

        cmp_deeply $email_args,
            {
            from                  => $brand->emails('no-reply'),
            subject               => 'P2P dispute expired',
            email_content_is_html => 1,
            message               => [
                '<p>A P2P order has been disputed for a while without resolution. Here are the details:<p>',
                '<ul>',
                "<li><b>Buyer Loginid:</b> $buyer_loginid</li>",
                "<li><b>Seller Loginid:</b> $seller_loginid</li>",
                "<li><b>Raised by:</b> $buyer_loginid</li>",
                "<li><b>Reason:</b> $dispute_reason</li>",
                "<li><b>Order ID:</b> $order_id</li>",
                "<li><b>Amount:</b> $order_amount</li>",
                "<li><b>Currency:</b> $order_currency</li>",
                "<li><b>Dispute raised time:</b> $disputed_at</li>",
                '</ul>'
            ],
            to => 'p2p-support@deriv.com',
            },
            "We've got the expected email content";
    };

    BOM::Test::Helper::P2P::reset_escrow();
};

done_testing();

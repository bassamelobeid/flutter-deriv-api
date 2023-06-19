use strict;
use warnings;
no indirect;

use Test::More;
use Test::MockModule;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts;
use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve;

my $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(broker_code => 'CR');

subtest get_stable_payment_methods => sub {
    my $expected_result = {
        skrill                 => 'Skrill',
        neteller               => 'Neteller',
        perfectm               => 'Perfect Money',
        fasapay                => 'FasaPay',
        paysafe                => 'PaySafe',
        sticpay                => 'SticPay',
        webmoney               => 'Webmoney',
        airtm                  => 'AirTM',
        paylivre               => 'Paylivre',
        nganluong              => 'NganLuong',
        astropay               => 'Astropay',
        onlinenaira            => 'Onlinenaira',
        directa24s             => 'Directa24',
        zingpay                => 'ZingPay',
        pix                    => 'PIX',
        payrtransfer           => 'PayRTransfer',
        advcash                => 'Advcash',
        upi                    => 'UPI',
        beyonicmt              => 'BeyonicMT',
        imps                   => 'IMPS',
        btc                    => 'BTCCOP',
        ltc                    => 'BTCCOP',
        eth                    => 'BTCCOP',
        bch                    => 'BTCCOP',
        solidpaywave           => 'SolidPayWave',
        verve                  => 'Verve',
        help2pay               => 'Help2pay',
        p2p                    => 'Deriv P2P',
        payment_agent_transfer => 'Payment Agent'
    };

    is_deeply($auto_approve_obj->get_stable_payment_methods, $expected_result, 'get_stable_payment_methods should return the correct result');

};

done_testing;

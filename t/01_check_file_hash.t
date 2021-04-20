use strict;
use warnings;

use Test::More;
use Module::Path qw/module_path/;
use Digest::SHA1;
use LandingCompany::Registry;
use List::Util qw(uniq);

subtest 'UKGC compliant file hash check' => sub {
    my $base_module_name = 'BOM::Product::Contract::';
    my @contract_types   = LandingCompany::Registry::get('iom')->basic_offerings({
            action          => 'buy',
            loaded_revision => 1
        })->values_for_key('contract_type');

    push @contract_types,
        LandingCompany::Registry::get('malta')->basic_offerings({
            action          => 'buy',
            loaded_revision => 1
        })->values_for_key('contract_type');

    my %file_details = (
        runhigh => {
            filename => module_path('BOM::Product::Contract::Runhigh'),
            hash     => '27404d4a93be0860f01bf4c94bcd8454559a5bfe'
        },
        runlow => {
            filename => module_path('BOM::Product::Contract::Runlow'),
            hash     => '61a5d464b07dcab6df20972e3079e4f742b1cee9'
        },
        call => {
            filename => module_path('BOM::Product::Contract::Call'),
            hash     => '547145eab4e09cb377c7819e2a888a69accbe6cd'
        },
        put => {
            filename => module_path('BOM::Product::Contract::Put'),
            hash     => '263e75405e4645b2f40aff68ec756d4551285b46'
        },
        onetouch => {
            filename => module_path('BOM::Product::Contract::Onetouch'),
            hash     => 'b630d17b6f4e12e9579e019258f1400f5562cf68'
        },
        notouch => {
            filename => module_path('BOM::Product::Contract::Notouch'),
            hash     => 'f4e583beb0861b7fe6fb357f098199dbd6aca69e'
        },
        range => {
            filename => module_path('BOM::Product::Contract::Range'),
            hash     => 'ad03ad5c11e407b6add951305670a593224ab02c'
        },
        upordown => {
            filename => module_path('BOM::Product::Contract::Upordown'),
            hash     => 'e0bd58ca569f2e833783aac14846a55d8eae79fb'
        },
        expirymiss => {
            filename => module_path('BOM::Product::Contract::Expirymiss'),
            hash     => 'a72661b9a61c34009331b7233b0b300c8b4a44e1'
        },
        expiryrange => {
            filename => module_path('BOM::Product::Contract::Expirymisse'),
            hash     => '4971b4a1a9f6ce793fffd96f4685224d92b11bef'
        },
        asianu => {
            filename => module_path('BOM::Product::Contract::Asianu'),
            hash     => '656aaac4f48b5b995bda7603e45648d60b12e4a3'
        },
        asiand => {
            filename => module_path('BOM::Product::Contract::Asiand'),
            hash     => 'e98dbae7c9c1917a01f310845408f658bcc20260'
        },
        digitmatch => {
            filename => module_path('BOM::Product::Contract::Digitmatch'),
            hash     => 'b9db1f406c3d17e2b4bd2893f253053bd20a7396'
        },
        digitdiff => {
            filename => module_path('BOM::Product::Contract::Digitdiff'),
            hash     => '47591b22785e416f96bb341bed284e7a96443069'
        },
        digiteven => {
            filename => module_path('BOM::Product::Contract::Digiteven'),
            hash     => '53f9b8eb33768e517a7ca097913430ea8b785631'
        },
        digitodd => {
            filename => module_path('BOM::Product::Contract::Digitodd'),
            hash     => 'f530c9b768c9fb6eae364b3860749d4b4c3d5cc9'
        },
        digitover => {
            filename => module_path('BOM::Product::Contract::Digitover'),
            hash     => 'af5fe3eab60c5ae8c12bfd7c5377afc5e11690d1'
        },
        digitunder => {
            filename => module_path('BOM::Product::Contract::Digitunder'),
            hash     => '1601c5d259828382f930e15d83f056c9e2d0fcce'
        },
        lbfloatcall => {
            filename => module_path('BOM::Product::Contract::Lbfloatcall'),
            hash     => 'e3e68e78cbf2796e0a84fcc0d931ed061ddf783b'
        },
        lbfloatput => {
            filename => module_path('BOM::Product::Contract::Lbfloatput'),
            hash     => 'e843327d705dad38699776febab33dd8749a2002'
        },
        lbhighlow => {
            filename => module_path('BOM::Product::Contract::Lbhighlow'),
            hash     => 'a098dc6cf7d13805c7a65b0f97155f8904ae29d7'
        },
        ticklow => {
            filename => module_path('BOM::Product::Contract::Ticklow'),
            hash     => '72a5fc387ab18ea91e0046ac76459d2b2af340fe'
        },
        tickhigh => {
            filename => module_path('BOM::Product::Contract::Tickhigh'),
            hash     => '177ec191f4d1a6b0259fd5951e3126466508531d'
        },
        callspread => {
            filename => module_path('BOM::Product::Contract::Callspread'),
            hash     => 'f8345bf4f010dbd0f76e686f8395b7f8acfb972b'
        },
        putspread => {
            filename => module_path('BOM::Product::Contract::Putspread'),
            hash     => 'bfadc395d8100e4c594c28b7935dcb7d053fc260'
        },
        resetcall => {
            filename => module_path('BOM::Product::Contract::Resetcall'),
            hash     => '2429f13d0284bd6eb84095c64965d42ce0965ad1'
        },
        resetput => {
            filename => module_path('BOM::Product::Contract::Resetput'),
            hash     => 'f08dbfa3f49c76ccc21074b93cdcb0b3a1664623'
        },
        calle => {
            filename => module_path('BOM::Product::Contract::Calle'),
            hash     => 'b21689e81e8727649167e67c2ce3e06c111d3abf'
        },
        pute => {
            filename => module_path('BOM::Product::Contract::Pute'),
            hash     => 'a0685380d1b6ba87f2d277509df5fd97dde15ce9'
        },
        multup => {
            filename => module_path('BOM::Product::Contract::Multup'),
            hash     => '94b90c4ba5fcd4c7f5cb3cbd227d281737e2ec2f'
        },
        multdown => {
            filename => module_path('BOM::Product::Contract::Multdown'),
            hash     => '14b58bb235111966bcf3beffc6939c743db8e891'
        });

    foreach my $contract_type (map { lc ucfirst } uniq @contract_types) {
        if ($file_details{$contract_type}) {
            open(my $fh, "<", $file_details{$contract_type}{filename}) or die "File not found $_";
            binmode($fh);

            is(
                Digest::SHA1->new->addfile($fh)->hexdigest,
                $file_details{$contract_type}{hash},
                'Game signature for ' . $contract_type . ' is correct: ' . $file_details{$contract_type}{hash})
                or diag
                'Games must be recertified when this happens as part of UKGC compliance. Please contact compliance to discuss this before proceeding any further. Failed for: '
                . $contract_type;

            close $fh;
        } else {
            fail("Game signature for $contract_type is not defined");
        }
    }
};

done_testing();

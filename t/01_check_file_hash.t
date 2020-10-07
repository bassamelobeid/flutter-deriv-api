use strict;
use warnings;

use Test::More;
use Module::Path qw/module_path/;
use Digest::SHA1;

my %file_details = (
    runs => {
        filename => module_path('BOM::Product::Contract::Runhigh'),
        hash     => '27404d4a93be0860f01bf4c94bcd8454559a5bfe'
    },
    risefall => {
        filename => module_path('BOM::Product::Contract::Call'),
        hash     => '547145eab4e09cb377c7819e2a888a69accbe6cd'
    },
    higherlower => {
        filename => module_path('BOM::Product::Contract::Call'),
        hash     => '547145eab4e09cb377c7819e2a888a69accbe6cd'
    },
    touchnotouch => {
        filename => module_path('BOM::Product::Contract::Onetouch'),
        hash     => 'b630d17b6f4e12e9579e019258f1400f5562cf68'
    },
    staysbetweengoesout => {
        filename => module_path('BOM::Product::Contract::Range'),
        hash     => 'ad03ad5c11e407b6add951305670a593224ab02c'
    },
    endsbetweenout => {
        filename => module_path('BOM::Product::Contract::Expirymisse'),
        hash     => '4971b4a1a9f6ce793fffd96f4685224d92b11bef'
    },
    asians => {
        filename => module_path('BOM::Product::Contract::Asianu'),
        hash     => '656aaac4f48b5b995bda7603e45648d60b12e4a3'
    },
    digitsmatchdiffers => {
        filename => module_path('BOM::Product::Contract::Digitmatch'),
        hash     => 'b9db1f406c3d17e2b4bd2893f253053bd20a7396'
    },
    digitsevenodd => {
        filename => module_path('BOM::Product::Contract::Digiteven'),
        hash     => '53f9b8eb33768e517a7ca097913430ea8b785631'
    },
    digitsoverunder => {
        filename => module_path('BOM::Product::Contract::Digitover'),
        hash     => 'af5fe3eab60c5ae8c12bfd7c5377afc5e11690d1'
    },
    lookbacks => {
        filename => module_path('BOM::Product::Contract::Lbfloatcall'),
        hash     => 'e3e68e78cbf2796e0a84fcc0d931ed061ddf783b'
    },
    highlowtick => {
        filename => module_path('BOM::Product::Contract::Tickhigh'),
        hash     => '177ec191f4d1a6b0259fd5951e3126466508531d'
    },
    callputspread => {
        filename => module_path('BOM::Product::Contract::Callspread'),
        hash     => 'f8345bf4f010dbd0f76e686f8395b7f8acfb972b'
    },
    resetcallput => {
        filename => module_path('BOM::Product::Contract::Resetcall'),
        hash     => '2429f13d0284bd6eb84095c64965d42ce0965ad1'
    },
    calleputte => {
        filename => module_path('BOM::Product::Contract::Calle'),
        hash     => 'b21689e81e8727649167e67c2ce3e06c111d3abf'
    },
    multup => {
        filename => module_path('BOM::Product::Contract::Multup'),
        hash     => '51a5934d9d2337566fb40318fe1fd7824a445462'
    },
    multdown => {
        filename => module_path('BOM::Product::Contract::Multdown'),
        hash     => 'bd03929485d00041e936fd243daa471975f5a862'
    });

foreach my $entry (keys %file_details) {
    open(my $fh, "<", $file_details{$entry}{filename}) or die "File not found $_";
    binmode($fh);

    is(
        Digest::SHA1->new->addfile($fh)->hexdigest,
        $file_details{$entry}{hash},
        'Game signature for ' . $entry . ' is correct: ' . $file_details{$entry}{hash})
        or diag
        'Games must be recertified when this happens as part of UKGC compliance. Please contact compliance to discuss this before proceeding any further. Failed for: '
        . $entry;

    close $fh;
}

done_testing();

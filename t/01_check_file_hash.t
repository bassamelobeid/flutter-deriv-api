use strict;
use warnings;

use Test::More;
use Module::Path qw/module_path/;
use Digest::SHA1;

my %file_details = (
    risefall => {
        filename => module_path('BOM::Product::Contract::Upordown'),
        hash     => 'e0bd58ca569f2e833783aac14846a55d8eae79fb'
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
        hash     => '7db442786004654b27e8fa69a88e9f7a88987fc0'
    },
    asians => {
        filename => module_path('Pricing::Engine::BlackScholes'),
        hash     => 'b98e6d6b9428b0116fc65b79fff8153924bdbc3b'
    },
    digitsmatchdiffers => {
        filename => module_path('BOM::Product::Contract::Digitmatch'),
        hash     => 'f96de1a7db1c4b9f56fadac0b75b61ea97c9e31c'
    },
    digitsevenodd => {
        filename => module_path('BOM::Product::Contract::Digiteven'),
        hash     => 'e8d9cd5170b51cf079cdeda84f71191c477f5b7f'
    },
    digitsoverunder => {
        filename => module_path('BOM::Product::Contract::Digitover'),
        hash     => '79b75f97ca29499afe3eb84238bede377cd47b9d'
    },
    lookbacks => {
        filename => module_path('BOM::Product::Contract::Lbfloatcall'),
        hash     => '0c3926d2dd6b95b5fd2588426aff8058558281ba'
    },
    highlowtick => {
        filename => module_path('BOM::Product::Contract::Tickhigh'),
        hash     => '2d3e7b4217bf909bd2f0cebc1f3abd2acfad8858'
    },
    callputspread => {
        filename => module_path('BOM::Product::Contract::Callspread'),
        hash     => 'f8345bf4f010dbd0f76e686f8395b7f8acfb972b'
    },
    resetcallput => {
        filename => module_path('BOM::Product::Contract::Resetcall'),
        hash     => 'b014732c10c1b467cca90ede6c02ae1952e8a9c1'
    },
    calleputte => {
        filename => module_path('BOM::Product::Contract::Calle'),
        hash     => 'b21689e81e8727649167e67c2ce3e06c111d3abf'
    },
);

foreach my $entry (keys %file_details) {
    open(my $fh, "<", $file_details{$entry}{filename}) or die "File not found $_";
    binmode($fh);

    is(Digest::SHA1->new->addfile($fh)->hexdigest, $file_details{$entry}{hash}, 'File hash is unchanged')
        or diag
        'Games must be recertified when this happens as part of UKGC compliance. Please contact compliance to discuss this before proceeding any further. Failed for: '
        . $entry;

    close $fh;
}

done_testing();

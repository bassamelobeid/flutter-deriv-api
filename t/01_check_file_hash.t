use strict;
use warnings;

use Test::More;
use Module::Path qw/module_path/;
use Digest::SHA1;

my %file_details = (
    risefall => {
        filename => module_path('BOM::Product::Contract::Upordown'),
        hash     => '90891247609f2840767a236cc33e48c7bcb956a5'
    },
    higherlower => {
        filename => module_path('BOM::Product::Contract::Call'),
        hash     => '547145eab4e09cb377c7819e2a888a69accbe6cd'
    },
    touchnotouch => {
        filename => module_path('BOM::Product::Contract::Onetouch'),
        hash     => '25c870ac1d6fc097f743a4159fa0f129765f1760'
    },
    staysbetweengoesout => {
        filename => module_path('BOM::Product::Contract::Range'),
        hash     => '92c7e3ee01a82cac1fd0a653c30abf3af0b83eb4'
    },
    endsbetweenout => {
        filename => module_path('BOM::Product::Contract::Expirymisse'),
        hash     => 'fb6015bd64af11f1d0198c3f2e75aab7d101041d'
    },
    asians => {
        filename => module_path('Pricing::Engine::BlackScholes'),
        hash     => '568ed7f0777bc9a0197d097acbce62eabb79505e'
    },
    digitsmatchdiffers => {
        filename => module_path('BOM::Product::Contract::Digitmatch'),
        hash     => '961d3c9c1b1cf99148ec2346aca08e3a20ff77a2'
    },
    digitsevenodd => {
        filename => module_path('BOM::Product::Contract::Digiteven'),
        hash     => 'f7c66183272937a5345a3b439e2c17b32c1cdbad'
    },
    digitsoverunder => {
        filename => module_path('BOM::Product::Contract::Digitover'),
        hash     => '92b7045058e89b8bf85007e76fba2265ce4b5f8e'
    },
);

foreach my $entry (keys %file_details) {
    open(my $fh, "<", $file_details{$entry}{filename}) or die "File not found $_";
    binmode($fh);

    is(Digest::SHA1->new->addfile($fh)->hexdigest, $file_details{$entry}{hash}, 'File hash is unchanged')
        or diag
        'Games must be recertified when this happens as part of UKGC compliance. Please contact compliance to discuss this before proceeding any further.';

    close $fh;
}

done_testing();

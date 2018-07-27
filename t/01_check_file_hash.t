use strict;
use warnings;

use Test::More;
use Module::Path qw/module_path/;
use Digest::SHA1;

my %file_details = (
    risefall => {
        filename => module_path('BOM::Product::Contract::Upordown'),
        hash     => '018a7db139fa86d7009dbfb539d5e5b3f1231ce5'
    },
    higherlower => {
        filename => module_path('BOM::Product::Contract::Call'),
        hash     => '547145eab4e09cb377c7819e2a888a69accbe6cd'
    },
    touchnotouch => {
        filename => module_path('BOM::Product::Contract::Onetouch'),
        hash     => 'f628998eed1f254d217916abb70bef2b83f3f17d'
    },
    staysbetweengoesout => {
        filename => module_path('BOM::Product::Contract::Range'),
        hash     => '17f60d52c307c5071064f59dc15dc40fd4da68e7'
    },
    endsbetweenout => {
        filename => module_path('BOM::Product::Contract::Expirymisse'),
        hash     => 'fb6015bd64af11f1d0198c3f2e75aab7d101041d'
    },
    asians => {
        filename => module_path('Pricing::Engine::BlackScholes'),
        hash     => 'b98e6d6b9428b0116fc65b79fff8153924bdbc3b'
    },
    digitsmatchdiffers => {
        filename => module_path('BOM::Product::Contract::Digitmatch'),
        hash     => '042ad01b23b211c7271a27e9625a0b550d115265'
    },
    digitsevenodd => {
        filename => module_path('BOM::Product::Contract::Digiteven'),
        hash     => 'e8d9cd5170b51cf079cdeda84f71191c477f5b7f'
    },
    digitsoverunder => {
        filename => module_path('BOM::Product::Contract::Digitover'),
        hash     => 'efe9d26335cc4001c9f286ae152ebf8f51342bd8'
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

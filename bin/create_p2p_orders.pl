use strict;
use warnings;
use BOM::User::Client;
use Getopt::Long;
use BOM::Rules::Engine;
use Data::Dumper;
use Syntax::Keyword::Try;
use P2P;

my %opts;
GetOptions(\%opts, 'client|c=s', 'advertiser|a=s', 'orders|o=i');
warn Dumper \%opts;
my $client      = BOM::User::Client->new({loginid => $opts{client}})     or die "$opts{client} not found!";
my $advertiser  = BOM::User::Client->new({loginid => $opts{advertiser}}) or die "$opts{advertiser} not found!";
my $rule_engine = BOM::Rules::Engine->new();

$opts{orders} //= 100;
my $ad;
my $p2p = P2P->new(client => $advertiser);

try {
    $advertiser->payment_free_gift(
        amount   => $opts{orders},
        remark   => 'x',
        currency => $advertiser->currency
    );
    $ad = $p2p->p2p_advert_create(
        amount           => 3000,
        type             => 'sell',
        rate             => 1,
        local_currency   => 'xxx',
        min_order_amount => 0.01,
        max_order_amount => 1000,
        payment_method   => 'bank_transfer',
        payment_info     => 'test',
        contact_info     => 'test'
    );

    for my $i (1 .. $opts{orders} // 100) {
        print "Creating order $i\n";

        my $order = $p2p->p2p_order_create(
            advert_id   => $ad->{id},
            amount      => $i / 100,
            rule_engine => $rule_engine,
        );

        $p2p->p2p_order_confirm(id => $order->{id});
        $p2p->p2p_order_confirm(id => $order->{id});
    }
} catch {
    print Dumper $@ if $@;
} finally {
    $p2p->p2p_advert_update(
        id     => $ad->{id},
        delete => 1,
    ) if $ad;

}

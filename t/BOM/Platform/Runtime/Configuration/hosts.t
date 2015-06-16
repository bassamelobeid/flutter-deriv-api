use Test::Most 0.22 (tests => 3);
use Test::Deep;
use Test::NoWarnings;
use BOM::Platform::Runtime;
use Sys::Hostname;

my $hosts = BOM::Platform::Runtime->instance->hosts;
isa_ok $hosts, 'BOM::System::Host::Registry';
my $hostname = hostname();
$hostname =~ s/^([^.]+).*$/$1/;

subtest 'get_server and build' => sub {
    my $collector01 = $hosts->get('deal01');
    isa_ok $collector01, 'BOM::System::Host';
    cmp_deeply(
        $collector01,
        methods(
            name            => 'deal01',
            domain          => 'devbin.io',
            external_domain => 'devbin.io',
        ),
        "Got correct data for deal01"
    );

    ok !$hosts->get('specified'), 'No Such server';
};


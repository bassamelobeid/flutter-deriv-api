use Test::Most 0.22 (tests => 3);
use Test::Deep;
use Test::NoWarnings;
use BOM::Platform::Runtime;
use Sys::Hostname;

my $hosts = BOM::Platform::Runtime->instance->hosts;
isa_ok $hosts, 'BOM::System::Host::Registry';
my $hostname = hostname();
$hostname =~ s/^([^.]+).*$/$1/;

# here we depend on having only one dealing server during unit tests.
my $dealing_server = (BOM::System::Host::Registry->new({
        role_definitions => BOM::System::Host::Role::Registry->new,
    })->find_by_role("dealing_server"))[0];

subtest 'get_server and build' => sub {
    my $collector01 = $hosts->get($dealing_server->name);
    isa_ok $collector01, 'BOM::System::Host';
    cmp_deeply(
        $collector01,
        methods(
            name            => $dealing_server->name,
            domain          => $dealing_server->domain,
            external_domain => $dealing_server->external_domain,
        ),
        "Got correct data for deal01"
    );

    ok !$hosts->get('specified'), 'No Such server';
};


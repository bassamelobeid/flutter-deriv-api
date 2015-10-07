use Test::Most 0.22;
use Test::FailWarnings;

use BOM::System::Config;
use BOM::Platform::Context::Request;
use Sys::Hostname;
my $hostname = hostname();

sub website_domain () {
    for (BOM::System::Config::node->{node}->{environment}) {
        /^development$/ and return '.devbin.io';
        /^production$/  and return '.binary.com';
        /^qa\d+$/       and return '.binary' . $_ . '.com';
    }

    return 'Unexpected'
}

my $request = BOM::Platform::Context::Request->new;
is($request->cookie_domain, website_domain, 'Live site with "domain cookies" enabled.');

$request = BOM::Platform::Context::Request->new(domain_name => 'www.example.com');
is($request->cookie_domain, '.example.com', 'Live site with "domain cookies" enabled.');

$request = BOM::Platform::Context::Request->new(domain_name => 'example.com');
is($request->cookie_domain, '.example.com', 'Bare domain, and "domain cookies" enabled.');

done_testing;

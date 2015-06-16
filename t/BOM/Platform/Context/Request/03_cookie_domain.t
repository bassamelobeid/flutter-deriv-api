use Test::Most 0.22;
use Test::FailWarnings;

use BOM::Platform::Context::Request;
use Sys::Hostname;
my $hostname = hostname();

my $request = BOM::Platform::Context::Request->new;
is($request->cookie_domain, ".devbin.io", 'Live site with "domain cookies" enabled.');

$request = BOM::Platform::Context::Request->new(domain_name => 'www.example.com');
is($request->cookie_domain, '.example.com', 'Live site with "domain cookies" enabled.');

$request = BOM::Platform::Context::Request->new(domain_name => 'example.com');
is($request->cookie_domain, '.example.com', 'Bare domain, and "domain cookies" enabled.');

done_testing;

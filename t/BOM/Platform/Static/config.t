use Test::More;
use Test::FailWarnings;

use BOM::Platform::Static::Config;

is(BOM::Platform::Static::Config::get_static_path(), "/home/git/binary-com/binary-static/", 'Correct static path');
is(BOM::Platform::Static::Config::get_static_url(), "https://static.binary.com/", 'Correct static url');
is(BOM::Platform::Static::Config::get_customer_support_email(), 'support@binary.com', 'Correct customer support email');
is(scalar @{BOM::Platform::Static::Config::get_display_languages()}, 13, 'Correct number of language');
is(BOM::Platform::Static::Config::get_config(), BOM::Platform::Static::Config::get_config(), 'Static hash should be same even when requested multiple times');

done_testing();

use strict;
use warnings;
use Test::Most 0.22 (tests => 6);
use Test::NoWarnings;
use Test::MockModule;
use JSON qw(decode_json);
use Test::Warn;

use BOM::Platform::Runtime;

my $website_list;
lives_ok {
    $website_list = BOM::Platform::Runtime->instance->website_list;
}
'Initialized';

subtest 'default' => sub {
    my $website = $website_list->choose_website();
    ok $website, 'Got some website';
    is $website->name, 'Binary', 'Correct Website for no parameters';
};

subtest 'Binary' => sub {
    my $website = $website_list->choose_website({domain_name => 'www.binary.com'});
    ok $website, 'Got some website';
    is $website->name, 'Binary', 'Correct Website for domain_name www.binary.com';

    $website = $website_list->choose_website({domain_name => 'binary.com'});
    ok $website, 'Got some website';
    is $website->name, 'Binary', 'Correct Website for domain_name www.binary.com';
};

subtest 'BackOffice' => sub {
    my $website = $website_list->choose_website({backoffice => 1});
    is $website->name, 'BackOffice', 'Correct BackOffice Website';

    $website = $website_list->choose_website({
        domain_name => 'www.binary.com',
        backoffice  => 1
    });
    is $website->name, 'BackOffice', 'Correct BackOffice Website';

    $website = $website_list->choose_website({
        domain_name => 'www.binaryqa01.com',
        backoffice  => 1
    });
    is $website->name, 'BackOffice', 'Correct BackOffice Website';
};

subtest 'Binaryqa01' => sub {
    my $website = $website_list->choose_website({domain_name => 'www.binaryqa01.com'});
    ok $website, 'Got some website';
    is $website->name, 'Binaryqa01', 'Correct Website for domain_name www.binaryqa01.com';

    $website = $website_list->choose_website({domain_name => 'binaryqa01.com'});
    ok $website, 'Got some website';
    is $website->name, 'Binaryqa01', 'Correct Website for domain_name www.binaryqa01.com';
};


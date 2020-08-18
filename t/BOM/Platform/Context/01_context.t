#!/etc/rmg/bin/perl -I ../../../lib

use strict;
use warnings;

use Test::More (tests => 3);
use Test::Exception;
use Test::Warnings;

use BOM::Config::Runtime;
use BOM::Platform::Context qw(localize);
use BOM::Test::Localize qw(is_localized);

subtest 'request' => sub {
    ok(BOM::Platform::Context::request(), 'default');
    is(BOM::Platform::Context::request()->country_code, 'aq', 'default request');

    my $request = BOM::Platform::Context::Request->new(country_code => 'nl');

    ok(BOM::Platform::Context::request($request), 'new request');
    is(BOM::Platform::Context::request()->country_code, 'nl', 'new request');
};

subtest 'localize' => sub {
    my @bad_params = ('1=[_1] 2=[_2] 3=[_3]', '<LOC>one', 'two', 'three');
    ok !is_localized(localize(@bad_params)), 'invalid template message params';
    ok !is_localized(localize(\@bad_params)), 'invalid template message params (array ref)';

    my $message          = 'a message to localize';
    my @template_message = ('1=[_1] 2=[_2] 3=[_3]', 'one', 'two', 'three');
    is(localize(@template_message),  '<LOC>1=one 2=two 3=three</LOC>', 'template message is correctly localized');
    is(localize(\@template_message), '<LOC>1=one 2=two 3=three</LOC>', 'template message is correctly localized (array ref)');

    my $localized_message = localize($message);
    ok is_localized($localized_message, $message), 'valid localization';
    ok !is_localized($localized_message . ' concatenated'), 'concatenation with a non-localized string is rejected';
    ok !is_localized($localized_message . localize($message)), 'concatenation of two localized messages is rejected';

};

done_testing();

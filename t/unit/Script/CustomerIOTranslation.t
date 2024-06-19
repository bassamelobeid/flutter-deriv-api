use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Backoffice::Script::CustomerIOTranslation;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Context::Request;
use Data::Dumper;

# remember to mock anything that would hit the DB as unit tests don't support DB access
my $mock_language = 'en';
my $mock_request;
my $mock_translations = {};

sub mocklocal::maketext {
    my ($self, $str, @params) = @_;
    if (!defined($mock_translations->{$mock_language}))         { warn "missing language $mock_language when translating $str";  return $str }
    if (!defined($mock_translations->{$mock_language}->{$str})) { warn "missing phrase in $mock_language when translating $str"; return $str }
    my $tr = $mock_translations->{$mock_language}->{$str};
    #print "In mock maketext $mock_language :: $mock_language $str -> $tr\n";
    return $tr;
}

my $client_mock_i18n = Test::MockModule->new('BOM::Platform::Context::I18N');
$client_mock_i18n->mock(
    'handle_for',
    sub {
        return bless {}, "mocklocal";    #This makes it use our maketext method above
    });

#This is rather nasty, BOM::Backoffice::Script::CustomerIOTranslation imported request, so we have to mock it there as mocking it in BOM::Platform::Context doesn't help because CustomerIOTranslation has a reference to that method already
my $client_mock_customeriotranslations = Test::MockModule->new('BOM::Backoffice::Script::CustomerIOTranslation');
$client_mock_customeriotranslations->mock(
    'request',
    sub {
        my ($param) = @_;
        if (defined($param)) {
            $mock_request  = $param;
            $mock_language = $param->language;
            #print "Set mock_language to $mock_language\n";
        }
        return $mock_request;
    });

subtest 'check_localize_placeholders' => sub {
    $mock_translations = {
        fr        => {'Test_Translation_ABC[_1] test [_2] words [_3]' => 'Test_Translation_French[_1] test [_2] words [_3]'},
        backwards => {'Test_Translation_ABC[_1] test [_2] words [_3]' => 'Test_Translation_Backwards[_3][_2][_1]'},
        broken    => {'Test_Translation_ABC[_1] test [_2] words [_3]' => 'Test_Translation_Broken[_1] test [_2]'},
    };
    is BOM::Backoffice::Script::CustomerIOTranslation::check_localize_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]', 'fr', [], 0),
        undef;
    like BOM::Backoffice::Script::CustomerIOTranslation::check_localize_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]', 'broken', [],
        0),
        qr/Placeholder count mismatch 3!=2/;

    is BOM::Backoffice::Script::CustomerIOTranslation::check_localize_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'backwards', [], 0),
        undef;
    like BOM::Backoffice::Script::CustomerIOTranslation::check_localize_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'backwards', [], 1),
        qr/Placeholder mismatch at 1/;

    is BOM::Backoffice::Script::CustomerIOTranslation::check_localize_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]', 'broken', [3], 0),
        undef;
    like BOM::Backoffice::Script::CustomerIOTranslation::check_localize_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'broken', [1, 2], 0),
        qr/Placeholder count mismatch 1!=0/;
};

subtest 'BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders' => sub {
    $mock_translations = {
        fr        => {'Test_Translation_ABC[_1] test [_2] words [_3]' => 'Test_Translation_French[_1] test [_2] words [_3]'},
        backwards => {'Test_Translation_ABC[_1] test [_2] words [_3]' => 'Test_Translation_Backwards[_3][_2][_1]'},
        broken    => {'Test_Translation_ABC[_1] test [_2] words [_3]' => 'Test_Translation_Broken[_1] test [_2]'},
    };

    my $field_placeholders = ['{{firstName}}', '{{ middlename}}', '{{ lastname }}'];
    is BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'fr', $field_placeholders),
        undef;
    is BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'backwards', $field_placeholders),
        undef;
    like BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'broken', $field_placeholders),
        qr/Basic: Placeholder count mismatch 3!=2/;

    my $code_placeholders = ['{%if foo%}', '{% else%}', '{% endif %}'];
    is BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'fr', $code_placeholders),
        undef;
    like BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'backwards', $code_placeholders),
        qr/Liquid order: Placeholder mismatch at 1/;
    like BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'broken', $code_placeholders),
        qr/Basic: Placeholder count mismatch 3!=2/;

    my $html_placeholders = ['<a href="foo">', '<br>', '</a>'];
    is BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'fr', $html_placeholders),
        undef;
    like BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'backwards', $html_placeholders),
        qr/Html order: Placeholder mismatch at 1/;
    like BOM::Backoffice::Script::CustomerIOTranslation::check_localize_liquid_placeholders('Test_Translation_ABC[_1] test [_2] words [_3]',
        'broken', $html_placeholders),
        qr/Basic: Placeholder count mismatch 3!=2/;

};

done_testing;

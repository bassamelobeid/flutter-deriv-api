use strict;
use warnings;
use Test::More;
use BOM::Event::Transactional::Filter::Equal;
use BOM::Event::Transactional::Filter::Exist;
use BOM::Event::Transactional::Filter::Contain;
use BOM::Event::Transactional::Filter::NotContain;
use BOM::Event::Transactional::Filter::NotEqual;
use BOM::Event::Transactional::Mapper;
use Test::MockModule;

subtest 'Equal' => sub {
    my $filter = BOM::Event::Transactional::Filter::Equal->new;
    my $res    = $filter->parse('property', 'string');
    ok $res, 'string captured';
    ok $res->apply({'property'        => 'string'}),       'string matched';
    ok !$res->apply({'other_property' => 'string'}),       'string not matched';
    ok !$res->apply({'property'       => 'other string'}), 'string not matched';
    $res = $filter->parse('property', {hash => 'ref'});
    ok !$res, 'hash ref not parsed';
    $res = $filter->parse('property', ['array']);
    ok !$res, 'not parsed';
    $res = $filter->parse('property', {is => 'ref'});
    ok $res, 'is keyword captured';
};

subtest 'exist' => sub {
    my $filter = BOM::Event::Transactional::Filter::Exist->new;
    my $res    = $filter->parse('property', 1);
    ok !$res, 'not parsed';
    $res = $filter->parse('property', '1');
    ok !$res, 'not parsed';
    $res = $filter->parse('property', ['array']);
    ok !$res, 'not parsed';
    $res = $filter->parse('property', {hash => 'ref'});
    ok !$res, 'not parsed';
    $res = $filter->parse('property', {'exists' => 0});
    ok $res, ' parsed';
};

subtest 'contains' => sub {
    my $filter = BOM::Event::Transactional::Filter::Contain->new;
    my $res    = $filter->parse('property', 1);
    ok !$res, 'not parsed';
    $res = $filter->parse('property', '1');
    ok !$res, 'not parsed';
    $res = $filter->parse('property', ['array']);
    ok !$res, 'not parsed';
    $res = $filter->parse('property', {hash => 'ref'});
    ok !$res, 'not parsed';
    $res = $filter->parse('property', {'contains' => 'string'});
    ok $res, 'parsed';
    ok $res->apply({'property'  => 'a string'});
    ok !$res->apply({'property' => 'not found'});
};

subtest 'contains - Array support (or operation)' => sub {
    my $filter = BOM::Event::Transactional::Filter::Contain->new;
    my $res    = $filter->parse('property', {'contains' => ['string', 'other word']});
    ok $res, 'parsed';
    ok $res->apply({'property'  => 'a string'}),                     'string matched';
    ok $res->apply({'property'  => 'other word is in this string'}), 'string matched';
    ok !$res->apply({'property' => 'non included str'}),             'string not matched';
    # case with array
    ok $res->apply({'property'  => ['string',           'other word']}), 'string matched';
    ok $res->apply({'property'  => ['other word',       'string']}),     'string matched';
    ok !$res->apply({'property' => ['non included str', 'not here']}),   'string not matched';
};

subtest 'not contain' => sub {
    my $filter = BOM::Event::Transactional::Filter::NotContain->new;
    my $res    = $filter->parse('property', 1);
    ok !$res, 'not parsed';
    $res = $filter->parse('property', '1');
    ok !$res, 'not parsed';
    $res = $filter->parse('property', ['array']);
    ok !$res, 'not parsed';
    $res = $filter->parse('property', {hash => 'ref'});
    ok !$res, 'not parsed';
    $res = $filter->parse('property', {'not_contain' => 'string'});
    ok $res, 'parsed';
    ok !$res->apply({'property' => 'a string'});
    ok $res->apply({'property'  => 'not found'});
};

subtest 'not contains - Array support (or operation)' => sub {
    my $filter = BOM::Event::Transactional::Filter::NotContain->new;
    my $res    = $filter->parse('property', {'not_contain' => ['string', 'other word']});
    ok $res, 'parsed';
    ok !$res->apply({'property' => 'a string'}),                     'string matched';
    ok !$res->apply({'property' => 'other word is in this string'}), 'string matched';
    ok $res->apply({'property'  => 'non included str'}),             'string not matched';
};

subtest 'NotEqual' => sub {
    my $filter = BOM::Event::Transactional::Filter::NotEqual->new;
    my $res    = $filter->parse('property', 'string');
    ok !$res, 'string not parsed';
    $res = $filter->parse('property', {hash => 'ref'});
    ok !$res, 'hash ref not parsed';
    $res = $filter->parse('property', ['array']);
    ok !$res, 'not parsed';
    $res = $filter->parse('property', {not_equal => 'ref'});
    ok $res, 'not_equal keyword captured';
    ok !$res->apply({'property' => 'ref'}),    'fail equal strings';
    ok $res->apply({'property'  => 'string'}), 'string matched';
};

subtest 'mapper' => sub {
    my $mock_mapper = Test::MockModule->new('YAML::XS');
    $mock_mapper->mock(
        'LoadFile' => sub {
            return {
                signup => [{
                        welcome_deriv => {
                            country       => {not_contain => 'france'},
                            brand         => 'a',
                            server        => {contains => 'mt5'},
                            social_signup => {exists   => 1}}
                    },
                    {welcome_binary => {brand => 'binary'}}]};
        });
    my $mapper = BOM::Event::Transactional::Mapper->new;
    $mapper->load;
    my $res = $mapper->get_event({
            event      => 'signup',
            properties => {
                country       => 'brazil',
                social_signup => 1,
                brand         => 'a',
                server        => 'real-mt5'
            }});
    is $res, 'welcome_deriv', 'correct map';
    $res = $mapper->get_event({event => 'signup'});
    ok !$res, 'not match';
    $res = $mapper->get_event({event => 'not_conditional'});
    is $res, 'not_conditional', 'not conditional event returned';
};

done_testing();

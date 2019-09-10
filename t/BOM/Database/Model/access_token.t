#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init :disable_cleanup);

use BOM::Database::Model::AccessToken;
use Date::Utility;

my $db_model = BOM::Database::Model::AccessToken->new;

subtest 'save_token' => sub {
    my $args = {
        token => _token(),
        display_name => 'test',
        loginid => 'CR123',
        scopes => ['read'],
        valid_for_ip => '',
        creation_time => Date::Utility->new->db_timestamp,
    };
    my $res = $db_model->save_token($args);
    ok $res, 'successfully saved';

    is $res->{token}, $args->{token}, 'token matched';
    $args->{token} = _token();
    $res = $db_model->save_token($args);
    ok $res, 'saved when display_name is the same';
    is $res->{token}, $args->{token}, 'token matched';

    $args->{loginid} = 'CR1234';
    $args->{token} = _token();
    $res = $db_model->save_token($args);
    ok $res, 'saved successfully';
    ok $db_model->_update_token_last_used($res->{token}, Date::Utility->new->db_timestamp), 'last_used timestamp updated';
};

my $tokens;
subtest 'get_all_tokens_by_loginid' => sub {
    $tokens = $db_model->get_all_tokens_by_loginid('CR123');
    is scalar(@$tokens), 2, 'two tokens for CR123';
    $tokens = $db_model->get_all_tokens_by_loginid('CR1234');
    is scalar(@$tokens), 1, 'one token for CR1234';
};

subtest 'remove_by_token' => sub {
    ok $db_model->remove_by_token($tokens->[0]->{token}, Date::Utility->new->db_timestamp), 'removed token';
    $tokens = $db_model->get_all_tokens_by_loginid('CR1234');
    is scalar(@$tokens), 0, 'no token for CR1234';
};

done_testing();

sub _token {
    my @a = ('A'..'Z');
    return join '', map {$a[int(rand($#a))]} (1..5);
}

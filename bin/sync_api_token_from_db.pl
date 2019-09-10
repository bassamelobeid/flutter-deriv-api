#!/usr/bin/perl

use strict;
use warnings;

use BOM::Database::Model::AccessToken;
use BOM::Platform::Token::API;

my $db_model   = BOM::Database::Model::AccessToken->new;
my $tokens_ref = $db->get_all_tokens;
my $api_obj = BOM::Platform::Token::API->new;

foreach my $details (values %$tokens_ref) {
    next if $api_obj->token_exists($details->{token});
    $api_obj->save_token_details_to_redis($details);
}

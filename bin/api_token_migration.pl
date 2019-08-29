#!/usr/bin/perl

use strict;
use warnings;

use BOM::Database::Model::AccessToken;
use BOM::Platform::Token::API;

my $model   = BOM::Database::Model::AccessToken->new;
my $p_token = BOM::Platform::Token::API->new;

my $res = $model->dbic->run(
    fixup => sub {
        my $sth = $_->prepare("SELECT * FROM auth.access_token");
        $sth->execute();
        while (my $row = $sth->fetchrow_hashref) {
            $row->{$_} //= '' for keys %$row;
            $row->{loginid} = delete $row->{client_loginid};
            $p_token->save_token_details_to_redis($row);
        }
    });

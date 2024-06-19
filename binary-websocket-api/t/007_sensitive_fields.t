use strict;
use warnings;

use Test::More;
use Test::Warnings;

use JSON::MaybeUTF8 qw(decode_json_text);
use List::Util      qw(pairgrep);
use Path::Tiny;
use constant BASE_PATH => 'config/v3/';

my %elements;

for my $file (qx{git ls-files @{[BASE_PATH]}}) {
    chomp $file;
    my ($method, $type) = ($file =~ m{^@{[BASE_PATH]}([a-z0-9_]+)/([a-z]+)\.json$});
    next if $type eq 'example';
    my $schema = decode_json_text(path($file)->slurp_utf8);
    my $items  = get_items($schema->{properties});
    $elements{"$method/$type" . $_->{path}} = $_->{item} for @$items;
}

sub get_items {
    my $node = shift // {};
    my $path = shift // '';
    my @result;

    for my $k (sort keys %$node) {
        if (($node->{$k}{type} // '') eq 'object') {
            push @result, get_items($node->{$k}{properties},        "$path/$k")->@*;
            push @result, get_items($node->{$k}{patternProperties}, "$path/$k")->@*;
        } elsif (($node->{$k}{type} // '') eq 'array') {
            push @result, get_items($node->{$k}{items}{properties},        "$path/$k")->@*;
            push @result, get_items($node->{$k}{items}{patternProperties}, "$path/$k")->@*;
        }

        push @result,
            {
            item => $node->{$k},
            path => "$path/$k"
            };
    }

    return \@result;
}

# This test searches elements by applying these items as regex against the json path.
# Regexes are anchored at the end.
# Path format: p2p_advert_create/receive/p2p_advert_create/contact_info

# sensitive fields have PII and/or security risk if leaked in logs.
my @sensitive_fields = qw(
    authorize/send/authorize
    /password
    /investPassword
    /mainPassword
    /phonePassword
    /new_password
    /old_password
    /client_password
    /token
    sell_contract_for_multiple_accounts/tokens
    /chat_token
    /secret_answer
    /first_name
    /last_name
    /phone
    /contact_info
    /payment_info
    /p2p.+?/name
    /p2p.+?/description
    /p2p.+?/first_name
    /p2p.+?/last_name
    /p2p_advertiser_payment_methods/create
    /p2p_advertiser_payment_methods/update
    /valid_for_ip
);

for my $field (@sensitive_fields) {
    my %items = pairgrep { $a =~ /$field$/ } %elements;
    for my $k (sort keys %items) {
        ok $items{$k}->{sensitive}, "$k has sensitive attribute";
    }
}

done_testing;

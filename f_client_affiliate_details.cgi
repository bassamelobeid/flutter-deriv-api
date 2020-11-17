#!/etc/rmg/bin/perl
package main;

=pod

=head1 DESCRIPTION

This script retrieves affiliate details by client loginid and displays them as a table.
It will also indicate whether or not the client is not an affiliate.

=cut

use strict;
use warnings;

use List::Util qw(first);

use BOM::MyAffiliates;
use BOM::User::Client;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("AFFILIATE DETAILS");

my $input           = request()->params;
my $loginid         = $input->{loginid} // '';
my $encoded_loginid = encode_entities($loginid);

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid, db_operation => 'backoffice_replica'}) };

code_exit_BO(qq[ERROR : Wrong loginID $encoded_loginid]) unless $client;

my $my_affiliates = BOM::MyAffiliates->new();

my @affiliates;
for my $sibling ($client->user->clients) {
    my $res = $my_affiliates->get_users(
        VARIABLE_NAME  => 'affiliates_client_loginid',
        VARIABLE_VALUE => $sibling->loginid
    );
    my @result =
          ref $res->{USER} eq 'ARRAY' ? @{$res->{USER}}
        : $res->{USER}                ? ($res->{USER})
        :                               ();
    push @affiliates, @result;
}

code_exit_BO(qq[Client isn\'t an affiliate]) unless @affiliates;

for my $affiliate (@affiliates) {
    next unless $affiliate->{USER_VARIABLES}->{VARIABLE};

    # Arrays with single elements are being received as a hash. Let's fix it.
    if (ref($affiliate->{SUBSCRIPTIONS}->{SUBSCRIPTION}) ne 'ARRAY') {
        $affiliate->{SUBSCRIPTIONS}->{SUBSCRIPTION} = [$affiliate->{SUBSCRIPTIONS}->{SUBSCRIPTION}];
    }
    if (ref($affiliate->{USER_COMMENTS}->{COMMENT}) ne 'ARRAY') {
        $affiliate->{USER_COMMENTS}->{COMMENT} = [$affiliate->{USER_COMMENTS}->{COMMENT}];
    }
    if (ref($affiliate->{USER_DETAILS}->{DETAIL}) ne 'ARRAY') {
        $affiliate->{USER_DETAILS}->{DETAIL} = [$affiliate->{USER_DETAILS}->{DETAIL}];
    }
    if (ref($affiliate->{USER_VARIABLES}->{VARIABLE}) ne 'ARRAY') {
        $affiliate->{USER_VARIABLES}->{VARIABLE} = [$affiliate->{USER_VARIABLES}->{VARIABLE}];
    }

    my $loginid_variable = first { $_->{NAME} eq 'affiliates_client_loginid' } $affiliate->{USER_VARIABLES}->{VARIABLE}->@*;
    $affiliate->{loginid} = $loginid_variable->{VALUE};
    my $mt5_variable = first { $_->{NAME} eq 'mt5_account' } $affiliate->{USER_VARIABLES}->{VARIABLE}->@*;
    my $mt5_loginid  = $mt5_variable->{VALUE} ? $client->user->get_loginid_for_mt5_id($mt5_variable->{VALUE}) : undef;

    if ($mt5_loginid) {
        my ($mt5_group, $mt5_status) = get_mt5_group_and_status($mt5_loginid);
        $affiliate->{mt5_account} = $mt5_variable->{VALUE} . ($mt5_group ? " ($mt5_group - $mt5_status)" : ' (waiting to get mt5 group and status)');
    } elsif ($mt5_variable->{VALUE}) {
        $affiliate->{mt5_account} = $mt5_variable->{VALUE} . ' (belongs to another user)';
    }

    # convert empty hash to empty string (just for parent id and name)
    $affiliate->{PARENT_ID}       = '' if ref($affiliate->{PARENT_ID}) eq 'HASH';
    $affiliate->{PARENT_USERNAME} = '' if ref($affiliate->{PARENT_USERNAME}) eq 'HASH';

    $affiliate->{USER_DETAILS}->{DETAIL} //= [];
    my @user_details_array = $affiliate->{USER_DETAILS}->{DETAIL}->@*;
    $affiliate->{user_details} = [];

    # sort known keys
    for my $key (
        qw(first_name last_name individual business business_regnumber warranty agreement  address state city postcode phone_number skype website other_comments)
        )
    {
        my $found_detail = first { $_->{NAME} eq $key } @user_details_array;
        if ($found_detail) {
            push $affiliate->{user_details}->@*, $found_detail;
            $found_detail->{known} = 1;
        }
    }

    # append unknown keys
    push $affiliate->{user_details}->@*, grep { not $_->{known} } @user_details_array;

    Bar(" AFFILIATE DETAILS - $affiliate->{loginid} ");

    my $client_details_link = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $affiliate->{loginid}});

    print qq{<a href='$client_details_link'>&laquo; return to client details</a><p>};

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_affiliate_details.html.tt',
        {
            affiliate => $affiliate,
        });
}

code_exit_BO();

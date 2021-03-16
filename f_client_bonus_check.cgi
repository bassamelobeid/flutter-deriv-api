#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
use Syntax::Keyword::Try;
use Date::Utility;
use BOM::User::Client;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Database::ClientDB;
use BOM::MyAffiliates;
use BOM::Backoffice::PromoCodeEligibility;
use JSON::MaybeXS;
BOM::Backoffice::Sysinit::init();

use BOM::Config;
my $app_config = BOM::Config::Runtime->instance->app_config;
my $json       = JSON::MaybeXS->new;
my %input      = %{request()->params};
PrintContentType();

=head1 f_client_bonus_check.cgi

Description: To be used by marketing to approve Bonus payments.
This purposefully does not apply any rules as the decision to grant
a bonus or not is largely up to the staff member. It attempts to
give the information required to make that decision and the tools
to quickly approve or reject the bonus.

It will first check myaffiliates for the bonus code and if one does not exist
it will offer the opportunity to manually  enter a bonus code.

=cut

### Header Stuff ###

my %details = get_client_details(\%input, 'backoffice/f_client_bonus_check.cgi');

my $client          = $details{client};
my $user            = $details{user};
my $encoded_loginid = $details{encoded_loginid};
my $mt_logins       = $details{mt_logins};
my $user_clients    = $details{user_clients};
my $broker          = $details{broker};
my $encoded_broker  = $details{encoded_broker};
my $is_virtual_only = $details{is_virtual_only};
my $clerk           = $details{clerk};
my $self_post       = $details{self_post};
my $self_href       = $details{self_post};
my $loginid         = $client->loginid;
my $currency        = $client->currency;

client_search_and_navigation($client, $self_post);

# End of header stuff
##################################################

##################################################
#  Apply form Submissions
#

if ($input{apply_bonus_code}) {

    my $encoded_promo_code = encode_entities(uc $input{apply_bonus_code});
    try {
        $client->promo_code($encoded_promo_code);
        $client->save();
    } catch ($e) {
        code_exit_BO(sprintf('<p class="error">ERROR: %s</p>', $e));
    };

}

# End apply form submissions
##################################################

# view client's statement/portfolio/profit table
#

BOM::Backoffice::Request::template()->process(
    'backoffice/client_statement_get.html.tt',
    {
        history_url     => request()->url_for('backoffice/f_manager_history.cgi'),
        statement_url   => request()->url_for('backoffice/f_manager_statement.cgi'),
        self_post       => $self_post,
        encoded_loginid => $encoded_loginid,
        encoded_broker  => $encoded_broker,
        checked         => 'checked="checked"',
    });

Bar("$loginid STATUSES");
my $statuses = join '/', map { uc } @{$client->status->all};
if (my $statuses = build_client_warning_message($loginid)) {
    print $statuses;
}
my $name = $client->full_name;
my $client_info = sprintf "%s %s%s", $client->loginid, ($name || '?'), ($statuses ? " [$statuses]" : '');
Bar("CLIENT " . $client_info);

print "<p>Corresponding accounts: </p><ul>";

# show all BOM loginids for user, include disabled acc
foreach my $lid ($user_clients->@*) {
    next
        if ($lid->loginid eq $client->loginid);

    # get BOM loginids for the user, and get instance of each loginid's currency
    my $client = BOM::User::Client->new({loginid => $lid->loginid});
    my $currency =
          $client->default_account
        ? $client->default_account->currency_code
        : 'No currency selected';

    my $link_href = request()->url_for(
        'backoffice/f_clientloginid_edit.cgi',
        {
            broker  => $lid->broker_code,
            loginID => $lid->loginid,
        });

    print "<li><a href='$link_href'"
        . ($client->status->disabled ? ' class="error"' : ' class="link link--primary"') . ">"
        . encode_entities($lid->loginid) . " ("
        . $currency
        . ") </a></li>";

}

print "</ul>";

my $log_args = {
    broker   => $broker,
    category => 'client_details',
    loginid  => $loginid
};
my $new_log_href = request()->url_for('backoffice/show_audit_trail.cgi', $log_args);
print qq{<p><a class="btn btn--primary" href="$new_log_href">View history of changes to $encoded_loginid</a></p>};

##################################################
# Main Section of page
#

my $statement_to_date   = Date::Utility->new();
my $statement_from_date = $statement_to_date->_minus_months(3);
my $transactions        = get_transactions_details({
    client   => $client,
    from     => $statement_from_date->minus_time_interval('1s')->datetime_yyyymmdd_hhmmss(),
    to       => $statement_to_date->plus_time_interval('1s')->datetime_yyyymmdd_hhmmss(),
    currency => $currency,
    limit    => 99999,
});

# first we try to get bonus info from Myaffiliates failing that we check if the client already
# has bonus information (which was set manually)

my $affiliate_promo;
if ($client->myaffiliates_token) {
    $affiliate_promo = get_myaffilate_information($client);
}

if (!$affiliate_promo && $client->promo_code) {
    $affiliate_promo = get_promo_information($client->promo_code, $client->db->dbic);
}

code_exit_BO('<p class="error">Client has no promo code assigned</p>') unless $affiliate_promo;

my $amount = $affiliate_promo->{config}{amount};

# Amount for GET_X_OF_DEPOSITS is dependant on eligible deposits made
if ($affiliate_promo->{promo_code_type} eq 'GET_X_OF_DEPOSITS') {
    ($amount) = BOM::Backoffice::PromoCodeEligibility::get_dynamic_bonus(
        db           => $client->db->dbic,
        account_id   => $client->account->id,
        code         => $affiliate_promo->{code},
        promo_config => $affiliate_promo->{config},
    );
}

my $countries_instance = request()->brand->countries_instance->countries;
my $country_residence  = $countries_instance->country_from_code($client->residence);
my $client_country_matches_promo;
if ($affiliate_promo) {
    my $promo_countries = $affiliate_promo->{config}->{country};
    my $res             = $client->residence;
    $client_country_matches_promo = (
        ($promo_countries =~ /$res/)
            or $promo_countries eq 'ALL'
    ) ? 1 : 0;    #TODO bonus country(s) is stored as a string would make more sense as an array
}
my $claimed_already = 0;
if (    $affiliate_promo
    and defined($affiliate_promo->{code})
    and defined($client->promo_code)
    and $client->promo_code eq $affiliate_promo->{code}
    and $client->promo_code_status =~ /^(CLAIM|REJECT)$/)
{
    $claimed_already = $client->promo_code_status;
}

my $join_date = Date::Utility->new($client->date_joined);

BOM::Backoffice::Request::template()->process(
    'backoffice/client_bonus_check.html.tt',
    {
        client                       => $client,
        amount                       => $amount,
        country_residence            => $country_residence,
        affiliate_promo              => $affiliate_promo,
        transactions                 => $transactions,
        today                        => Date::Utility->new(),
        join_date                    => $join_date,
        request                      => request(),
        claimed_already              => $claimed_already,
        bonus_deposit_amount         => $app_config->get('marketing.bonus_deposit_amount'),
        bonus_deposit_age            => $app_config->get('marketing.bonus_deposit_age'),
        bonus_sign_up_age            => $app_config->get('marketing.bonus_sign_up_age'),
        bonus_dubious_countries      => $app_config->get('marketing.bonus_dubious_countries'),
        client_country_matches_promo => $client_country_matches_promo,
    });

##################################################
# End of Main section
#

Bar($user->{email} . " Login history");
my $limit         = 200;
my $login_history = $user->login_history(
    order                    => 'desc',
    show_impersonate_records => 1,
    limit                    => $limit
);

BOM::Backoffice::Request::template()->process(
    'backoffice/user_login_check.html.tt',
    {
        user    => $user,
        history => $login_history,
        limit   => $limit
    });

code_exit_BO();

=head2 get_myaffilate_information

Description: Gets the Bonus promotion code from myaffiliates if
the client has registered via myaffiliates and has a myaffiliates token.
Takes the following argument

=over 4

=item - $client L<BOM::User::Client>


=back

Returns the promo code as a string or undef.

=cut

sub get_myaffilate_information {
    my ($client)      = @_;
    my $my_affiliates = BOM::MyAffiliates->new();
    my $affiliate_id  = $my_affiliates->get_affiliate_id_from_token($client->myaffiliates_token);
    return undef if !$affiliate_id;

    my $affiliate = $my_affiliates->get_user($affiliate_id);

    return undef if !$affiliate;

    my $myaffiliate_promo_code = '';

    # MyAffilates User_variables look like
    # 'USER_VARIABLES' => {
    #                      'VARIABLE' => [
    #                                      {
    #                                        'NAME' => 'affiliates_client_loginid',
    #                                        'VALUE' => 'CR1234'
    #                                      },
    #                                      {
    #                                        'NAME' => 'betonmarkets_promo_code',
    #                                        'VALUE' => ';0013F10;'
    #                                      },

    foreach my $affiliate_user_variable ($affiliate->{USER_VARIABLES}->{VARIABLE}->@*) {

        if ($affiliate_user_variable->{NAME} eq 'betonmarkets_promo_code') {
            $myaffiliate_promo_code = $affiliate_user_variable->{VALUE};

            last;
        }
    }
    return get_promo_information($myaffiliate_promo_code, $client->db->dbic);
}

=head2 get_promo_information

Description: Retrieve Promotional information from the DB using the promo code.
converts  the JSON (promo_code_config) field into Perl vars and dates into L<Date::Utility> Objects
Takes the following arguments

=over 4

=item - $promo_code String Id of promo code.

=item - $dbic L<DBIx::Connector::Pg>

=back

Returns an hashref

      {
          'start_date' => 'Date::Utility',
          'description' => 'description text ',
          'status' => 1,
          'promo_code_config' => JSON string with promotion code configuration,
          'expiry_date' => 'Date::Utility',
          'code' => promo_code string ,
          'config' => { Perl Representaion of promo_code_config field
                        'currency' => alphanumeric with length of two or more,
                        'country' => Country that bonus applies to ,
                        'amount' => amount to credit account
                      }
       }

or

undef  if not found

=cut

sub get_promo_information {
    my ($promo_code, $dbic) = @_;
    my $json            = JSON::MaybeXS->new;
    my $affiliate_promo = undef;
    if ($promo_code) {

        #code from myaffilates is wrapped in ";"
        $promo_code =~ s/;//g;
        $affiliate_promo = $dbic->run(
            fixup => sub {
                $_->selectrow_hashref("SELECT * FROM betonmarkets.promo_code WHERE code = ?", undef, ($promo_code));
            });
    }

    if ($affiliate_promo) {
        $affiliate_promo->{config} =
            $json->decode($affiliate_promo->{promo_code_config});
        $affiliate_promo->{expiry_date} =
            Date::Utility->new($affiliate_promo->{expiry_date});
        $affiliate_promo->{start_date} =
            Date::Utility->new($affiliate_promo->{start_date});
    }
    return $affiliate_promo;
}

1;

package BOM::Service::User::Attributes;

use strict;
use warnings;
no indirect;
use Scalar::Util qw(blessed looks_like_number);

use BOM::Service::User::Attributes::Get;
use BOM::Service::User::Attributes::Update;

our %ATTRIBUTES = (
    accepted_tnc_version => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_accepted_tnc_version,
        set_handler => \&BOM::Service::User::Attributes::Update::set_accepted_tnc_version
    },
    account_opening_reason => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    address_city => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    address_line_1 => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    address_line_2 => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    address_postcode => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    address_state => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    allow_login => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    aml_risk_classification => {
        type        => 'type',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    # app_id => {                               Not supported, not used by code/apps, not updatable
    #     type        => 'int',
    #     get_handler => \&get_user_data,
    #     set_handler => \&set_user_data
    # },
    binary_user_id => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported,
        remap       => 'id'
    },
    cashier_setting_password => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    checked_affiliate_exposures => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    citizen => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    comment => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    custom_max_acbal => {
        type        => 'int',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    custom_max_daily_turnover => {
        type        => 'int',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    custom_max_payout => {
        type        => 'int',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    # date_first_contact => {                        Not supported, doesn't look to actually be used
    #     type        => 'date',
    #     get_handler => \&get_user_data,
    #     set_handler => \&set_user_data
    # },
    date_joined => {
        type        => 'date',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    date_of_birth => {
        type        => 'date',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    default_client => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported,
        remap       => 'loginid'
    },
    dx_trading_password => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_dx_trading_password
    },
    email => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_email
    },
    email_consent => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_email
    },
    email_verified => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_email
    },
    fatca_declaration_time => {
        type        => 'date',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    fatca_declaration => {
        type        => 'bool-nullable',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    feature_flag => {
        type        => 'json',
        get_handler => \&BOM::Service::User::Attributes::Get::get_feature_flag,
        set_handler => \&BOM::Service::User::Attributes::Update::set_feature_flag
    },
    financial_assessment => {
        type        => 'json',
        get_handler => \&BOM::Service::User::Attributes::Get::get_financial_assessment,
        set_handler => \&BOM::Service::User::Attributes::Update::set_financial_assessment
    },
    first_name => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    first_time_login => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    gclid_url => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
    gender => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    has_social_signup => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_has_social_signup
    },
    id => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_id,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
    immutable_attributes => {
        type        => 'json',
        get_handler => \&BOM::Service::User::Attributes::Get::get_immutable_attributes,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
    is_totp_enabled => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_totp_fields
    },
    last_name => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    latest_environment => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    mifir_id => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    myaffiliates_token => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    myaffiliates_token_registered => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    non_pep_declaration_time => {
        type        => 'date',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    password => {
        type  => 'string',
        flags => {
            password_update_reason => [qw(reset_password change_password)],
            password_previous      => 1
        },
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_password
    },
    payment_agent_withdrawal_expiration_date => {
        type        => 'date',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    phone => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    phone_number_verification => {
        type        => 'bool',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_phone_number_verification,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_phone_number_verification
    },
    place_of_birth => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    preferred_language => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_preferred_language
    },
    residence => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    restricted_ip_address => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    salutation => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    secret_answer => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    secret_key => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_totp_fields
    },
    secret_question => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    signup_device => {
        type        => 'type',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
    small_timer => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    source => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    tax_identification_number => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    tax_residence => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_client_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_client_data
    },
    trading_password => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_user_trading_password
    },
    utm_campaign => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
    utm_data => {
        type        => 'json',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
    utm_medium => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
    utm_source => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_data,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
    uuid => {
        type        => 'string',
        get_handler => \&BOM::Service::User::Attributes::Get::get_user_uuid,
        set_handler => \&BOM::Service::User::Attributes::Update::set_not_supported
    },
);

=head2 get_all_attributes

Returns a reference to the hash %ATTRIBUTES which contains all the user attributes.

=over 4

=item * Return: Hash reference to %ATTRIBUTES

=back

=cut

sub get_all_attributes {
    return \%ATTRIBUTES;
}

=head2 get_requested_attributes

Takes an array reference of attribute names and returns a hash reference where the keys are the attribute names and the values are the corresponding attribute handlers from the %ATTRIBUTES hash. If an attribute is not found in %ATTRIBUTES, the subroutine dies with an error message.

=over 4

=item * Input: Array reference of attribute names

=item * Return: Hash reference of attribute handlers

=back

=cut

sub get_requested_attributes {
    my ($attributes) = @_;
    my $handlers = ();

    for my $attribute (@{$attributes}) {
        die "Invalid attribute: '$attribute'" unless $ATTRIBUTES{$attribute};
        $handlers->{$attribute} = $ATTRIBUTES{$attribute};
    }
    return $handlers;
}

1;

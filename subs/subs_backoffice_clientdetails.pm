## no critic (RequireExplicitPackage)
use strict;
use warnings;
no indirect;

use Encode;
use Date::Utility;
use Format::Util::Strings qw( set_selected_item );
use Format::Util::Numbers qw/ formatnumber /;
use Locale::Country 'code2country';
use Finance::MIFIR::CONCAT qw(mifir_concat);
use LWP::UserAgent;
use HTTP::Headers;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use LandingCompany::Registry;
use List::MoreUtils qw(any);
use Log::Any        qw($log);
use YAML::XS        qw(LoadFile);

use BOM::Config::Onfido;
use BOM::Transaction::Utility;
use BOM::Config;
use BOM::User::AuditLog;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::Account;
use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Payment::DoughFlow;
use BOM::User::Utility;
use BOM::Platform::Locale;
use BOM::Platform::Context;
use BOM::Platform::S3Client;
use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Utility;
use BOM::Backoffice::FormAccounts;
use BOM::Backoffice::Config;
use BOM::Database::Model::HandoffToken;
use BOM::Config::Redis;
use BOM::User::Client;
use BOM::User::Client::Status;
use BOM::Backoffice::Request qw(request localize);
use BOM::User::Onfido;
use BOM::User::SocialResponsibility;
use BOM::Transaction::Utility;
use BOM::User::AuditLog;
use BOM::Backoffice::Request qw(request);
use BOM::User::Onfido;
use BOM::User::SocialResponsibility;
use BOM::User::IdentityVerification;
use BOM::Rules::Engine;
use BOM::Platform::Doughflow;
use BOM::User::LexisNexis;
use BOM::Config::Compliance;
use Deriv::TradingPlatform::MT5::UserRights qw(to_hash);

my $compliance_config = BOM::Config::Compliance->new;

use 5.010;

=head1 subs_backoffice_clientdetails

A spot to place subroutines that might be useful for various client related operations

=cut

use constant ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX  => 'ONFIDO::RESUBMISSION_COUNTER::ID::';
use constant RISK_DISCLAIMER_RESUBMISSION_KEY_PREFIX => 'RISK_DISCLAIMER_RESUBMISSION::ID::';
use constant ACCOUNT_OPENING_REASONS                 => ['Speculative', 'Income Earning', 'Hedging', 'Peer-to-peer exchange'];
use constant SR_30_DAYS_EXP                          => 86400 * 30;
my $POI_REASONS = {
    cropped => {
        reason => 'cropped',
    },
    expired => {
        reason => 'expired',
    },
    blurred => {
        reason => 'blurred',
    },
    type_is_not_valid => {
        reason => 'type is not valid',
    },
    selfie_is_not_valid => {
        reason => 'selfie is not valid',
    },
    nimc_no_dob => {
        reason => 'nimc or no dob',
    },
    different_person_name => {
        reason => 'different person/name',
    },
    missing_one_side => {
        reason => 'missing one side',
    },
    suspicious => {
        reason => 'suspicious',
    },
};
my $POA_REASONS = {
    old => {
        reason => 'old',
    },
    cropped => {
        reason => 'cropped',
    },
    blurred => {
        reason => 'blurred/flashlight',
    },
    screenshot => {
        reason => 'screenshot',
    },
    envelope => {
        reason => 'envelope',
    },
    different_name => {
        reason => 'different name',
    },
    different_address => {
        reason => 'different address',
    },
    capitec_stat_no_match => {
        reason => 'capitec stat no match',
    },
    forged => {
        reason => 'forged',
    },
    password_protected => {
        reason => 'password protected',
    },
    unsupported_format => {
        reason => 'unsupported format',
    },
    irrelevant_documnets => {
        reason => 'irrelevant documents',
    },
};

my $POINC_REASONS = {
    blurry => {
        reason => 'blurry',
    },
    not_dated => {
        reason => 'not dated',
    },
    password_protected => {
        reason => 'password protected',
    },
    different_name => {
        reason => 'different name',
    },
    no_employer_details => {
        reason => 'no employer details',
    },
    cropped => {
        reason => 'cropped',
    },
    not_stamped => {
        reason => 'not stamped',
    },
    outdated => {
        reason => 'outdated',
    },
    no_income_details => {
        reason => 'no income details',
    },
    no_occupation_details => {
        reason => 'no occupation details',
    },
    no_letterhead => {
        reason => 'no letterhead',
    },
    income_not_matching_fa => {
        reason => 'income not matching FA',
    }};

my $UNTRUSTED_STATUS = [{
        'linktype'    => 'disabledlogins',
        'comments'    => 'Disabled Accounts',
        'code'        => 'disabled',
        'show_reason' => 'yes',
        'explanation' => "Restricts access to account, client can't login.",
    },
    {
        'linktype'    => 'lockcashierlogins',
        'comments'    => 'Cashier Lock Section',
        'code'        => 'cashier_locked',
        'show_reason' => 'yes',
        'explanation' => 'Restricts access to cashier, blocking both deposits and withdrawals.',
    },
    {
        'linktype'    => 'unwelcomelogins',
        'comments'    => 'Unwelcome Login ID (no deposits or trades)',
        'code'        => 'unwelcome',
        'show_reason' => 'yes',
        'explanation' => 'Client can only login, close any open trades, withdraw any pending balance.',
    },
    {
        'linktype'    => 'nowithdrawalortrading',
        'comments'    => 'Disable Withdrawal and Trading',
        'code'        => 'no_withdrawal_or_trading',
        'show_reason' => 'yes',
        'explanation' => 'Restricts trading and submission of withdrawal requests, deposits allowed.',
    },
    {
        'linktype'    => 'lockwithdrawal',
        'comments'    => 'Withdrawal Locked',
        'code'        => 'withdrawal_locked',
        'show_reason' => 'yes',
        'explanation' => 'Restricts access to submit withdrawal requests. Client can deposit and trade.',
    },
    {
        'linktype'    => 'lockmt5withdrawal',
        'comments'    => 'MT5 Withdrawal Locked',
        'code'        => 'mt5_withdrawal_locked',
        'show_reason' => 'yes'
    },
    {
        'linktype'    => 'duplicateaccount',
        'comments'    => 'Duplicate account',
        'code'        => 'duplicate_account',
        'show_reason' => 'yes',
        'explanation' => 'Blocks complete access to account.',
    },
    {
        'linktype'    => 'professionalrequested',
        'comments'    => 'Professional requested',
        'code'        => 'professional_requested',
        'show_reason' => 'no'
    },
    {
        'linktype'    => 'allowdocumentupload',
        'comments'    => 'Allow client to upload document',
        'code'        => 'allow_document_upload',
        'show_reason' => 'yes'
    },
    {
        'linktype'    => 'internalclient',
        'comments'    => 'Internal Client',
        'code'        => 'internal_client',
        'show_reason' => 'yes'
    },
    {
        'linktype'    => 'notrading',
        'comments'    => 'Disable Trading',
        'code'        => 'no_trading',
        'show_reason' => 'yes'
    },
    {
        'linktype'    => 'sharedpaymentmethod',
        'comments'    => 'Shared Payment Method Found',
        'code'        => 'shared_payment_method',
        'show_reason' => 'yes'
    },
    {
        'linktype'    => 'cryptoautorejectdisabled',
        'comments'    => 'Disable auto reject for crypto payouts',
        'code'        => 'crypto_auto_reject_disabled',
        'show_reason' => 'yes',
        'explanation' => 'Prevents Auto Rejecting client crypto payouts.',
    },
    {
        'linktype'    => 'cryptoautoapprovedisabled',
        'comments'    => 'Disable auto approve for crypto payouts',
        'code'        => 'crypto_auto_approve_disabled',
        'show_reason' => 'yes',
        'explanation' => 'Prevents Auto Approving client crypto payouts.',
    },
    {
        'linktype'    => 'allowduplicatesignup',
        'comments'    => 'Allow to create a new duplicate account for approved SOPs',
        'code'        => 'allow_duplicate_signup',
        'show_reason' => 'yes',
    },

];

foreach my $untrusted_status ($UNTRUSTED_STATUS->@*) {
    my $status_code = $untrusted_status->{code};
    my $children    = BOM::User::Client::Status::STATUS_CODE_HIERARCHY->{$status_code};
    my $is_root     = !defined(BOM::User::Client::Status::REVERSE_STATUS_CODE_HIERARCHY->{$status_code});
    $untrusted_status->{children} = $children;
    $untrusted_status->{is_root}  = $is_root;
}

sub get_document_type_category_mapping {
    my $client = shift;
    my %type_category_mapping;

    foreach my $category (keys $client->documents->categories->%*) {
        my $category_index = $client->documents->categories->{$category}->{priority}    // 100;
        my $category_title = $client->documents->categories->{$category}->{description} // 'Others';

        foreach my $doc_type (keys $client->documents->categories->{$category}->{types}->%*) {
            # payslip is a special case
            next if $doc_type eq 'payslip' and $category ne 'EDD';

            $type_category_mapping{$doc_type} = {
                index => $category_index,
                title => $category_title,
            };
        }
    }
    return %type_category_mapping;
}

sub get_currency_options {
    # we need to prioritise based on the following list, since BO users mostly use them
    my %order = (
        'USD' => 1,
    );
    my $currency_options;
    foreach my $currency (sort { ($order{$a} // 99) <=> ($order{$b} // 99) or $a cmp $b } @{request()->available_currencies}) {
        $currency_options .= '<option value="' . $currency . '">' . $currency . '</option>';
    }
    return $currency_options;
}

=head2 allow_uplift_self_exclusion

Takes a client object, client's current exclude_until date, and new exclude_until date from the form.
Validation is then performed to either allow or restrict the staff to amend the exclude_until date
by returning 1 or 0, respectively. [Section 3.5.4 (5a,5f)
of the United Kingdom Gambling Commission licence conditions and codes of practice
(effective 6 April 2017)].

- Only Compliance team is allowed to uplift exclude_until date before expiry.
- exclude_until period must not be less than SIX months [Section 3.5.4 (5a)
of the United Kingdom Gambling Commission licence conditions and codes of practice
(effective 6 April 2017)].

- After the exclude_until date expires, clients' exclusion still remains in place.

At this point, client must email Customer Support/Compliance team for their exclusion
to be uplifted (exclude_until date removed).

United Kingdom Gambling Commission licence conditions and codes of practice is
applicable to clients under Deriv (Europe) Limited & Deriv (MX) Ltd only. Change is also
applicable to clients under Deriv Investments (Europe) Limited for standardisation.
(http://www.gamblingcommission.gov.uk/PDF/LCCP/Licence-conditions-and-codes-of-practice.pdf)

=cut

sub allow_uplift_self_exclusion {

    my ($client, $exclude_until_date, $form_exclude_until_date) = @_;

    my $after_exclusion_date;

    # Check if client has exclude_until date, and if it has expired
    if ($exclude_until_date) {
        $after_exclusion_date = Date::Utility::today()->is_after($exclude_until_date);
    }

# If exclude_until date is unset, Customer Support and Compliance team can insert the exclude_until date
    return 1 unless $exclude_until_date;

# If exclude_until date has expired, Customer Support and Compliance team can remove the exclude_until date
    return 1 if ($after_exclusion_date and not $form_exclude_until_date);

# If exclude_until date has not expired and client is under Deriv (SVG) LLC,
# then Customer Support and Compliance team can amend or remove the exclude_until date
    return 1 if ($client->landing_company->short eq 'svg');

# If exclude_until date has not expired and client is under Deriv (Europe) Limited, Deriv (MX) Ltd,
# or Deriv Investments (Europe) Limited, then only Compliance team can amend or remove the exclude_until date
    return 1 if (BOM::Backoffice::Auth::has_authorisation(['Compliance']));

    # Default value (no uplifting allowed)
    return 0;
}

=head2 get_professional_status

This sub returns any of the four: Pending, Approved, Rejected, None
In terms of priority, rejected has higher priority than approved, and approved has higher priority than pending.
In the worst case scenario, the client might have both professional_rejected and professional statuses
In cases like this, we assume the client is rejected because there must be a reason why compliance rejected him/her in the first place.

=cut

sub get_professional_status {

    my $client = shift;

    return 'Rejected' if $client->status->professional_rejected;

    return 'Approved' if $client->status->professional;

    return 'Pending' if $client->status->professional_requested;

    return 'None';
}

sub print_client_details {

    my ($client, $client_aml_jurisdiction_risk, $is_readonly) = @_;

    # IDENTITY SECTION
    my @salutation_options = BOM::Backoffice::FormAccounts::GetSalutations();

    # Extract year/month/day if we have them
    # after client->save we have T00:00:00 in date_of_birth, so handle this
    my ($dob_year, $dob_month, $dob_day) = ($client->date_of_birth // '') =~ /^(\d\d\d\d)-(\d\d)-(\d\d)/;

    # make dob_day as numeric values because there is no prefix '0' in dob_daylist
    $dob_day += 0;

    my $dob_day_optionlist = BOM::Backoffice::FormAccounts::DOB_DayList($dob_day);
    my $dob_day_options;
    $dob_day_options .= qq|<option value="$_->{value}">$_->{value}</option>| for @$dob_day_optionlist;
    $dob_day_options = set_selected_item($dob_day, $dob_day_options);
    my @month_names       = (undef, qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec));
    my $dob_month_options = set_selected_item($dob_month, join "",
        map { "<option value=\"" . ($_ ? sprintf("%02s", $_) : "") . "\">" . ($month_names[$_] || "") . "</option>" } (0 .. $#month_names));
    my $dob_year_optionlist = BOM::Backoffice::FormAccounts::DOB_YearList($dob_year);
    my $dob_year_options    = '<option value=""></option>';
    $dob_year_options .= qq|<option value="$_->{value}">$_->{value}</option>| for @$dob_year_optionlist;
    $dob_year_options = set_selected_item($dob_year, $dob_year_options);

    my @countries;
    my $country_codes      = {};
    my $countries_instance = request()->brand->countries_instance->countries;
    foreach my $country_name (sort $countries_instance->all_country_names) {
        push @countries, $country_name;
        $country_codes->{$country_name} = $countries_instance->code_from_country($country_name);
    }

    my $show_uploaded_documents = '';
    my $user                    = $client->user;

    # User should be accessable from client by loginid
    print "<p class='error'>User doesn't exist. This client is unlinked. Please, investigate.<p>"
        and die
        unless $user;

    my $config = request()->brand->countries_instance->countries_list->{$client->residence};
    my $docs   = [];
    unless ($client->is_virtual) {
        my @siblings = grep { LandingCompany::Registry->check_broker_from_loginid($_) } $user->loginids;
        for my $sibling_loginid (@siblings) {
            next if $sibling_loginid =~ /^(MT|DX)[DR]?/;

            my $dbic = BOM::Database::ClientDB->new({
                    client_loginid => $sibling_loginid,
                    operation      => 'backoffice_replica',
                }
                )->db->dbic
                or die "[$0] cannot create connection";

            push $docs->@*, $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref( <<'SQL', {Slice => {}}, $sibling_loginid);
SELECT id,
    file_name,
    document_type,
    issue_date,
    expiration_date,
    comments,
    document_id,
    upload_date,
    age(date_trunc('day', now()), date_trunc('day', upload_date)) AS age,
    status,
    lifetime_valid,
    client_loginid,
    issuing_country,
    address_mismatch
FROM betonmarkets.client_authentication_document
WHERE client_loginid = ? AND status != 'uploading'
SQL
                })->@*;

        }
    }

    $show_uploaded_documents .= show_client_id_docs($docs, $client, show_delete => 1);
    $show_uploaded_documents = "<table class='full-width' style='margin-bottom: 10px;'>$show_uploaded_documents</table>";

    if ($show_uploaded_documents) {
        my $confirm_box = qq{javascript:return get_checked_files()};
        $show_uploaded_documents .=
            qq{<button name="delete_checked_documents" value = "1" onclick="$confirm_box" class="btn btn--primary">Delete Checked Files</button>};
        $show_uploaded_documents .=
            qq{<button name="verify_checked_documents" value = "1" onclick="javascript:return get_to_verify_files()" class="btn btn--primary">Verify Checked Files</button>};
        $show_uploaded_documents .=
            qq{<button name="reject_checked_documents" value = "1" onclick="javascript:return get_to_reject_files()" class="btn btn--secondary">Reject Checked Files</button>};
        if ($client->landing_company->short ne 'maltainvest') {
            $show_uploaded_documents .=
                qq{<button name="address_mismatch_checked_documents" value = "1" onclick="javascript:return get_to_address_mismatch_files()" class="btn btn--secondary">Mark as Address Mismatch</button>};
        }
    }

    # Get matching countries (country abbreviations) from client's phone
    my $client_phone_country = get_client_phone_country($client, $countries_instance);

    my @language_options = @{BOM::Config::Runtime->instance->app_config->cgi->allowed_languages};

    # SECURITY SECTION
    my ($secret_answer, $can_decode_secret_answer);
    try {
        $secret_answer            = BOM::User::Utility::decrypt_secret_answer($client->secret_answer);
        $can_decode_secret_answer = 1;
    } catch ($e) {
        $can_decode_secret_answer = 0;
        $log->warnf("ERROR: Login ID: %s - $e", $client->loginid);
    }

    # MARKETING SECTION
    my $promo_code_access = BOM::Backoffice::Auth::has_authorisation(['Marketing']);

    my $self_exclusion_enabled = $client->self_exclusion ? 'yes' : '';

    my $stateoptionlist = BOM::Platform::Locale::get_state_option($client->residence);
    my $stateoptions    = '<option value=""></option>';
    my $state_name      = '';
    my $state_value     = '';
    for (@$stateoptionlist) {
        if ($_->{value} eq BOM::User::Utility::get_valid_state(trim($client->state), $client->residence)) {
            $state_name  = $_->{text};
            $state_value = $_->{value};
        }
        $stateoptions .= qq|<option value="$_->{value}">$_->{text}</option>|;
    }

    my $rows = $client->user->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT version, brand, stamp::timestamp(0) FROM users.tnc_approval WHERE binary_user_id = ?',
                {Slice => {}},
                $client->user->id
            );
        });
    my $tnc_status;
    $tnc_status->{$_->{brand}} = {
        version => $_->{version},
        stamp   => $_->{stamp}} for @$rows;
    my $tnc_versions = decode_json_utf8(BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_versions);

    my $crs_tin_status          = $client->status->crs_tin_information;
    my $is_valid_tin            = 0;
    my $tin_validation_required = 0;
    my $tin_format_description;
    my $country = request()->brand->countries_instance();
    # Remove leading and trailing space
    my $tax_identification_number = $client->tax_identification_number // '';
    $tax_identification_number =~ s/^\s+|\s+$//g if $tax_identification_number;
    if ($client->tax_residence) {
        # In case of having more than a tax residence, client residence will replaced.
        my $selected_tax_residence = $client->tax_residence =~ /\,/g ? $client->residence : $client->tax_residence;
        my $tin_format             = $country->get_tin_format($selected_tax_residence);
        if ($tin_format) {
            $tin_format_description  = $country->get_tin_format_description($selected_tax_residence) // 'Please check TIN documents';
            $is_valid_tin            = $tax_identification_number eq 'Approved000' || any { $tax_identification_number =~ m/$_/ } @$tin_format;
            $tin_validation_required = 1;
        }
    }
    my @tax_residences =
        $client->tax_residence
        ? split ',', $client->tax_residence
        : ();
    my $tax_residences_countries_name;

    if (@tax_residences) {
        $tax_residences_countries_name = join ',', map { code2country($_) } @tax_residences;
    }

    my $onfido_check = get_onfido_check_latest($client);
    my $onfido_pdf_url;

    if (($onfido_check->{status} // '') eq 'complete' && ($onfido_check->{pdf_status} // '') eq 'completed') {
        my $onfido_s3_client =
            BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth_onfido});
        $onfido_pdf_url = $onfido_s3_client->get_s3_url($onfido_check->{id} . '.pdf');
    }

    my $redis                          = BOM::Config::Redis::redis_replicated_write();
    my $onfido_allow_resubmission_flag = $client->status->reason('allow_poi_resubmission') // '';
    $onfido_allow_resubmission_flag =~ s/\skyc_email$//;    # Match the dropdown reasons to avoid user confusion
    my $onfido_resubmission_counter = $redis->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $client->binary_user_id);

    my $idv_model      = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);
    my $countries_list = request()->brand->countries_instance->countries_list;

    my $idv_records = $idv_model->get_document_list;
    my $messages;
    if ($idv_records) {
        my $rejected_reasons = BOM::Platform::Utility::rejected_onfido_reasons();
        for my $idv_record ($idv_records->@*) {
            $messages                      = [];
            $messages                      = eval { decode_json_utf8 $idv_record->{status_messages} } if $idv_record->{status_messages};
            $idv_record->{status_messages} = [map { $rejected_reasons->{$_} ? localize($rejected_reasons->{$_}) : $_ } grep { $_ } $messages->@*];
            $idv_record->{document_type} =
                $countries_list->{$idv_record->{issuing_country}}->{config}->{idv}->{document_types}->{$idv_record->{document_type}}->{display_name};
            $idv_record->{issuing_country} = $countries_instance->country_from_code($idv_record->{issuing_country});
            $idv_record->{document_expiration_date} ||= "Lifetime Valid";
            $idv_record->{document_expiration_date} = "-" if uc($idv_record->{status}) eq "FAILED";

            my $idv_document_check = $idv_model->get_document_check_detail($idv_record->{document_id});

            next unless $idv_document_check;

            my $idv_report = $idv_document_check->{report};
            $idv_report = eval { decode_json_text $idv_report } if $idv_report;

            my $provider         = $idv_document_check->{provider};
            my $providers_config = BOM::Config::identity_verification()->{providers} // {};
            my $provider_config  = $providers_config->{$provider}                    // {};
            my $is_selfish       = $provider_config->{selfish};

            if (defined $provider && $is_selfish) {
                $idv_record->{tooltip}   = $idv_document_check->{provider} . " provider does not return personal data";
                $idv_record->{full_name} = 'N/A';
                $idv_record->{dob}       = 'N/A';
            } elsif ($idv_report) {
                $idv_record->{full_name} = $idv_report->{full_name};
                $idv_record->{dob}       = $idv_report->{birthdate};
            } else {
                $idv_record->{full_name} = 'ERROR';
                $idv_record->{dob}       = 'ERROR';
            }

            $idv_record->{portal_uri} =
                sprintf(BOM::Config::identity_verification()->{providers}{$idv_document_check->{provider}}{portal_base}, $idv_report->{portal_id})
                if $idv_report && $idv_report->{portal_id};
        }
    }

    my $poa_resubmission_allowed = $client->status->reason('allow_poa_resubmission') // '';
    $poa_resubmission_allowed =~ s/\skyc_email$//;    # Match the dropdown reasons to avoid user confusion
    my $poinc_submission_count = $client->documents->get_poinc_count($docs) // 0;

    #max allowed submissions 3
    my $poinc_submissions_left     = $poinc_submission_count < 3 ? 3 - $poinc_submission_count : 0;
    my $poinc_resubmission_allowed = $client->status->reason('allow_poinc_resubmission') // '';
    #resubmission is allowed submission minus current submissions of type proof of income
    my $poinc_resubmission_count = $poinc_submission_count > 3 ? $poinc_submission_count - 3 : 0;
    my @poi_reasons_tpl =
        map  { {index => $_, reason => $POI_REASONS->{$_}->{reason}} }
        sort { $POI_REASONS->{$a}->{reason} cmp $POI_REASONS->{$b}->{reason} }
        keys $POI_REASONS->%*;
    my @poa_reasons_tpl =
        map  { {index => $_, reason => $POA_REASONS->{$_}->{reason}} }
        sort { $POA_REASONS->{$a}->{reason} cmp $POA_REASONS->{$b}->{reason} }
        keys $POA_REASONS->%*;
    my @poinc_reasons_tpl =
        map  { {index => $_, reason => $POINC_REASONS->{$_}->{reason}} }
        sort { $POINC_REASONS->{$a}->{reason} cmp $POINC_REASONS->{$b}->{reason} }
        keys $POINC_REASONS->%*;

    my $balance =
        $client->default_account
        ? formatnumber('amount', $client->default_account->currency_code, client_balance($client))
        : '--- no currency selected';

    my $redis_oauth  = BOM::Config::Redis::redis_auth_write();
    my $login_locked = $redis_oauth->ttl('oauth::blocked_by_user::' . $client->user->id);
    my $login_locked_until;
    my $too_many_attempts;

    if ($login_locked > 0) {
        $login_locked_until = Date::Utility->new(time + $login_locked);
    } else {
        $too_many_attempts = $client->user->dbic->run(
            fixup => sub {
                $_->selectrow_arrayref('select users.too_many_login_attempts(?::BIGINT, ?::SMALLINT, ?::INTERVAL)',
                    undef, $client->user->id, 5, '5 minutes')->[0];
            });
    }

    my $key = RISK_DISCLAIMER_RESUBMISSION_KEY_PREFIX . $client->user->id;
    my $risk_disclaimer_resubmission_updated_at;
    my $risk_disclaimer_resubmission_updated_by;
    if (my $updated_at = $redis->hget($key . 'meta', 'updated_at')) {
        $risk_disclaimer_resubmission_updated_at = Date::Utility->new($updated_at)->datetime;
        $risk_disclaimer_resubmission_updated_by = $redis->hget($key . 'meta', 'staff_name');
    }
    my @countries_disallow_residence_change = LoadFile("/home/git/regentmarkets/bom-backoffice/config/countries_disallow_residence_change.yml");
    my $sr_status_key;
    my $social_responsibility_risk_status_start_date;
    my $social_responsibility_risk_status_end_date;
    my $social_responsibility_risk_status = 'low';
    my $show_social_responsibility_client = $client->landing_company->social_responsibility_check // '';

    if ($show_social_responsibility_client) {
        if ($show_social_responsibility_client eq 'required') {
            $sr_status_key = $client->loginid . ':sr_risk_status';
            my $redis_events = BOM::Config::Redis::redis_events();
            $social_responsibility_risk_status = $redis_events->get($sr_status_key) // 'low';
            if ($social_responsibility_risk_status eq 'high') {
                my $social_responsibility_risk_status_ttl = $redis_events->ttl($sr_status_key);
                if ($social_responsibility_risk_status_ttl > 0) {
                    $social_responsibility_risk_status_end_date =
                        Date::Utility->today()->plus_time_interval($social_responsibility_risk_status_ttl)->date_ddmmmyyyy;
                    $social_responsibility_risk_status_start_date =
                        Date::Utility->new($social_responsibility_risk_status_end_date)->minus_time_interval(SR_30_DAYS_EXP)->date_ddmmmyyyy;
                }
            }
        } elsif ($show_social_responsibility_client eq 'manual') {
            $social_responsibility_risk_status = BOM::User::SocialResponsibility->get_sr_risk_status($user->id) // 'low';
        }
    }
    my $doughflow_mapper = BOM::Database::DataMapper::Payment::DoughFlow->new({
        client_loginid => $client->loginid,
    });

    my $expected_address     = $client->documents->poa_address_mismatch();
    my $poa_address_mismatch = $client->status->poa_address_mismatch();
    my $idv_submissions_left = $idv_model->submissions_left();

    $idv_submissions_left = $idv_model->has_expired_document_chance() ? 1 : 0 if $idv_submissions_left <= 0 && $client->get_idv_status() eq 'expired';

    my $app_config            = BOM::Config::Runtime->instance->app_config;
    my $payment_method_config = $app_config->payments->payment_methods_with_poo;

    my $doughflow_methods = $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM payment.doughflow_deposit_methods_without_poo(?, ?)',
                undef, $client->binary_user_id, $payment_method_config);
        });
    my $proof_of_ownership_list = $client->proof_of_ownership->list();

    my $poo_access = BOM::Backoffice::Auth::has_authorisation(['AntiFraud', 'CS']);
    my ($latest_poi_by) = $client->latest_poi_by({only_verified => 1});

    # checking if the client tax_residence(country) and landing company are part NPJ (TIN not required) so TAX IDENTIFICATION NUMBER will show NPJ country

    my $npj_countries_list = $compliance_config->get_npj_countries_list;

    my $is_npj = 0;

    if (any { $client->tax_residence eq $_ } $npj_countries_list->{$client->landing_company->short}->@*) {
        $is_npj = 1;
    }

    my $template_param = {
        is_readonly          => $is_readonly,
        balance              => $balance,
        client               => $client,
        client_phone_country => $client_phone_country,
        countries            => \@countries,
        country_codes        => $country_codes,
        crs_tin_information  => $crs_tin_status
        ? $crs_tin_status->{last_modified_date}
        : '',
        dob_day_options                              => $dob_day_options,
        dob_month_options                            => $dob_month_options,
        dob_year_options                             => $dob_year_options,
        financial_risk_status                        => $client->status->financial_risk_approval,
        has_social_signup                            => $user->{has_social_signup},
        lang                                         => request()->language,
        language_options                             => \@language_options,
        mifir_config                                 => $Finance::MIFIR::CONCAT::config,
        promo_code_access                            => $promo_code_access,
        currency_type                                => (LandingCompany::Registry::get_currency_type($client->currency) // ''),
        salutation_options                           => \@salutation_options,
        secret_answer                                => $secret_answer,
        can_decode_secret_answer                     => $can_decode_secret_answer,
        self_exclusion_enabled                       => $self_exclusion_enabled,
        show_allow_professional_client               => $client->landing_company->support_professional_client,
        show_social_responsibility_client            => $show_social_responsibility_client,
        social_responsibility_risk_status            => $social_responsibility_risk_status,
        social_responsibility_risk_status_start_date => $social_responsibility_risk_status_start_date,
        social_responsibility_risk_status_end_date   => $social_responsibility_risk_status_end_date,
        professional_status                          => get_professional_status($client),
        eligible_counterparty                        => $client->status->eligible_counterparty ? 1 : 0,
        show_funds_message                           => ($config->{ukgc_funds_protection} and not $client->is_virtual),
        show_risk_approval                           => ($client->landing_company->short eq 'maltainvest'),
        client_aml_jurisdiction_risk                 => $client_aml_jurisdiction_risk,
        show_tnc_status                              => !$client->is_virtual,
        show_non_pep_declaration_time                => !$client->is_virtual,
        non_pep_declaration_time                     => $client->non_pep_declaration_time,
        show_fatca_declaration_time                  => !$client->is_virtual,
        fatca_declaration_time                       => $client->fatca_declaration_time,
        fatca_declaration                            => $client->fatca_declaration,
        show_uploaded_documents                      => $show_uploaded_documents,
        state_options                                => set_selected_item($state_value, $stateoptions),
        client_state                                 => $state_name,
        tnc_status                                   => $tnc_status,
        tnc_versions                                 => $tnc_versions,
        is_valid_tin                                 => $is_valid_tin,
        tin_format_info                              => $tin_format_description,
        tin_validation_required                      => $tin_validation_required,
        ukgc_funds_status                            => $client->status->ukgc_funds_protection,
        tax_residence                                => \@tax_residences,
        tax_residences_countries_name                => $tax_residences_countries_name,
        tax_identification_number                    => $tax_identification_number,
        cashier_allow_payment_agent_status           => $client->status->pa_withdrawal_explicitly_allowed,
        address_verification_status                  => $client->status->address_verified,
        smarty_street_status                         => $client->status->smarty_streets_validated,
        onfido_check_result                          => $onfido_check->{result},
        onfido_check_url                             => $onfido_check->{results_uri} // '',
        onfido_resubmission                          => $onfido_allow_resubmission_flag,
        poa_resubmission_allowed                     => $poa_resubmission_allowed,
        poinc_resubmission_allowed                   => $poinc_resubmission_allowed,
        poinc_submissions_left                       => $poinc_submissions_left,
        poinc_resubmission_count                     => $poinc_resubmission_count,
        text_validation_info                         => client_text_field_validation_info($client, secret_answer => $secret_answer),
        aml_risk_levels                              => [get_aml_risk_classicications()],
        is_staff_compliance                          => BOM::Backoffice::Auth::has_authorisation(['Compliance']),
        onfido_resubmission_counter                  => $onfido_resubmission_counter // 0,
        account_opening_reasons                      => ACCOUNT_OPENING_REASONS,
        poi_reasons                                  => \@poi_reasons_tpl,
        poa_reasons                                  => \@poa_reasons_tpl,
        poinc_reasons                                => \@poinc_reasons_tpl,
        onfido_submissions_left                      => BOM::User::Onfido::submissions_left($client),
        onfido_submissions_reset                     => BOM::User::Onfido::submissions_reset_at($client),
        onfido_reported_properties                   => BOM::User::Onfido::reported_properties($client),
        poi_name_mismatch                            => $client->status->poi_name_mismatch,
        idv_records                                  => $idv_records,
        expired_poi_docs                             => $client->documents->expired(1),
        login_locked_until                           => $login_locked_until ? $login_locked_until->datetime_ddmmmyy_hhmmss_TZ : undef,
        too_many_attempts                            => $too_many_attempts,
        screening_reasons                            => [BOM::User::LexisNexis::SCREENING_REASON],
        is_compliance                                => BOM::Backoffice::Auth::has_authorisation(['Compliance']),
        risk_disclaimer_updated_at                   => $risk_disclaimer_resubmission_updated_at,
        risk_disclaimer_updated_by                   => $risk_disclaimer_resubmission_updated_by,
        payment_methods                              => $doughflow_mapper->get_poo_required_methods(),
        proof_of_ownership_list                      => $proof_of_ownership_list,
        disallow_residence_change                    => @countries_disallow_residence_change,
        onfido_pending_request                       => BOM::User::Onfido::pending_request($client->binary_user_id),
        onfido_supported_country => BOM::Config::Onfido::is_country_supported(uc($client->place_of_birth || $client->residence // '')),
        poa_address_mismatch     => $poa_address_mismatch,
        expected_address         => $expected_address,
        broker_code              => $client->broker_code,
        idv_pending_lock         => $idv_model->get_pending_lock() // -1,
        idv_submissions_left     => $idv_submissions_left,
        doughflow_methods        => $doughflow_methods,
        poo_access               => $poo_access,
        latest_poi_by            => $latest_poi_by,
        idv_status               => $client->get_idv_status,
        onfido_status            => $client->get_onfido_status,
        manual_status            => $client->get_manual_poi_status,
        is_npj                   => $is_npj,
        onfido_pdf_url           => $onfido_pdf_url,
        onfido_suspended         => BOM::Config::Runtime->instance->app_config->system->suspend->onfido,
        is_idv_validated         => $client->is_idv_validated,
    };

    return BOM::Backoffice::Request::template()->process('backoffice/client_edit.html.tt', $template_param, undef, {binmode => ':utf8'})
        || die BOM::Backoffice::Request::template()->error(), "\n";
}

## build_client_statement_form #######################################
# Purpose : Build the form that lets people view a Client's statement.
#           Used in several places in b/o, hence the subroutine.
######################################################################
sub build_client_statement_form {
    my $broker = shift @_;
    return
        '<hr><p class="error grd-margin-bottom"><b>Show All Transaction</b>, may fail for clients with huge number of transaction, so use this feature only when required.</p><FORM ACTION="'
        . request()->url_for('backoffice/f_manager_history.cgi')
        . '" METHOD="GET" onsubmit="return validate_month(\'statement\')">'
        . '<div class="row"><label>Check Statement of Login ID:</label><input id="statement_loginID" name="loginID" type="text" size="15" data-lpignore="true" value="'
        . $broker . '"/> '
        . '<label>From:</label><input name="startdate" type="text" size="10" value="'
        . Date::Utility->today()->_minus_months(1)->date
        . '" required pattern="\d{4}-\d{2}-\d{2}" class="datepick" id="statement_startdate" data-lpignore="true" /> '
        . '<label>To:</label><input name="enddate" type="text" size="10" value="'
        . Date::Utility->today()->date
        . '" required pattern="\d{4}-\d{2}-\d{2}" class="datepick" id="statement_enddate" data-lpignore="true" /> '
        . '<input type="hidden" name="broker" value="'
        . $broker . '">'
        . '<SELECT name="currency_dropdown"><option value="default">client\'s default currency</option>'
        . get_currency_options()
        . '</SELECT>'
        . '</div><input type="hidden" name="l" value="EN">'
        . '<input type="checkbox" value="deposit_withdrawal_only" name="trx_filter"  id="deposit_withdrawal_only"><label for="deposit_withdrawal_only">Deposits and Withdrawals only</label> '
        . '<input type="submit" class="btn btn--primary" value="Client statement">'
        . '</FORM>'
        # ------- CRYPTO -------
        . '<hr><FORM ACTION="'
        . request()->url_for('backoffice/f_manager_crypto_history.cgi')
        . '" METHOD="POST" onsubmit="return validate_month(\'statement\')">'
        . '<label>Check Crypto Statement of Login ID:</label><input id="statement_loginID" name="loginID" type="text" size="15" data-lpignore="true" value="'
        . $broker . '"/> '
        . '<input type="hidden" name="broker" value="'
        . $broker . '">'
        . '<input type="hidden" name="l" value="EN">'
        . '<input class="btn btn--primary" type="submit" value="Client Crypto statement">'
        . '</FORM>';
}

sub link_for_remove_status_from_all_siblings {
    my ($loginid, $status_code, $messages) = @_;
    my $client                          = BOM::User::Client->new({'loginid' => $loginid});
    my $sibling_loginids_without_status = $client->get_sibling_loginids_without_status($status_code);
    my $siblings                        = $client->siblings();
    $messages //= {};

    return '<span>' . (defined($messages->{disabled}) ? $messages->{disabled} : 'status has not been set to its siblings') . '</span>'
        if scalar @{$sibling_loginids_without_status} == scalar @{$siblings};

    return '<a class="link" href="'
        . request()->url_for(
        'backoffice/sync_client_status.cgi',
        {
            action      => 'remove',
            loginid     => $loginid,
            status_code => $status_code
        })
        . '">'
        . (defined($messages->{enabled}) ? $messages->{enabled} : 'remove from all siblings <i>(including ' . $loginid . ')</i>') . '</a>';
}

=head2 siblings_status_summary

Gets a brief description of the given status syncing among the client siblings.

Takes the following arguments:

=over 4

=item * C<client> the client instance

=item * C<code> the given status code

=back

Returns a string.

=cut

sub siblings_status_summary {
    my ($client, $code) = @_;

    return "<span>doesn't have siblings across the same landing company</span>" unless $client->has_siblings();

    my $sibling_loginids_without_status = $client->get_sibling_loginids_without_status($code);

    return '<span>status synced among siblings</span>' if scalar $sibling_loginids_without_status->@* == 0;

    my $siblings = join ', ', $sibling_loginids_without_status->@*;

    return "<span>some siblings are not synced: $siblings</span>";
}

sub link_for_copy_status_status_to_siblings {
    my ($loginid, $status_code, $messages, $cl) = @_;
    my $client                          = BOM::User::Client->new({'loginid' => $loginid});
    my $sibling_loginids_without_status = $client->get_sibling_loginids_without_status($status_code);
    $messages //= {};

    return '<span>' . (defined($messages->{disabled}) ? $messages->{disabled} : 'status synced among siblings') . '</span>'
        if scalar @{$sibling_loginids_without_status} == 0;

    return '<a class="link" href="'
        . request()->url_for(
        'backoffice/sync_client_status.cgi',
        {
            action      => 'copy',
            loginid     => $loginid,
            status_code => $status_code
        })
        . '">'
        . (defined($messages->{enabled}) ? $messages->{enabled} : 'copy to siblings') . '</a>';
}

## build_client_warning_message #######################################
# Purpose : To obtain the client warning status and return its status
#           in html form
######################################################################
sub build_client_warning_message {
    my ($login_id, $is_readonly) = @_;
    my $client = BOM::User::Client->new({'loginid' => $login_id})
        || return "<p>The Client's details can not be found [$login_id]</p>";
    my $broker = $client->broker;

    my $p2p_advertiser = $client->_p2p_advertiser_cached;
    my $p2p_approved   = $p2p_advertiser ? $p2p_advertiser->{is_approved} : '';

    my @output;

    my $edit_client_with_status = sub {
        my $action_type = shift;
        return '<a class="link" href="'
            . request()->url_for(
            "backoffice/f_clientloginid.cgi",
            {
                untrusted_action      => 'insert_data',
                editlink              => 1,
                login_id              => $login_id,
                broker                => $broker,
                untrusted_action_type => $action_type
            }) . '">edit</a>';
    };

    my $remove_client_from = sub {
        my $action_type = shift;
        return '<a class="link" href="'
            . request()->url_for(
            "backoffice/untrusted_client_edit.cgi",
            {
                untrusted_action      => 'remove_status',
                login_id              => $login_id,
                broker                => $broker,
                untrusted_action_type => $action_type
            }) . '">remove</a>';
    };

    ###############################################
    ## UNTRUSTED SECTION
    ###############################################
    my %client_status =
        map { $_ => $client->status->$_ } @{$client->status->all};
    foreach my $type (@{get_untrusted_types()}) {
        my $code             = $type->{code};
        my $siblings_summary = siblings_status_summary($client, $code);

        if (my $disabled = $client->status->$code) {
            delete $client_status{$type->{code}};
            push(
                @output,
                {
                    clerk              => $disabled->{staff_name},
                    reason             => $disabled->{reason},
                    warning            => 'var(--color-red)',
                    code               => $code,
                    section            => $type->{comments},
                    editlink           => $edit_client_with_status->($type->{linktype}),
                    siblings_summary   => $siblings_summary,
                    last_modified_date => $disabled->{last_modified_date} // ''
                });
        }
    }

    # build the table
    my $output = '';

    if (@output || scalar keys %client_status) {
        $output =
              '<form method="POST" class="row">'
            . '<div class="row"><table class="collapsed hover alternate"><thead><tr>'
            . '<th>&nbsp;</th>'
            . '<th>Status</th>'
            . '<th>Reason/Info</th>'
            . '<th>Staff</th>'
            . '<th>Sync</th>'
            . '<th>Last modified date</th>'
            . '</tr></thead><tbody>';
        foreach my $output_rows (@output) {
            $output .= '<tr>'
                . '<td align="center">'
                . '<input type="checkbox" name="status_checked" value="'
                . $output_rows->{'code'} . '" />' . '</td>'
                . '<td align="left">'
                . '<strong style="font-size: 1.3rem !important; color:'
                . $output_rows->{'warning'} . '">'
                . (uc $output_rows->{'section'})
                . '</strong></td>'
                . '<td><b>'
                . get_detailed_status_reason($output_rows->{'reason'})
                . '</b></td>'
                . '<td><b>'
                . $output_rows->{'clerk'}
                . '</b></td>'
                . '<td><b>'
                . $output_rows->{'siblings_summary'}
                . '</b></td>'
                . '<td><b>'
                . $output_rows->{'last_modified_date'}
                . '</b></td></tr>';
        }

        # Show all remaining status info
        for my $status (sort keys %client_status) {
            my $info = $client_status{$status};
            $output .= '<tr>'
                . '<td>&nbsp;</td>'
                . '<td align="left">'
                . $status . '</td>'
                . '<td><b>'
                . ($info->{reason} // '')
                . '</b></td>'
                . '<td><b>'
                . ($info->{staff_name} // '')
                . '</b></td>'
                . '<td colspan="4">&nbsp;</td>' . '</tr>';
        }
        $output .= '</tbody></table></div>';
        $output .= '<div class="row btn-group">';
        my $button_type = $is_readonly ? 'class="btn btn--disabled"' : 'class="btn btn--primary"';
        $output .= '<button ' . $button_type . ' name="status_op" value="remove">Remove selected</button> ';
        $output .=
              '<button '
            . $button_type
            . ' name="status_op" value="remove_siblings">Remove selected including accounts within same landing company</button> ';
        $output .= '<button ' . $button_type . ' name="status_op" value="sync">Copy selected to accounts within same landing company</button>';
        $output .= '<div class="row btn-group" style=\'margin-top: 8px;\'>';
        $output .=
              '<button '
            . $button_type
            . ' name="status_op" value="remove_accounts">Remove selected including accounts in all landing companies (including virtual)</button> ';
        $output .=
              '<button '
            . $button_type
            . ' name="status_op" value="sync_accounts">Copy selected to accounts in all landing companies (including virtual)</button>';
        $output .= '</div>';
        $output .= '<input type="hidden" name="p2p_approved" value="' . $p2p_approved . '">';
        $output .= '</div>';
        $output .= '</form>';
    }

    return $output;
}

## get_untrusted_client_reason ###############################
#
# Purpose : all the available untrusted client reason
#
##############################################################
sub get_untrusted_client_reason {
    return {
        kyc => {
            name    => 'KYC',
            reasons => [
                'Incomplete/false details',
                'Pending proof of age',
                'Pending EDD docs/info for withdrawal request',
                'Pending EDD docs/info',
                'Pending docs - qualifying threshold reached',
                'Corporate account - pending info/docs/declarations',
                'Pending disclaimer for Spanish clients with MT5',
                'Allow document upload',
                'Docs requested',
            ],
        },
        sr => {
            name    => 'SR',
            reasons => ['Problem Trader', 'Negative target market',],
        },
        investigation => {
            name    => 'Investigations',
            reasons => [
                'Hacked account',
                'Fraudulent account',
                'Forged document',
                'Pending investigation',
                'Chargeback',
                'Fraud Notification',
                'Retrieval Request'
            ],
        },
        payment => {
            name    => 'Payments / transactions',
            reasons => [
                'PA withdrawal activation',
                'Payment related',
                'Sharing payment method',
                'Duplicate account - currency change',
                'Duplicate account',
                'Pending payout request',
            ],
        },
        affiliate => {
            name    => 'PAs / affiliates',
            reasons => [
                'PA application - pending info/documents',
                'PA application - pending COC',
                'Affiliate account - pending COC/ROD',
                'Affiliate account - pending info/documents',
                'PA dispute',
                'App developer - pending info/documents',
                'Affiliate - reputation check',
            ],
        },
        account => {
            name    => 'Account',
            reasons => ['Email change request', 'Account closure', 'Incorrect broker code', 'MT5 advanced account', 'Multiple IPs',],
        },
        other => {
            name    => 'Others',
            reasons => ['Internal client used for testing & learning - internal test account', 'Others',],
        },
    };
}

sub date_html {
    my ($name, $value, $label, $id, $required, $extra) = @_;

    $required = $required ? 'required' : '';
    my $required_mark = $required ? '*' : ' ';
    my $date          = $value || '';
    if ($date) {
        eval {
            my $formatted = Date::Utility->new($date)->date_yyyymmdd;
            $date = $formatted;
        } or $label = "<span class='error'>$label (invalid)</span>";
    }

    return
        qq{ $label$required_mark<input type="text" $required maxlength="15" name="${name}_${id}" value="$date" pattern="\\d{4}-\\d{2}-\\d{2}" class="datepick" data-lpignore="true" $extra>};
}

## show_client_id_docs #######################################
# Purpose : generate the html to display client's documents.
# Relocated to here from Client module.
##############################################################
sub show_client_id_docs {
    my ($docs, $client, %args) = @_;
    my $show_delete = $args{show_delete};
    my $extra       = $args{no_edit} ? 'disabled' : '';
    my $links       = '';

    my %doc_types_categories = get_document_type_category_mapping($client);
    my @poi_doctypes         = $client->documents->poi_types->@*;
    my @poa_doctypes         = $client->documents->poa_types->@*;
    my @dateless_doctypes    = $client->documents->dateless_types->@*;
    my @expirable_doctypes   = $client->documents->expirable_types->@*;
    my @numberless_doctypes  = $client->documents->numberless->@*;

    foreach my $doc (@$docs) {
        # add category index to each doc
        $doc->{category_idx} =
            ($doc->{document_type} && $doc_types_categories{$doc->{document_type}})
            ? $doc_types_categories{$doc->{document_type}}{index}
            : $doc_types_categories{others}{index};
    }

    # sort by category then by issue date and expiration date descending
    @$docs = sort {
               $a->{category_idx} <=> $b->{category_idx}
            || ($b->{issue_date}      ? $b->{issue_date}      : '') cmp($a->{issue_date}      ? $a->{issue_date}      : '')
            || ($b->{expiration_date} ? $b->{expiration_date} : '') cmp($a->{expiration_date} ? $a->{expiration_date} : '')
    } @$docs;

    my $last_category_idx = -1;
    foreach my $doc (@$docs) {
        my (
            $id,       $file_name,      $document_type, $issue_date,      $expiration_date,
            $comments, $document_id,    $upload_date,   $age,             $category_idx,
            $status,   $lifetime_valid, $loginid,       $issuing_country, $address_mismatch
            )
            = $doc->@{
            qw/id file_name document_type issue_date expiration_date comments document_id upload_date age category_idx status lifetime_valid client_loginid issuing_country address_mismatch/
            };

        if ($category_idx != $last_category_idx) {
            my $category_title = (
                ($doc_types_categories{$document_type} && $doc_types_categories{$document_type}{title})
                ? $doc_types_categories{$document_type}{title}
                : $doc_types_categories{others}{title}) . ":";
            $links .= qq(<tr><th colspan='9' class='left'>$category_title</th></tr>);
        }
        $last_category_idx = $category_idx;

        if (not $file_name) {
            $links .= qq{<tr><td>Missing filename for a file with ID: $id</td></tr>};
            next;
        }

        my $age_display;
        if ($age) {
            $age =~ s/[\d:]{8}//g;
            $age_display = $age ? "$age old" : "today";
            $age_display = qq{<td style="width:60px;overflow:hidden;" title="$upload_date">$age_display</td>};
        } else {
            $age_display = '<td style="width:60px;overflow:hidden;"></td>';
        }

        my $poi_doc       = any { $_ eq $document_type } @poi_doctypes;
        my $poa_doc       = any { $_ eq $document_type } @poa_doctypes;
        my $expirable_doc = any { $_ eq $document_type } @expirable_doctypes;
        my $dateless_doc  = any { $_ eq $document_type } @dateless_doctypes;
        my $numberless    = any { $_ eq $document_type } @numberless_doctypes;

        my $expiration = 'not_applicable';
        $expiration = 'expiration_date' if $expiration_date;
        $expiration = 'lifetime_valid'  if $lifetime_valid;

        my $issuance = 'not_applicable';
        $issuance = 'issuance_date'  if $issue_date;
        $issuance = 'lifetime_valid' if $lifetime_valid;

        my @issue_date_chunks = split(' ', $issue_date // '');
        my $input             = '';

        BOM::Backoffice::Request::template()->process(
            'backoffice/client_edit_document_dates.html.tt',
            {
                poi_doc         => $poi_doc,
                expirable_doc   => $expirable_doc,
                dateless_doc    => $dateless_doc,
                lifetime_valid  => $lifetime_valid,
                issuance        => $issuance,
                expiration_date => $expiration_date,
                expiration      => $expiration,
                id              => $id,
                issue_date      => $issue_date_chunks[0] // '',
            },
            \$input
        );

        my $required_mark = $poi_doc ? '*' : ' ';

        if ($numberless) {
            $input .= '<td></td>';
        } else {
            $input .=
                qq{<td align="left"><label>Document ID:</label>$required_mark<br/><input type="text" maxlength="30" name="document_id_$id" value="$document_id" data-lpignore="true" $extra> </td>};
        }

        $input .=
            qq{<td><label>Comments:</label><br/><input type="text" maxlength="255" name="comments_$id" value="$comments" data-lpignore="true" $extra> </td>};

        $status = 'address_mismatch' if $address_mismatch;

        my %status_string = (
            verified         => 'Verified',
            rejected         => 'Rejected',
            uploaded         => 'Needs Review',
            address_mismatch => 'Address Mismatch',
        );

        $input .= "<td>$status_string{$status}</td>" if $status_string{$status};

        my $s3_client =
            BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
        my $url = $s3_client->get_s3_url($file_name);

        my $expired_poi_hint =
            ($expirable_doc && $poi_doc && $expiration_date && Date::Utility::today()->date gt $expiration_date)
            ? qq{ class="error" title="expired" }
            : "";

        my $country = 'Not Available';

        $country = request()->brand->countries_instance->countries_list->{$issuing_country}->{name} // 'Unknown Country' if $issuing_country;

        $links .=
            qq{<tr><td width="20" dir="rtl" $expired_poi_hint > &#9658; </td><td style="width:400px;overflow:hidden;"><a class="link" href="$url" data-document-id="$id" target="_blank">$file_name</a><br/><span><b>Issuing country:</b> $country</span></td>$age_display$input};

        my $is_poa = $poa_doc ? 1 : 0;
        $links .=
            qq{<td><input data-is-poa="$is_poa" type="checkbox" class='files_checkbox' name="document_list" value="$id-$loginid-$file_name"><td>};

        $links .= "</tr>";
    }

    return $links;
}

sub get_onfido_check_latest {
    my ($client) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic
        or die "[$0] cannot create connection";

    my $latest_check_result = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare('select * from users.get_onfido_checks(?::BIGINT, ?::TEXT, ?::BIGINT)');
            $sth->execute($client->binary_user_id, undef, 1);
            return $sth->fetchrow_hashref;
        });

    return $latest_check_result // {};
}

sub client_statement_summary {
    my ($args) = @_;
    my ($client, $from, $to, $currency) = @{$args}{'client', 'from', 'to', 'currency'};

    $currency //= $client->currency;

    my $client_db = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
        operation      => 'backoffice_replica',
    });

    my $dm_params = {
        client_loginid => $client->loginid,
        currency_code  => $currency,
        db             => $client_db->db,
    };

    my $payment_mapper = BOM::Database::DataMapper::Payment->new($dm_params);
    my $account_mapper = BOM::Database::DataMapper::Account->new($dm_params);

    my $raw_summary = $payment_mapper->get_summary({
        from_date => $from,
        to_date   => $to
    });

    my $summary = {};
    foreach my $item (@$raw_summary) {
        my ($amount, $type, $system) = @{$item}{'amount', 'action_type', 'payment_system'};

        if ($type) {
            if ($system) {

                $summary->{$type}->{systems}->{$system} = $amount;
                next;
            }

            $summary->{$type}->{total} = $amount;
            next;
        }

        $summary->{total} = $amount;
    }

    # {income} is sum of profits and losses
    $summary->{income} = $account_mapper->get_total_trades_income({
        from => $client->date_joined,
    });

    return $summary;
}

=head2 client_inernal_transfer_summary

Returns a summary of client's internal transfers per action types (deposit, withdrawal)
and payment types (internal tansfer, free gift, doughflow, ...).

=cut

sub client_inernal_transfer_summary {
    my %args = @_;
    my ($client, $from, $to) = @args{qw/client from to/};

    my $summary = {};

    return $summary unless $client->account;

    my $raw_summary = $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM payment.get_internal_transfer_summary(?,?,?)', {Slice => {}}, $client->account->id, $from, $to);
        },
    );

    foreach my $item (@$raw_summary) {
        my ($amount, $action, $type) = @{$item}{qw/amount action_type payment_type/};

        $summary->{$action}->{type}->{$type} = $amount;
        $summary->{$action}->{total} += $amount;
        $summary->{total} += $amount;
    }

    return $summary;
}

=head2 client_payment_agent_transfer_summary

Returns a summary of client's payment agent transfers.

It takes the following named arguments:

=over 4

=item * C<client>: client we are report on.

=item * C<from>: start date.

=item * C<to>: end date.

=back

=cut

sub client_payment_agent_transfer_summary {
    my %args = @_;
    my ($client, $from, $to) = @args{qw/client from to/};

    my $summary = {};

    return $summary unless $client->account;

    my $raw_summary = $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM payment.get_payment_agent_transfer_summary(?,?,?)', {Slice => {}}, $client->account->id, $from,
                $to);
        },
    );

    foreach my $item (@$raw_summary) {
        my ($amount, $count, $action, $loginid, $account_id, $is_payment_agent, $api_call) =
            @{$item}{qw/amount count action_type fellow_loginid fellow_accountid fellow_is_payment_agent api_call/};

        $summary->{$loginid}->{by_call}->{$api_call}->{$action}->{amount} = $amount;
        $summary->{$loginid}->{by_call}->{$api_call}->{$action}->{count}  = $count;
        $summary->{$loginid}->{by_call}->{$api_call}->{total}->{count} += $count;

        $summary->{$loginid}->{loginid}          = $loginid;
        $summary->{$loginid}->{accountid}        = $account_id;
        $summary->{$loginid}->{is_payment_agent} = $is_payment_agent;

        $summary->{$loginid}->{total}->{amount} += abs($amount);
        $summary->{$loginid}->{total}->{count}  += $count;
        $summary->{$action}->{total}->{amount}  += $amount;
        $summary->{$action}->{total}->{count}   += $count;
    }

    # create a list of fellow clients, sorted by their number of transactions.
    my @fellows = map { $_ =~ qr/deposit|withdraw/ ? () : $summary->{$_} } keys %$summary;
    $summary->{sorted} = [sort { $b->{total}->{count} <=> $a->{total}->{count} } @fellows];

    return $summary;
}

=head2 client_payment_agent_transfer_details

Returns the details of client's payment agent transfers with a specific fellow client.

It takes the following named arguments:

=over 4

=item * C<client>: client we are report on.

=item * C<fellow_account>: client we are report on.

=item * C<from>: start date.

=item * C<to>: end date.

=item * C<api_call>: (optional) the target api call: valid amounts:
C<paymentagent_deposit>, C<paymentagent_dwithdraw> and C<total> (both api calls)

=back

=cut

sub client_payment_agent_transfer_details {
    my %args = @_;
    my ($client, $fellow_account, $from, $to, $api_call) = @args{qw/client fellow_account from to api_call/};

    return {} unless $client->account;

    my $result = $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM payment.get_payment_agent_transfer_details(?,?,?,?)',
                {Slice => {}},
                $client->account->id, $fellow_account, $from, $to
            );
        },
    );

    return $result if not $api_call or $api_call eq 'total';

    return [grep { $_->{api_call} eq $api_call } @$result];
}

=head2 internal_transfer_statement_urls

Returns urls that allow displaying a detailed stement report for internal transfer types in L<f_statement_internal_transfer.cgi> page.
Note: it supports onnly B<payment_agent_transfer> transfer type at the moment.

=cut

sub internal_transfer_statement_urls {
    my ($client, $from_date, $to_date) = @_;

    return {
        payment_agent_transfer => request()->url_for(
            'backoffice/f_statement_internal_transfer.cgi',
            {
                loginID       => $client->loginid,
                from_date     => $from_date->date_yyyymmdd(),
                to_date       => $to_date->date_yyyymmdd(),
                transfer_type => 'payment_agent_transfer'
            }
        ),
    };
}

sub get_transactions_details {
    my ($args) = @_;
    my ($client, $from, $to, $currency, $dw_only, $limit, $transaction_id) =
        @{$args}{'client', 'from', 'to', 'currency', 'dw_only', 'limit', 'transaction_id'};

    $currency //= $client->currency;
    $dw_only  //= 0;
    $limit    //= 20;

    my $client_db = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
        operation      => 'backoffice_replica',
    });

    my $tranxs_dm = BOM::Database::DataMapper::Transaction->new({
        client_loginid => $client->loginid,
        currency_code  => $currency,
        db             => $client_db->db,
    });

    my $transactions;
    if ($dw_only) {
        $transactions = $tranxs_dm->get_payments({
            after  => $from,
            before => $to,
            limit  => $limit
        });

        foreach (@$transactions) {
            $_->{absolute_amount} = abs($_->{amount});
        }

    } else {
        $transactions = $tranxs_dm->get_transactions({
            after          => $from,
            before         => $to,
            limit          => $limit,
            transaction_id => $transaction_id,
        });

        foreach my $transaction (@{$transactions}) {
            $transaction->{absolute_amount} = abs($transaction->{amount});
            $transaction->{limit_order}     = encode_json_utf8(BOM::Transaction::Utility::extract_limit_orders($transaction))
                if defined $transaction->{bet_class}
                and $transaction->{bet_class} eq 'multiplier';
        }
    }

    return $transactions;
}

sub client_balance {
    my ($client, $currency) = @_;

    $currency //= $client->currency;

    my $client_db = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
        operation      => 'backoffice_replica',
    });

    my $account_dm = BOM::Database::DataMapper::Account->new({
        client_loginid => $client->loginid,
        currency_code  => $currency,
        db             => $client_db->db,
    });

    return $account_dm->get_balance();
}

=head2 get_untrusted_types

Returns untrusted status code info as an array ref.

=cut

sub get_untrusted_types {
    return $UNTRUSTED_STATUS;
}

=head2 get_untrusted_types_hashref

Returns untrusted status code info as a hashref keyed by status codes.

=cut

sub get_untrusted_types_hashref {
    return {map { $_->{code} => $_ } @$UNTRUSTED_STATUS};
}

sub get_untrusted_type_by_code {
    my $code = shift;

    my ($untrusted_type) = grep { $_->{code} eq $code } @$UNTRUSTED_STATUS;

    return $untrusted_type;
}

sub get_untrusted_type_by_linktype {
    my $linktype = shift;

    my ($untrusted_type) = grep { $_->{linktype} eq $linktype } @$UNTRUSTED_STATUS;

    return $untrusted_type;
}

sub get_open_contracts {
    my $client = shift;
    return BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
            operation      => 'backoffice_replica',
        })->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client->loginid, $client->currency, 'false']);
}

sub sync_to_doughflow {
    my ($client, $clerk) = @_;

    return "Invalid account." unless $client;

    return "No currency selected for account." unless $client->default_account;

    return "Sync to doughflow is not available for virtual clients."
        if $client->is_virtual;

    return "Only fiat currency accounts are allowed to sync to doughflow."
        unless LandingCompany::Registry::get_currency_type($client->default_account->currency_code) eq 'fiat';

    my $loginid = $client->loginid;

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $loginid});
    my $currency  = $df_client->doughflow_currency;

    return 'Sync not allowed as the client has never deposited using doughflow.'
        unless $currency;

    # create handoff token
    my $client_db = BOM::Database::ClientDB->new({
            client_loginid => $loginid,
        })->db;

    my $handoff_token = BOM::Database::Model::HandoffToken->new(
        db                 => $client_db,
        data_object_params => {
            key            => BOM::Database::Model::HandoffToken::generate_session_key,
            client_loginid => $loginid,
            expires        => time + 60,
        },
    );
    $handoff_token->save;

    my $doughflow_loc =
        BOM::Config::third_party()->{doughflow}->{request()->brand->name};
    my $doughflow_pass = BOM::Config::third_party()->{doughflow}->{passcode};
    my $url            = $doughflow_loc . '/CreateCustomer.asp';

    # hit DF's CreateCustomer API
    my $headers = HTTP::Headers->new();
    $headers->header('User-Agent' => 'Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:47.0) Gecko/20100101 Firefox/47.0');
    my $ua = LWP::UserAgent->new(
        timeout         => 60,
        default_headers => $headers
    );
    $ua->ssl_opts(
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE
    );    #temporarily disable host verification as full ssl certificate chain is not available in doughflow.

    my $result = $ua->post(
        $url,
        $df_client->create_customer_property_bag({
                SecurePassCode => $doughflow_pass,
                Sportsbook     => get_sportsbook($client->broker_code, $currency),
                IP_Address     => '127.0.0.1',
                Password       => $handoff_token->key,
            }));

    return "An error occurred while syncing client authentication status to doughflow. Error is: $result->{_content}"
        unless ($result->{'_content'} eq 'OK');

    my $msg =
          Date::Utility->new->datetime
        . " sync client authentication status to Doughflow by clerk=$clerk $ENV{REMOTE_ADDR}, "
        . 'loginid: '
        . $df_client->loginid
        . ', Email: '
        . $df_client->Email
        . ', Name: '
        . $df_client->CustName
        . ', Profile: '
        . $df_client->Profile;
    BOM::User::AuditLog::log($msg, $loginid, $clerk);

    return undef;
}

#

=head2 get_client_phone_country

Get abbreviation(s) of matching countrie(s) from the given client's phone based on phone code
Returns a string with country abbreviations separated by comma

Arguments:

=over 1

=item C<$client>, type L<BOM::User::Client>

Client whose phone is processed to find the matching countries

=item C<$countries_instance>, type "Locale::Country::Extra"

Instance of all available countries for a brand

=back

=cut

sub get_client_phone_country {
    my ($client, $countries_instance) = @_;
    my $client_phone_country;
    $client_phone_country = join(", ", ($countries_instance->codes_from_phone($client->phone) || [])->@*)
        if $client->phone;
    $client_phone_country = 'Unknown' unless $client_phone_country;

    return $client_phone_country;
}

sub check_client_login_id {
    my ($loginid) = @_;

    return ($loginid =~ m/[A-Z]{2,4}[\d]{4,10}$/) ? 1 : 0;
}

=head2 get_client_details

Description:  Works out all the client details required for more than 1 page.
Takes the following arguments

=over 4

=item -  %input,  Hash, The input paramters from the page submission

=item - $url, the url of the page being rendered.

=back

Returns  a Hash with
 (
 client, L<BOM::User::Client>
 user, L<BOM::User>
 encoded_loginid, encoded version of the loginid
 mt_logins, mt5 logins for this user ArrayRef of loginid strings.
 user_clients, all the clients for this user ArrayRef of L<BOM::User::Clients>
 broker, The broker for this client (string)
 encoded_broker, encoded Broker string j
 is_virtual_only, if this client only has  virtual accounts
 clerk,  The logged in staff members user id
 self_post, URL to use for posting  to itself
 self_href URL to use for referencing itself (postfixed with the client loginid)
)

=cut

sub get_client_details {
    my ($input, $url) = @_;
    my $loginid   = $input->{loginID};
    my $self_post = request()->url_for($url);
    my $self_href = request()->url_for($url, {loginID => $loginid});
    if (not $loginid) {

        BrokerPresentation("CLIENT DETAILS");
        code_exit_BO(
            qq[<p>Login ID is required</p>
            <form action="$self_post" method="get">
            <label>Login ID:</label><input type="text" name="loginID" size="15" data-lpignore="true" />
            </form>]
        );
    }
    $loginid = trim(uc $loginid);

    my $encoded_loginid = encode_entities($loginid);

    try { BrokerPresentation("$encoded_loginid CLIENT DETAILS") } catch { }

    # If the loginid correspond to a trading platform
    # show a loginid picker page.
    if ($loginid =~ /^(MT|DX|EZ|CT)[DR]?/) {
        if (my $user = BOM::User->new(loginid => $loginid)) {
            my $logins             = loginids($user);
            my $mt_logins_ids      = $logins->{mt5};
            my $bom_logins         = $logins->{bom};
            my $dx_logins_ids      = $logins->{dx};
            my $derivez_logins_ids = $logins->{derivez};
            my $ctrader_logins_ids = $logins->{ctrader};

            Bar("$encoded_loginid LOGINIDS");

            BOM::Backoffice::Request::template()->process(
                'backoffice/client_loginids.html.tt',
                {
                    bom_logins       => $bom_logins,
                    mt5_loginids     => $mt_logins_ids,
                    dx_loginids      => $dx_logins_ids,
                    derivez_loginids => $derivez_logins_ids,
                    ctrader_loginids => $ctrader_logins_ids,
                },
            ) || die BOM::Backoffice::Request::template()->error(), "\n";

            code_exit_BO();
        }
    }

# given a bad-enough loginID, BrokerPresentation can die, leaving an unformatted screen..
# let the client-check offer a chance to retry.

    my $well_formatted = $loginid =~ m/^[A-Z]{2,4}[\d]{4,10}$/;
    my $client;
    try {
        $client = BOM::User::Client->new({loginid => $loginid}) if $well_formatted;
    } catch {
    }

    if (!$client) {
        my $message =
            $well_formatted
            ? "Client [$encoded_loginid] not found."
            : "Invalid Login ID provided.";

        print "<p class='notify notify--danger'>ERROR: $message </p>";
        code_exit_BO(
            qq[<form action="$self_post" method="get">
                <label>Try again:</label><input type="text" name="loginID" size="15" value="$encoded_loginid" data-lpignore="true" />
                <input type="submit" class="btn btn--primary" value="Search" />
            </form>]
        );
    }

    if ($client->loginid =~ /^MF/
        and !BOM::Backoffice::Auth::has_authorisation([qw/CSRegulated IT Compliance Payments Marketing-EU/]))
    {
        print "<p class='notify notify--danger'>ERROR: You cannot view this client's profile. </p>";
        code_exit_BO(
            qq[<form action="$self_post" method="get">
                <label>Login ID:</label><input type="text" name="loginID" size="15" value="$encoded_loginid" data-lpignore="true" />
                <input type="submit" class="btn btn--primary" value="Search" />
            </form>]
        );
    }

    my $user = $client->user;
    my @user_clients;
    push @user_clients, $client;
    foreach my $login_id ($user->bom_loginids) {
        next if ($login_id eq $client->loginid);
        push @user_clients, BOM::User::Client->new({loginid => $login_id}) if (LandingCompany::Registry->check_broker_from_loginid($login_id));
    }

    my $loginid_details = $user->loginid_details;
    my @mt_logins       = sort $user->get_mt5_loginids(
        type_of_account    => 'all',
        include_all_status => 1
    );

    my @dx_logins      = sort $user->get_dxtrade_loginids;
    my @derivez_logins = sort $user->get_derivez_loginids;
    my @ctrader_logins = sort $user->get_ctrader_loginids;

    my $is_virtual_only = (@user_clients == 1 and @mt_logins == 0 and $client->is_virtual);
    my $broker          = $client->broker;
    my $encoded_broker  = encode_entities($broker);
    my $clerk           = BOM::Backoffice::Auth::get_staffname();

    my $affiliate_mt5_accounts_db = $user->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(q{SELECT * FROM mt5.list_user_accounts(?)}, {Slice => {}}, $user->id);
        });

    my %affiliate_mt5_accounts = map { 'MTR' . $_->{mt5_account_id} => $_ } @$affiliate_mt5_accounts_db;

    return (
        client                 => $client,
        user                   => $user,
        encoded_loginid        => $encoded_loginid,
        mt_logins              => \@mt_logins,
        affiliate_mt5_accounts => \%affiliate_mt5_accounts,
        user_clients           => \@user_clients,
        broker                 => $broker,
        encoded_broker         => $encoded_broker,
        is_virtual_only        => $is_virtual_only,
        clerk                  => $clerk,
        self_post              => $self_post,
        self_href              => $self_href,
        dx_logins              => \@dx_logins,
        derivez_logins         => \@derivez_logins,
        ctrader_logins         => \@ctrader_logins,
        loginid_details        => $loginid_details,
    );
}

=head2 loginids

Gets a hashref of user loginids per trading platform (mt5/dx) and also
our system loginids (bom_loginids).

It takes the following params:

=over 4

=item * C<$user> - a L<BOM::User> instance.

=back

Returns a hashref.

=cut

sub loginids {
    my ($user) = @_;

    my $details   = $user->loginid_details;
    my @mt_logins = $user->get_mt5_loginids(
        type_of_account    => 'all',
        include_all_status => 1
    );
    my @bom_logins;
    my @dx_logins;
    my @derivez_logins;
    my @ctrader_logins;

    foreach my $lid (sort $user->bom_loginids()) {
        unless (LandingCompany::Registry->check_broker_from_loginid($lid)) {
            $log->warnf("Invalid login id $lid");
            next;
        }

        my $client = BOM::User::Client->new({loginid => $lid});

        my $formatted_balance;
        unless ($client->default_account) {
            $formatted_balance = '--- no currency selected';
        } else {
            my $balance = client_balance($client);
            $formatted_balance =
                $balance
                ? formatnumber('amount', $client->default_account->currency_code, $balance)
                : 'ZERO';
        }

        push @bom_logins,
            {
            text        => encode_entities($lid),
            balance     => $formatted_balance,
            currency    => ' (' . ($client->default_account ? $client->default_account->currency_code : 'No currency selected') . ')',
            is_disabled => $client->status->disabled
            };
    }

    my @platforms = ('dxtrade', 'derivez', 'ctrader');

    foreach my $platform (@platforms) {
        foreach my $lid ($user->get_trading_platform_loginids(platform => $platform)) {
            my $currency;
            my $market_type;
            my $account_type;
            my $login;

            if (my $details = $details->{$lid}) {
                ($currency, $account_type) = @{$details}{qw/currency account_type/};

                if (my $attributes = $details->{attributes}) {
                    ($market_type, $login) = @{$attributes}{qw/market_type login/};
                }
            }

            my %common_params = (
                loginid      => encode_entities($lid),
                market_type  => $market_type  // 'missing market type',
                account_type => $account_type // 'missing account type',
                currency     => $currency     // 'missing currency',
            );

            if ($platform eq 'dxtrade') {
                push @dx_logins,
                    +{
                    %common_params,
                    dxlogin => $login // 'missing dxlogin',
                    };
            }

            if ($platform eq 'derivez') {
                push @derivez_logins, +{%common_params,};
            }

            if ($platform eq 'ctrader') {
                push @ctrader_logins, +{%common_params,};
            }
        }
    }

    return {
        mt5     => \@mt_logins,
        dx      => \@dx_logins,
        bom     => \@bom_logins,
        derivez => \@derivez_logins,
        ctrader => \@ctrader_logins,
    };
}

=head2 client_search_and_navigation

Description: Builds the previous next client navigation display and let search clients by loginid and email address.

=over 4

=item - $client L<BOM::User::Client>

=item - $self_post  string,  url that the links should point to.

=back

Returns  undef

=cut

sub client_search_and_navigation {
    my ($client, $self_post) = @_;
    Bar("NAVIGATION");

    my $encoded_loginid = encode_entities($client->loginid);
    my $email           = encode_entities($client->user->{email});
    my $email_url       = request()->url_for('backoffice/client_email.cgi');

    print '<div class="row">';

    print qq{
        <form action="$self_post" method="get">
            <input type="text" size="15" maxlength="15" name="loginID" value="$encoded_loginid" data-lpignore="true" />
        </form>

        <form action="$email_url" method="get">
            <input type="text" size="30" name="email" value="$email" placeholder="email\@domain.com" data-lpignore="true" />
        </form>
    };

# find next and prev real clients but give up after a few tries in each direction.
    my $attempts = 3;
    my ($prev_client, $next_client, $prev_loginid, $next_loginid);
    my $client_broker = $client->broker;
    (my $number = $client->loginid) =~ s/$client_broker//;
    my $len = length($number);
    for (1 .. $attempts) {
        $prev_loginid = sprintf "$client_broker%0*d", $len, $number - $_;
        last
            if $prev_client = BOM::User::Client->new({loginid => $prev_loginid});
    }

    for (1 .. $attempts) {
        $next_loginid = sprintf "$client_broker%0*d", $len, $number + $_;
        last
            if $next_client = BOM::User::Client->new({loginid => $next_loginid});
    }

    my $encoded_prev_loginid = encode_entities($prev_loginid);
    my $encoded_next_loginid = encode_entities($next_loginid);

    if ($prev_client) {
        print qq{
        <form action="$self_post" method="get">
        <input type="hidden" name="loginID" value="$encoded_prev_loginid">
        <input type="submit" class="btn btn--primary" value="Previous client ($encoded_prev_loginid)">
        </form>
        }
    } else {
        print qq{<span class="btn btn--disabled">No client down to $encoded_prev_loginid</span>};
    }

    if ($next_client) {
        print qq{
        <form action="$self_post" method="get">
        <input type="hidden" name="loginID" value="$encoded_next_loginid">
        <input type="submit" class="btn btn--primary" value="Next client ($encoded_next_loginid)">
        </form>
        }
    } else {
        print qq{<span class="btn btn--disabled">No client up to $encoded_next_loginid</span>};
    }

    print '</div>';
    return undef;
}

=head2 get_fiat_login_id_for

Description: Given a client loginID, this sub will return a Real Fiat loginID from the
client following these rules:

=over 3

=item  If an available (not disabled and not duplicatd) account exists, this will be returned
=item  Unavailable(duplicated or disabled) loginID will be returned IF AND ONLY IF no other real fiat account loginID is available.
=item In case there is no available accounts, the first unavailable retrieved from database will be returned.

=back

=over 4

=item - $lid string, the client loginid.

=item - $broker, the broker code for building the link

=back

Returns Hash with keys `fiat_loginid`, `fiat_link` and `fiat_statement`

=cut

sub get_fiat_login_id_for {
    my $lid    = uc shift;
    my $broker = shift;

    my $client = BOM::User::Client->new({loginid => $lid});

    my %fiat_details = (
        fiat_loginid => undef,
        fiat_link    => undef
    );

    my $fiat_loginid = undef;
    my $broker_code  = undef;
    foreach my $login_id ($client->user->bom_loginids) {
        my $client_account = BOM::User::Client->new({loginid => $login_id});
        next if $client_account->is_virtual();
        next unless $client_account->currency;
        next if (LandingCompany::Registry::get_currency_type($client_account->currency) // '') eq 'crypto';
        $broker_code = $broker;
        if (not $client_account->is_available()) {
            $fiat_loginid //= $login_id;
            next;
        }
        $fiat_loginid = $login_id;
        last;
    }

    $fiat_details{fiat_loginid} = $fiat_loginid;
    $fiat_details{fiat_link}    = request()->url_for(
        'backoffice/f_clientloginid_edit.cgi',
        {
            broker  => $broker,
            loginID => $fiat_loginid
        });
    $fiat_details{fiat_statement} = request()->url_for(
        'backoffice/f_manager_history.cgi',
        {
            broker  => $broker,
            loginID => $fiat_loginid
        });

    return %fiat_details;
}

=head2 client_text_field_validation_info

Returns a hash-ref representing information about validation of client's free text profile fields,
containing a regex pattern, an error message, a name (display name) and a validation result (is_valid)
for each field. It takes following args:

=over 1

=item C<client>: client object to take values form

=item C<args>: a collection of named arguments, values of which override C<client>'s attributes
(used for letting input values be validated before they are saved to the C<client> object,
and dealing with the special field C<secret_answer>, whose value cannot be read directly from client object).

=back

=cut

sub client_text_field_validation_info {
    my ($client, %args) = @_;

    my %validations = (
        first_name => {
            pattern => q/^[\p{L}\s`"'.-]{2,50}$/,
            message => 'Within 2-50 characters, use only letters, spaces, hyphens, full-stops or apostrophes.',
            name    => 'First Name',
        },
        last_name => {
            pattern => q/^[\p{L}\s`'.-]{1,50}$/,
            message => 'Within 1-50 characters, use only letters, spaces, hyphens, full-stops or apostrophes.',
            name    => 'Last Name',

        },
        address_1 => {
            pattern => q/^[\p{L}\p{Nd}\s'\N{U+2019}.,:;()\x{b0}@#\/-]{1,70}$/,
            message => 'Within 70 characters, Only letters, numbers, space, and these special characters are allowed: - . \' # ; : ( ) , @ /',
            name    => 'Address 1',
        },
        address_2 => {
            pattern => q/^[\p{L}\p{Nd}\s'\N{U+2019}.,:;()\x{b0}@#\/-]{0,70}$/,
            message => 'Within 70 characters, Only letters, numbers, space, and these special characters are allowed: - . \' # ; : ( ) , @ /',
            name    => 'Address 2',
        },
        city => {
            pattern => q/^[\p{L}\s'.-]{1,35}$/,
            message => 'Within 35 characters, use only letters, spaces, hyphens, full-stops or apostrophes',
            name    => 'City/Town',
        },
        address_postcode => {
            pattern => q/^[\w\s-]{0,20}$/,
            message => 'Within 20 characters, use only letters, spaces, underscore or hyphens',
            name    => 'Postal Code',
        },
        tax_identification_number => {
            pattern => q/^[\w\-\/. ]{0,20}$/,
            message => 'Within 20 characters, use only letters, space and these characters: - _ . /',
            name    => 'Tax Identification Number',
        },
        # secrete question could be limitted to the values accepted by websocket API,
        # but in backoffice it's still a free text field.
        secret_question => {
            pattern => q/^[\w\-,.' ]{4,50}$/,
            message => 'Within 4 to 50 characters, use only letters, numbers, space, hyphen, period, and apostrophe.',
            name    => 'Secret Question',
        },
        secret_answer => {
            pattern => q/^[\w\-,.' ]{4,50}$/,
            message => 'Within 4 to 50 characters, use only letters, numbers, space, hyphen, period, and apostrophe.',
            name    => 'Secret Answer',
        },
        restricted_ip_address => {
            pattern => q/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/,
            message => 'Four integers separated by dots, like 172.154.22.22',
            name    => 'Ip Security',
        });

    for my $field (keys %validations) {
        my $value = $args{$field} // $client->$field // '';
        $validations{$field}->{is_valid} = (not $value or $value =~ m/$validations{$field}->{pattern}/);
    }

    return \%validations;
}

sub get_aml_risk_classicications {
    my @classifications = ('low', 'standard', 'high', 'manual override - low', 'manual override - standard', 'manual override - high');
    return map { {name => ucfirst($_), value => $_} } @classifications;
}

sub link_for_clientloginid_edit {
    my $login_id = shift;

    return
          '<a class="link" href="'
        . request()->url_for("backoffice/f_clientloginid_edit.cgi", {loginID => encode_entities($login_id)}) . '">'
        . encode_entities($login_id) . '</a>';
}

=head2 check_update_needed

Checks if a change in an account is allowed to be synced to a specific sibling.
It takes following arguments:

=over 4

=item - $client, a L<BOM::User::Client> object of the client being edited.

=item - $client_checked, a L<BOM::User::Client> object representing the account to be checked for syncing.

=item - $key the name of the key being updated.

=back

Returns  1 if the sibling can be updated, 0 otherwise.

=cut

sub check_update_needed {
    my ($client, $client_checked, $key) = @_;

    # %sync_scope:
    # client: the key only apply to the current client
    # lc: the key will apply to all clients in the same lc
    # user: the key will aply to all clients of this user
    # default is user
    my %sync_scope = (
        client_aml_risk_classification => 'lc',
        aml_risk_classification        => 'lc',
    );

    return 1 if (!exists($sync_scope{$key}) || $sync_scope{$key} eq 'user');
    return $client_checked->loginid eq $client->loginid
        if ($sync_scope{$key} eq 'client');
    return $client_checked->broker eq $client->broker
        if ($sync_scope{$key} eq 'lc');
    die "don't know the scope $sync_scope{$key}";
}

=head2 p2p_advertiser_approval_check

Checks if p2p advertiser approval has changed based on hidden form field
"p2p_approved" which contains the previous approval state.

=over 4

=item * C<client> - the client instance

=item * C<params> - a hashref of the user inputs

=back

=cut

sub p2p_advertiser_approval_check {
    my ($client, $params) = @_;

    return unless exists $params->{p2p_approved};
    my $p2p_advertiser = $client->_p2p_advertiser_cached or return;
    if ($params->{p2p_approved} ne $p2p_advertiser->{is_approved}) {
        BOM::Platform::Event::Emitter::emit('p2p_advertiser_approval_changed', {client_loginid => $client->loginid});
    }
}

=head2 get_detailed_status_reason

Maps reason code to a detailed reasoning message
Returns the code back if there's no detailed version present

=cut

sub get_detailed_status_reason {
    my $status_reason = shift;

    # Mapping of status reason code to detailed reason
    # Uses state as it will not have to initialize it everytime this sub is called
    state $status_reason_map = {
        FIAT_TO_CRYPTO_TRANSFER_OVERLIMIT   => 'Client reached the fiat to crypto internal transfer limit',
        CRYPTO_TO_CRYPTO_TRANSFER_OVERLIMIT => 'Client reached the crypto to crypto internal transfer limit',
        CRYPTO_TO_FIAT_TRANSFER_OVERLIMIT   => 'Client reached the crypto to fiat internal transfer limit',
        P2P_ADVERTISER_CREATED              => 'Client applied to P2P',
        BECOME_HIGH_RISK                    => 'Client become high risk',
        MT5_ACCOUNT_IS_CREATED              => 'Client created MT5 account',
        MT5_DBVI_ACCOUNT_IS_CREATED         => 'MT5 DBVI account created (full authentication required within 10 days)',
        MT5_DVL_ACCOUNT_IS_CREATED          => 'MT5 DVL account created (full authentication required within 5 days)',
        WITHDRAWAL_LIMIT_REACHED            => 'Client reached withdrawal limit',
        MARKED_AS_NEEDS_ACTION              => 'Client was marked as Needs Action',
        POTENTIAL_FRAUD                     => 'Client was identified as potential fraud',
        CR_CREATION_FOR_NON_IDV_COUNTRIES   => 'CR creation for IDV unsupported countries',
    };

    return $status_reason ? $status_reason_map->{$status_reason} // $status_reason : 'Unknown reason';
}

=head2 get_mt5_group_and_status

Tries to get mt5 group and status from redis; if fails, queues a requests for retrieval of the missing info, returning nothing.

It takes a single argument:

=over 4

=item - mt5_loginid, an MT5 loginid

=back

And returns two values:

=over 4

=item - group: mt5 group of the input mt5_loginid

=item - status: status of the mt5 account (Enabled or Disabled)

=back

=cut

sub get_mt5_group_and_status {
    my ($mt5_loginid) = @_;

    return unless $mt5_loginid;

    # If we have group information, retrieve it
    my $cache_key = "MT5_USER_GROUP::$mt5_loginid";
    my $group     = BOM::Config::Redis::redis_mt5_user()->hmget($cache_key, 'group');

    if ($group and $group->[0]) {
        my $status = BOM::Config::Redis::redis_mt5_user()->hmget($cache_key, 'rights');

        my $rights = Deriv::TradingPlatform::MT5::UserRights::to_hash($status->[0]);

        if ($rights->{enabled}) {
            return $group->[0], 'Enabled';
        } else {
            return $group->[0], 'Disabled';

        }
    } else {
        # ... and if we don't, queue up the request. This may lead to a few duplicates
        # in the queue - that's fine, we check each one to see if it's already
        # been processed.
        BOM::Config::Redis::redis_mt5_user_write()->lpush('MT5_USER_GROUP_PENDING', join(':', $mt5_loginid, time));
    }

    return;
}

=head2 get_limit_expiration_date

get limit name and find first modified date for current value, add number of days the
value is valid and return expiration date to be used in exclusion table

=over

=item * C<db> - required. Database handler object.

=item * C<loginid> - required. Client loginid.

=item * C<limit_name> - required. The name of limit we want to calculate expiration date for.

=item * C<added_day> - Number of day the data is valid for a certain limit. 0 if none provided.

=back

=cut

sub get_limit_expiration_date {
    my ($db, $loginid, $limit_name, $added_day) = @_;

    return undef unless ($db and $loginid and $limit_name);
    return undef
        unless any { $_ eq $limit_name }
        qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_turnover max_30day_losses max_open_bets session_duration_limit max_deposit_daily max_deposit_7day max_deposit_30day/;

    my $latest_modified_date = $db->run(
        ping => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.get_self_exclusion_expiry_date(?,?)', undef, $loginid, $limit_name);
        });
    return undef if !defined $latest_modified_date;
    return Date::Utility->new($latest_modified_date)->plus_time_interval(($added_day // 0) . 'd')->date;
}

=head2 notify_resubmission_of_risk_disclaimer

Trigger risk_disclaimer_resubmission event.

=cut

sub notify_resubmission_of_risk_disclaimer {
    my ($loginid, $lang, $clerk) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid});

    my $brand = Brands->new(name => 'deriv');

    my $req = BOM::Backoffice::Request::Base->new(brand_name => $brand->name);
    BOM::Backoffice::Request::request($req);

    BOM::Platform::Event::Emitter::emit(
        'risk_disclaimer_resubmission',
        {
            language   => $lang,
            event      => 'risk_disclaimer_resubmission',
            loginid    => $client->loginid,
            properties => {
                title        => localize('Your affiliate account needs an update'),
                loginid      => $client->loginid,
                salutation   => $client->salutation,
                website_name => $brand->website_name,
            }});

    my $key   = RISK_DISCLAIMER_RESUBMISSION_KEY_PREFIX . $client->user->id;
    my $redis = BOM::Config::Redis::redis_replicated_write();
    $redis->hset($key . 'meta', 'updated_at', time);
    $redis->hset($key . 'meta', 'staff_name', $clerk);
}

=head2 get_dynamic_settings_list

Returns a hashref containing the list of Dynamic Settings.

=cut

sub get_dynamic_settings_list {
    return +{
        shutdown_suspend     => 'Shutdown/Suspend',
        quant                => 'Quant',
        it                   => 'IT',
        terms_and_conditions => 'T&C',
        others               => 'Others',
        payments             => 'Payments',
        crypto               => 'Cryptocurrency',
        compliance           => 'Compliance',
        anti_fraud           => 'Anti-Fraud',
    };
}

=head2 create_dropdown

Creates a dropdown (HTML C<select>) using the given items.

Takes a hash containing the list of following arguments:

=over 4

=item * C<name> - Name of dropdown

=item * C<items> - A hashref or arrayref containing the list of items. In case of hashref its structure is { value => text }, and when an arrayref the value and text would be the same

=item * C<selected_item> - An optional string represents the initially selected item

=item * C<only_options> - A boolean value, if 1 returns only the C<option> tags, otherwise wrapped in C<select>

=back

Returns a string containing the result HTML tags.

=cut

sub create_dropdown {
    my (%args) = @_;

    my $selected = $args{selected_item} // '';

    my %items = ref $args{items} eq 'HASH' ? $args{items}->%* : map { $_ => $_ } $args{items}->@*;

    my $options = join '', map { "<option value='$_'@{[$_ eq $selected ? ' selected=\"selected\"' : '']}>@{[$items{$_}]}</option>" }
        sort { $items{$a} cmp $items{$b} } keys %items;

    return $options if $args{only_options};

    return "<select name='$args{name}'>$options</select>";
}

=head2 write_operation_error

Returns an error if the logged in user tries to perform
an unauthorized update/write operation

=cut

sub write_operation_error {
    return "You are not authorized to update client details" if (request()->http_method eq 'POST' and not BOM::Backoffice::Auth::has_write_access());

    return undef;
}

=head2 get_sibiling_account_by_currency_code

Returns the sibling account login_id corresponding to the currency code

=over 4

=item * C<client_loginid> - client loginid

=item * C<currency_code> - currency code

=back

=cut

sub get_sibiling_account_by_currency_code {
    my ($client_loginid, $currency_code) = @_;

    my $client = BOM::User::Client->new({loginid => $client_loginid});
    my $user   = $client->user;

    foreach my $sibling_lid ($user->bom_real_loginids) {
        next if ($sibling_lid eq $client_loginid);
        next unless (LandingCompany::Registry->check_broker_from_loginid($sibling_lid));

        my $sibling_client   = BOM::User::Client->new({loginid => $sibling_lid});
        my $sibling_currency = $sibling_client->default_account->currency_code;

        return $sibling_lid if ($sibling_currency eq $currency_code);
    }

    return undef;
}

1;

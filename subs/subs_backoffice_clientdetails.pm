## no critic (RequireExplicitPackage)
use strict;
use warnings;

use Encode;
use Date::Utility;
use Format::Util::Strings qw( set_selected_item );
use Locale::Country 'code2country';
use Finance::MIFIR::CONCAT qw(mifir_concat);
use LWP::UserAgent;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );

use LandingCompany::Registry;

use BOM::Config;
use BOM::User::AuditLog;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::Account;
use BOM::User::Utility;
use BOM::Platform::Locale;
use BOM::Platform::S3Client;
use BOM::Platform::Client::DoughFlowClient;
use BOM::Backoffice::FormAccounts;
use BOM::Backoffice::Config;
use BOM::Backoffice::Request qw(request);
use BOM::Database::Model::HandoffToken;
use BOM::Config::RedisReplicated;

use constant ONFIDO_REPORT_KEY_PREFIX => 'ONFIDO::REPORT::ID::';

sub get_currency_options {
    my $currency_options;
    foreach my $currency (@{request()->available_currencies}) {
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
applicable to clients under Binary (Europe) Ltd & Binary (IOM) Ltd only. Change is also
applicable to clients under Binary Investments (Europe) Ltd for standardisation.
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

    # If exclude_until date has not expired and client is under Binary (SVG) Ltd.,
    # then Customer Support and Compliance team can amend or remove the exclude_until date
    return 1 if ($client->landing_company->short eq 'svg');

    # If exclude_until date has not expired and client is under Binary (Europe) Ltd, Binary (IOM) Ltd,
    # or Binary Investments (Europe) Ltd, then only Compliance team can amend or remove the exclude_until date
    return 1 if (BOM::Backoffice::Auth0::has_authorisation(['Compliance']));

    # Default value (no uplifting allowed)
    return 0;
}

=head2

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

    my $client = shift;

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
    my @month_names = (undef, qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec));
    my $dob_month_options = set_selected_item($dob_month,
        join "", map { "<option value=\"" . ($_ ? sprintf("%02s", $_) : "") . "\">" . ($month_names[$_] || "") . "</option>" } (0 .. $#month_names));
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

    my ($proveID, $show_uploaded_documents) = ('', '');
    my $user = $client->user;

    # User should be accessable from client by loginid
    print "<p style='color:red;'>User doesn't exist. This client is unlinked. Please, investigate.<p>" and die unless $user;

    my $client_for_prove = undef;

    # If client is from UK, check for ProveID
    if ($client->residence eq 'gb') {
        $client_for_prove = $client;

        # KYC/IDENTITY VERIFICATION SECTION
        $proveID = BOM::Platform::ProveID->new(
            client        => $client_for_prove,
            search_option => 'ProveID_KYC'
        );

        # If client is under Binary Investments (Europe) Ltd and there is no ProveID_KYC,
        # check whether there is ProveID_KYC under Binary (IOM) Ltd.
        if ($client->landing_company->short eq 'maltainvest' && !$client->status->proveid_requested) {
            for my $client_iom ($user->clients_for_landing_company('iom')) {
                my $prove = BOM::Platform::ProveID->new(
                    client        => $client_iom,
                    search_option => 'ProveID_KYC'
                );
                if (($client_iom->status->proveid_requested && !$client->status->proveid_pending) || $prove->has_saved_xml) {
                    $client_for_prove = $client_iom;
                    $proveID          = $prove;
                    last;
                }
            }
        }
    }

    unless ($client->is_virtual) {
        my @siblings = $user->loginids;

        $show_uploaded_documents .= show_client_id_docs($_->loginid, show_delete => 1) for $client;

        my $siblings_docs = '';
        $siblings_docs .= show_client_id_docs(
            $_,
            show_delete => 1,
            no_edit     => 1
        ) for grep { $_ ne $client->loginid } @siblings;

        $show_uploaded_documents .= 'To edit following documents please select corresponding user<br>' . $siblings_docs
            if $siblings_docs;

        if ($show_uploaded_documents) {
            my $confirm_box = qq{javascript:return get_checked_files()};
            $show_uploaded_documents .= qq{<button onclick="$confirm_box">Delete Checked Files</button>};
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
    }
    catch {
        $can_decode_secret_answer = 0;
        warn "ERROR: Loginid: " . $client->loginid . " - $_";
    };

    # MARKETING SECTION
    my $promo_code_access = BOM::Backoffice::Auth0::has_authorisation(['Marketing']);

    my $self_exclusion_enabled = $client->self_exclusion ? 'yes' : '';

    my $stateoptionlist = BOM::Platform::Locale::get_state_option($client->residence);
    my $stateoptions    = '<option value=""></option>';
    my $state_name      = '';
    for (@$stateoptionlist) {
        $state_name = $_->{text} if $_->{value} eq $client->state;
        $stateoptions .= qq|<option value="$_->{value}">$_->{text}</option>|;
    }

    my $tnc_status     = $client->status->tnc_approval;
    my $crs_tin_status = $client->status->crs_tin_information;

    my @tax_residences =
        $client->tax_residence
        ? split ',', $client->tax_residence
        : ();
    my $tax_residences_countries_name;

    if (@tax_residences) {
        $tax_residences_countries_name = join ',', map { code2country($_) } @tax_residences;
    }

    my $onfido_check = get_onfido_check_latest($client);

    my $check_status = {
        clear        => 'pass',
        rejected     => 'fail',
        suspected    => 'fail',
        consider     => 'maybe',
        caution      => 'maybe',
        unidentified => 'maybe',
    };

    my $sr_check_req = $client->landing_company->social_responsibility_check_required;
    my $sr_risk;

    if ($sr_check_req) {
        my $redis = BOM::Config::RedisReplicated::redis_events_write();
        $sr_risk = $redis->hset('social_responsibility', $client->loginid . '_sr_risk_status');
    }

    my $template_param = {
        client                => $client,
        client_phone_country  => $client_phone_country,
        client_tnc_version    => $tnc_status ? $tnc_status->{reason} : '',
        countries             => \@countries,
        country_codes         => $country_codes,
        crs_tin_information   => $crs_tin_status ? $crs_tin_status->{last_modified_date} : '',
        dob_day_options       => $dob_day_options,
        dob_month_options     => $dob_month_options,
        dob_year_options      => $dob_year_options,
        financial_risk_status => $client->status->financial_risk_approval,
        has_social_signup     => $user->{has_social_signup},
        lang                  => request()->language,
        language_options      => \@language_options,
        mifir_config          => $Finance::MIFIR::CONCAT::config,
        promo_code_access     => $promo_code_access,
        currency_type => (LandingCompany::Registry::get_currency_type($client->currency) // ''),
        proveID => $proveID,
        client_for_prove                  => $client_for_prove,
        salutation_options                => \@salutation_options,
        secret_answer                     => $secret_answer,
        can_decode_secret_answer          => $can_decode_secret_answer,
        self_exclusion_enabled            => $self_exclusion_enabled,
        show_allow_professional_client    => $client->landing_company->support_professional_client,
        show_social_responsibility_client => $client->landing_company->social_responsibility_check_required,
        social_responsibility_risk_status => $sr_risk // 'low',
        professional_status               => get_professional_status($client),
        show_funds_message                => ($client->residence eq 'gb' and not $client->is_virtual) ? 1 : 0,
        show_risk_approval => ($client->landing_company->short eq 'maltainvest') ? 1 : 0,
        show_tnc_status => ($client->is_virtual) ? 0 : 1,
        show_uploaded_documents            => $show_uploaded_documents,
        state_options                      => set_selected_item($client->state, $stateoptions),
        client_state                       => $state_name,
        tnc_approval_status                => $tnc_status,
        ukgc_funds_status                  => $client->status->ukgc_funds_protection,
        tax_residence                      => \@tax_residences,
        tax_residences_countries_name      => $tax_residences_countries_name,
        cashier_allow_payment_agent_status => $client->status->pa_withdrawal_explicitly_allowed,
        address_verification_status        => $client->status->address_verified,
        onfido_check_result                => $check_status->{$onfido_check->{result} // ''},
        onfido_check_url                   => $onfido_check->{results_uri} // '',
    };

    return BOM::Backoffice::Request::template()->process('backoffice/client_edit.html.tt', $template_param, undef, {binmode => ':utf8'})
        || die "Error:" . BOM::Backoffice::Request::template()->error();
}

## build_client_statement_form #######################################
# Purpose : Build the form that lets people view a Client's statement.
#           Used in several places in b/o, hence the subroutine.
######################################################################
sub build_client_statement_form {
    my $broker = shift @_;
    return
          '<hr><FORM ACTION="'
        . request()->url_for('backoffice/f_manager_history.cgi')
        . '" METHOD="POST">'
        . '<span style="color:red;"><b>Show All Transaction</b>, may fail for clients with huge number of transaction, so use this feature only when required.</span><br/>'
        . 'Check Statement of LoginID : <input id="statement_loginID" name="loginID" type="text" size="10" value="'
        . $broker . '"/>'
        . 'From : <input name="startdate" type="text" size="10" value="'
        . Date::Utility->today()->_minus_months(1)->date . ' "/>'
        . 'To : <input name="enddate" type="text" size="10" value="'
        . Date::Utility->today()->date . ' "/>'
        . '<input type="hidden" name="broker" value="'
        . $broker . '">'
        . '<SELECT name="currency_dropdown"><option value="default">client\'s default currency</option>'
        . get_currency_options()
        . '</SELECT>'
        . '<input type="hidden" name="l" value="EN">'
        . '<input type="checkbox" name="all_in_one_page">Show All Transactions</input>'
        . '&nbsp; <input type="checkbox" value="yes" name="depositswithdrawalsonly">Deposits and Withdrawals only '
        . '&nbsp; <input type="submit" value="Client Statement">'
        . '</FORM>';
}

## build_client_warning_message #######################################
# Purpose : To obtain the client warning status and return its status
#           in html form
######################################################################
sub build_client_warning_message {
    my $login_id = shift;
    my $client   = BOM::User::Client->new({'loginid' => $login_id}) || return "<p>The Client's details can not be found [$login_id]</p>";
    my $broker   = $client->broker;
    my @output;

    my $edit_client_with_status = sub {
        my $action_type = shift;
        return '<a href="'
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
        return '<a href="'
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
    my %client_status = map { $_ => $client->status->$_ } @{$client->status->all};
    foreach my $type (@{get_untrusted_types()}) {
        my $code = $type->{code};
        if (my $disabled = $client->status->$code) {
            delete $client_status{$type->{code}};
            push(
                @output,
                {
                    clerk      => $disabled->{staff_name},
                    reason     => $disabled->{reason},
                    warning    => 'red',
                    section    => $type->{comments},
                    editlink   => $edit_client_with_status->($type->{linktype}),
                    removelink => $remove_client_from->($type->{linktype}),
                });
        }
    }

    # build the table
    my $output =
          '<br/><table border="1" cellpadding="2" style="background-color:#cccccc">' . '<tr>'
        . '<th>STATUS</th>'
        . '<th>REASON/INFO</th>'
        . '<th>STAFF</th>'
        . '<th>EDIT</th>'
        . '<th>REMOVE</th>' . '</tr>';

    if (@output) {
        my $trusted_section;
        foreach my $output_rows (@output) {
            if ($output_rows->{'editlink'} =~ /trusted_action_type=(\w+)/ or $output_rows->{'removelink'} =~ /trusted_action_type=(\w+)/) {
                $trusted_section = $1;
            }

            $output .= '<tr>'
                . '<td align="left" style="color:'
                . $output_rows->{'warning'}
                . ';"><strong>'
                . (uc $output_rows->{'section'})
                . '</strong></td>'
                . '<td><b>'
                . $output_rows->{'reason'}
                . '</b></td>'
                . '<td><b>'
                . $output_rows->{'clerk'}
                . '</b></td>'
                . '<td><b>'
                . $output_rows->{'editlink'}
                . '</b></td>'
                . '<td><b>'
                . $output_rows->{'removelink'}
                . '</b></td></tr>';
        }
    }

    # Show all remaining status info
    for my $status (sort keys %client_status) {
        my $info = $client_status{$status};
        $output .= '<tr>'
            . '<td align="left">'
            . $status . '</td>'
            . '<td><b>'
            . ($info->{reason} // '')
            . '</b></td>'
            . '<td><b>'
            . ($info->{staff_name} // '')
            . '</b></td>'
            . '<td colspan="2">&nbsp;</td>' . '</tr>';
    }
    $output .= '</table><br>';

    $output .= qq~
    <script type="text/javascript" language="javascript">
         function append_dccode(linkobj)
         {
            var dcc_staff_id = 'dcc_staff_'+linkobj.id;
            var dcc_id       = 'dcc_'+linkobj.id;

            var dccstaff = \$('#'+dcc_staff_id).val();
            var dcc      = \$('#'+dcc_id).val();

            linkobj.href.replace(/\&dcstaff.+/,'');
            linkobj.href = linkobj.href + '&dccstaff=' + dccstaff + '&dcc=' + dcc;
         }
    </script>
    ~;

    return $output;
}

## get_untrusted_client_reason ###############################
#
# Purpose : all the available untrusted client reason
#
##############################################################
sub get_untrusted_client_reason {
    return {
        Disabled => [
            'Account closure',
            'Bonus code abuse',
            'Compact state probably',
            'Docs requested',
            'Fraudulent account',
            'Incomplete/false details',
            'Multiple IPs',
            'Pending investigation',
            'Pending proof of age',
            'Others'
        ],
        Duplicate          => ['Duplicate account'],
        UKGCAuthentication => ['Online verification passed'],
    };
}

## show_client_id_docs #######################################
# Purpose : generate the html to display client's documents.
# Relocated to here from Client module.
##############################################################
sub show_client_id_docs {
    my ($loginid, %args) = @_;
    my $show_delete = $args{show_delete};
    my $extra       = $args{no_edit} ? 'disabled' : '';
    my $links       = '';

    return unless $loginid;

    return '' if $loginid =~ /^MT/;

    my $dbic = BOM::Database::ClientDB->new({
            client_loginid => $loginid,
            operation      => 'replica',
        }
        )->db->dbic
        or die "[$0] cannot create connection";

    my $docs = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(<<'SQL', undef, $loginid);
SELECT id,
       file_name,
       expiration_date,
       comments,
       document_id,
       upload_date,
       age(date_trunc('day', now()), date_trunc('day', upload_date)) AS age
  FROM betonmarkets.client_authentication_document
 WHERE client_loginid = ? AND status != 'uploading'
SQL
        });
    foreach my $doc (sort { $a->[0] <=> $b->[0] } @$docs) {
        my ($id, $file_name, $expiration_date, $comments, $document_id, $upload_date, $age) = @$doc;

        if (not $file_name) {
            $links .= qq{<tr><td>Missing filename for a file with ID: $id</td></tr>};
            next;
        }

        my $age_display;
        if ($age) {
            $age =~ s/[\d:]{8}//g;
            $age_display = $age ? "$age old" : "today";
            $age_display = qq{<td title="$upload_date">$age_display</td>};
        } else {
            $age_display = '<td></td>';
        }

        my $date = $expiration_date || '';
        if ($date) {
            eval {
                my $formatted = Date::Utility->new($date)->date_yyyymmdd;
                $date = $formatted;
            } or do {
                warn "Invalid date, using original information: $date\n";
            };
        }

        my $input = qq{expires on <input type="text" style="width:100px" maxlength="15" name="expiration_date_$id" value="$date" $extra>};
        $input .= qq{document id <input type="text" style="width:100px" maxlength="30" name="document_id_$id" value="$document_id" $extra>};
        $input .= qq{comments <input type="text" style="width:100px" maxlength="255" name="comments_$id" value="$comments" $extra>};

        my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
        my $url       = $s3_client->get_s3_url($file_name);

        $links .= qq{<tr><td><a href="$url">$file_name</a></td>$age_display<td>$input};

        $links .= qq{<input type="checkbox" class='files_checkbox' name="del_document_list" value="$file_name">};

        $links .= "</td></tr>";
    }
    $links = "<table>$links</table>" if $links;

    return $links;
}

sub get_onfido_check_latest {
    my ($client) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic or die "[$0] cannot create connection";

    my $latest_check_result = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare('select * from users.get_onfido_checks(?::BIGINT, ?::TEXT, ?::BIGINT)');
            $sth->execute($client->binary_user_id, undef, 1);
            return $sth->fetchrow_hashref;
        });

    return $latest_check_result;
}

sub client_statement_summary {
    my $args = shift;
    my ($client, $before, $after) = @{$args}{'client', 'before', 'after'};
    my $max_number_of_lines = 65535;    #why not?
    my $currency;

    $currency = $args->{currency} if exists $args->{currency};
    $currency //= $client->currency;
    my $clientdb = BOM::Database::ClientDB->new({
        client_loginid => $client->loginid,
    });

    my $txn_dm = BOM::Database::DataMapper::Transaction->new({
        client_loginid => $client->loginid,
        currency_code  => $currency,
        db             => $clientdb->db,
    });
    my $transactions = $txn_dm->get_payments({
        before => $before,
        after  => $after,
        limit  => $max_number_of_lines
    });
    my $summary = {};

    foreach my $transaction (@{$transactions}) {
        my $k = $transaction->{action_type} eq 'deposit' ? 'deposits' : 'withdrawals';
        my $payment_system = $transaction->{payment_type} // '(unknown)';

        # DoughFlow
        $payment_system = $1 if $transaction->{payment_remark} =~ /payment_processor=(\S+)/;

        # bank wire
        $payment_system = $1 if $transaction->{payment_remark} =~ /Wire\s+payment\s+from\s+([\S]+\s[\d\-]+) on/;
        $payment_system = $1 if $transaction->{payment_remark} =~ /Wire\s+deposit\s+.+\s+Recieved\s+by\s+([\S]+\s[\d\-]+)/;

        $summary->{$k}{$payment_system} += $transaction->{amount};
    }
    foreach my $type (keys %$summary) {
        my $ps_summary = [];
        my $total      = 0;
        foreach (sort keys %{$summary->{$type}}) {
            push @$ps_summary, [$_, $summary->{$type}->{$_}];
            $total += $summary->{$type}->{$_};
        }
        push @$ps_summary, ['total', $total];
        $summary->{$type} = $ps_summary;
    }

    # include client's profit & loss in the summary for easier analysis
    my $dbic       = $clientdb->db->dbic;
    my $account_id = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT id FROM transaction.account WHERE client_loginid=?});
            $sth->execute($client->loginid);
            my $out = $sth->fetchall_arrayref();
            return $out->[0][0];
        });
    my $pnl_summary = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT * FROM get_close_trades_profit_or_loss(?,?,?,?)",
                undef, $account_id, $client->currency, $client->date_joined, Date::Utility->new->datetime);
        });

    $summary->{pnl} = $pnl_summary->{get_close_trades_profit_or_loss} ? $pnl_summary->{get_close_trades_profit_or_loss} : '0.00';

    return $summary;
}

sub client_statement_for_backoffice {
    my $args = shift;
    my ($client, $before, $after, $max_number_of_lines) = @{$args}{'client', 'before', 'after', 'max_number_of_lines'};

    if (not $max_number_of_lines) {
        $max_number_of_lines = 200;
    }

    my $currency;
    $currency = $args->{currency} if exists $args->{currency};
    $currency //= $client->currency;

    my $depositswithdrawalsonly = request()->param('depositswithdrawalsonly') // '';

    my $db = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
        })->db;

    my $txn_dm = BOM::Database::DataMapper::Transaction->new({
        client_loginid => $client->loginid,
        currency_code  => $currency,
        db             => $db,
    });

    my $transactions = [];
    if ($depositswithdrawalsonly eq 'yes') {
        $transactions = $txn_dm->get_payments({
            before => $before,
            after  => $after,
            limit  => $max_number_of_lines
        });
        foreach my $transaction (@{$transactions}) {
            $transaction->{amount} = abs($transaction->{amount});

        }
    } else {
        $transactions = $txn_dm->get_transactions({
            after  => $after,
            before => $before,
            limit  => $max_number_of_lines
        });

        foreach my $transaction (@{$transactions}) {
            $transaction->{amount} = abs($transaction->{amount});
            $transaction->{remark} = $transaction->{bet_remark};
        }
    }

    my $acnt_dm = BOM::Database::DataMapper::Account->new({
        client_loginid => $client->loginid,
        currency_code  => $currency,
        db             => $db,
    });

    my $balance = {
        date   => Date::Utility->today,
        amount => $acnt_dm->get_balance(),
    };

    return {
        transactions => $transactions,
        balance      => $balance,
    };
}

sub get_untrusted_types {
    return [{
            'linktype'    => 'disabledlogins',
            'comments'    => 'Disabled/Closed Accounts',
            'code'        => 'disabled',
            'show_reason' => 'yes'
        },
        {
            'linktype'    => 'lockcashierlogins',
            'comments'    => 'Cashier Lock Section',
            'code'        => 'cashier_locked',
            'show_reason' => 'yes'
        },
        {
            'linktype'    => 'unwelcomelogins',
            'comments'    => 'Unwelcome loginIDs',
            'code'        => 'unwelcome',
            'show_reason' => 'yes'
        },
        {
            'linktype'    => 'nowithdrawalortrading',
            'comments'    => 'Disable Withdrawal and Trading',
            'code'        => 'no_withdrawal_or_trading',
            'show_reason' => 'yes'
        },
        {
            'linktype'    => 'lockwithdrawal',
            'comments'    => 'Withdrawal Locked',
            'code'        => 'withdrawal_locked',
            'show_reason' => 'yes'
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
            'show_reason' => 'yes'
        },
        {
            'linktype'    => 'ukgcauthenticated',
            'comments'    => 'UKGC authenticated',
            'code'        => 'ukgc_authenticated',
            'show_reason' => 'yes'
        },
        {
            'linktype'    => 'professionalrequested',
            'comments'    => 'Professional requested',
            'code'        => 'professional_requested',
            'show_reason' => 'no'
        },
    ];
}

sub get_open_contracts {
    my $client = shift;
    return BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
            operation      => 'replica',
        })->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', [$client->loginid, $client->currency, 'false']);
}

sub sync_to_doughflow {
    my ($client, $clerk) = @_;

    return "Invalid account." unless $client;

    return "No currency selected for account." unless $client->default_account;

    return "Sync to doughflow is not available for virtual clients." if $client->is_virtual;

    return "Only fiat currency accounts are allowed to sync to doughflow."
        unless LandingCompany::Registry::get_currency_type($client->default_account->currency_code) eq 'fiat';

    my $loginid = $client->loginid;

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $loginid});
    my $currency = $df_client->doughflow_currency;

    return 'Sync not allowed as the client has never deposited using doughflow.' unless $currency;

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

    my $doughflow_loc  = BOM::Config::third_party()->{doughflow}->{request()->brand->name};
    my $doughflow_pass = BOM::Config::third_party()->{doughflow}->{passcode};
    my $url            = $doughflow_loc . '/CreateCustomer.asp';

    # hit DF's CreateCustomer API
    my $ua = LWP::UserAgent->new(timeout => 60);
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
    $client_phone_country = join(", ", ($countries_instance->codes_from_phone($client->phone) || [])->@*) if $client->phone;
    $client_phone_country = 'Unknown' unless $client_phone_country;

    return $client_phone_country;
}

sub check_client_login_id {
    my ($loginid) = @_;

    return ($loginid =~ m/[A-Z]{2,4}[\d]{4,10}$/) ? 1 : 0;
}

1;

## no critic (RequireExplicitPackage)
use strict;
use warnings;
use Encode;

use Format::Util::Strings qw( set_selected_item );
use Date::Utility;
use Brands;

use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::Account;
use BOM::Platform::Client::Utility ();
use BOM::Backoffice::Request qw(request);
use BOM::Platform::Locale;
use BOM::Backoffice::FormAccounts;
use BOM::Backoffice::Script::DocumentUpload;
use Finance::MIFIR::CONCAT qw(mifir_concat);

sub get_currency_options {
    my $currency_options;
    foreach my $currency (@{request()->available_currencies}) {
        $currency_options .= '<option value="' . $currency . '">' . $currency . '</option>';
    }
    return $currency_options;
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
    my $dob_month_options = set_selected_item(
        $dob_month,
        localize(
            '<option value=""></option><option value="01">Jan</option><option value="02">Feb</option><option value="03">Mar</option><option value="04">Apr</option><option value="05">May</option><option value="06">Jun</option><option value="07">Jul</option><option value="08">Aug</option><option value="09">Sep</option><option value="10">Oct</option><option value="11">Nov</option><option value="12">Dec</option>'
        ));
    my $dob_year_optionlist = BOM::Backoffice::FormAccounts::DOB_YearList($dob_year);
    my $dob_year_options    = '<option value=""></option>';
    $dob_year_options .= qq|<option value="$_->{value}">$_->{value}</option>| for @$dob_year_optionlist;
    $dob_year_options = set_selected_item($dob_year, $dob_year_options);

    my @countries;
    my $country_codes = {};
    my $countries_instance = Brands->new(name => request()->brand)->countries_instance->countries;
    foreach my $country_name (sort $countries_instance->all_country_names) {
        push @countries, $country_name;
        $country_codes->{$country_name} = $countries_instance->code_from_country($country_name);
    }

    my ($proveID, $show_uploaded_documents) = ('', '');
    my $user = BOM::Platform::User->new({loginid => $client->loginid});

    # User should be accessable from client by loginid
    print "<p style='color:red;'>User doesn't exist. This client is unlinked. Please, investigate.<p>" and die unless $user;

    unless ($client->is_virtual) {
        # KYC/IDENTITY VERIFICATION SECTION
        $proveID = BOM::Platform::ProveID->new(
            client        => $client,
            search_option => 'ProveID_KYC'
        );

        my $user = BOM::Platform::User->new({loginid => $client->loginid});
        my $siblings = $user->loginid;

        $show_uploaded_documents .= show_client_id_docs($_->loginid, show_delete => 1) for $client;

        my $siblings_docs = '';
        $siblings_docs .= show_client_id_docs(
            $_->loginid,
            show_delete => 1,
            no_edit     => 1
        ) for grep { $_->loginid ne $client->loginid } @$siblings;

        $show_uploaded_documents .= 'To edit following documents please select corresponding user<br>' . $siblings_docs
            if $siblings_docs;
    }

    # COMMUNICATION ADDRESSES
    my $client_phone_country = $countries_instance->code_from_phone($client->phone);
    if (not $client_phone_country) {
        $client_phone_country = 'Unknown';
    }

    my @language_options = @{BOM::Platform::Runtime->instance->app_config->cgi->allowed_languages};

    # SECURITYS SECTION
    my $secret_answer = BOM::Platform::Client::Utility::decrypt_secret_answer($client->secret_answer);

    if (!Encode::is_utf8($secret_answer)) {
        $secret_answer = Encode::decode("UTF-8", $secret_answer);
    }

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

    my $tnc_status = $client->get_status('tnc_approval');
    my $show_allow_professional_client = $client->landing_company->short =~ /^(?:costarica|maltainvest)$/ ? 1 : 0;

    my @crs_tin_array = ();
    if (my $crs_tin_status = $client->get_status('crs_tin_information')) {
        my @dates = sort { Date::Utility->new($a)->epoch <=> Date::Utility->new($b)->epoch } split ",", $crs_tin_status->reason;
        for my $i (0 .. $#dates) {
            push @crs_tin_array, "Client submitted the TIN information Version " . ($i + 1) . " on " . $dates[$i];
        }
    }

    my $template_param = {
        client                => $client,
        client_phone_country  => $client_phone_country,
        client_tnc_version    => $tnc_status ? $tnc_status->reason : '',
        countries             => \@countries,
        country_codes         => $country_codes,
        csr_tin_information   => \@crs_tin_array,
        dob_day_options       => $dob_day_options,
        dob_month_options     => $dob_month_options,
        dob_year_options      => $dob_year_options,
        financial_risk_status => $client->get_status('financial_risk_approval'),
        has_social_signup     => $user->has_social_signup,
        is_vip                => $client->is_vip,
        lang                  => request()->language,
        language_options      => \@language_options,
        mifir_config          => $Finance::MIFIR::CONCAT::config,
        promo_code_access     => $promo_code_access,
        currency_type => (LandingCompany::Registry::get_currency_type($client->currency) // ''),
        proveID => $proveID,
        salutation_options             => \@salutation_options,
        secret_answer                  => $secret_answer,
        self_exclusion_enabled         => $self_exclusion_enabled,
        client_professional_status     => $client->get_status('professional'),
        show_allow_professional_client => $show_allow_professional_client,
        show_allow_omnibus             => (not $client->is_virtual and $client->landing_company->short eq 'costarica' and not $client->sub_account_of)
        ? 1
        : 0,
        show_funds_message => ($client->residence eq 'gb' and not $client->is_virtual) ? 1 : 0,
        show_risk_approval => ($client->landing_company->short eq 'maltainvest') ? 1 : 0,
        show_tnc_status => ($client->is_virtual) ? 0 : 1,
        show_uploaded_documents => $show_uploaded_documents,
        state_options           => set_selected_item($client->state, $stateoptions),
        client_state            => $state_name,
        tnc_approval_status     => $tnc_status,
        ukgc_funds_status       => $client->get_status('ukgc_funds_protection'),
        vip_since               => $client->vip_since,
    };

    return BOM::Backoffice::Request::template->process('backoffice/client_edit.html.tt', $template_param, undef, {binmode => ':utf8'})
        || die "Error:" . BOM::Backoffice::Request::template->error();
}

## build_client_statement_form #######################################
# Purpose : Build the form that lets people view a Client's statement.
#           Used in several places in b/o, hence the subroutine.
######################################################################
sub build_client_statement_form {
    my $broker = shift @_;

    return
          "<hr><FORM ACTION=\""
        . request()->url_for("backoffice/f_manager_history.cgi")
        . "\" METHOD=\"POST\">"
        . "Check Statement of LoginID : <input id='statement_loginID' name=loginID type=text size=10 value='$broker'>"
        . "<INPUT type=hidden name=\"broker\" value=\"$broker\">"
        . "<SELECT name=\"currency\"><option value=\"default\">client's default currency</option>"
        . get_currency_options()
        . "</SELECT>"
        . "<INPUT type=hidden name=\"l\" value=\"EN\">"
        . "&nbsp; <INPUT type=\"submit\" value='Client Statement'>"
        . "&nbsp; <input type=checkbox value=yes name=depositswithdrawalsonly>Deposits and Withdrawals only "
        . "</FORM>";
}

## build_client_warning_message #######################################
# Purpose : To obtain the client warning status and return its status
#           in html form
######################################################################
sub build_client_warning_message {
    my $login_id = shift;
    my $client   = Client::Account->new({'loginid' => $login_id}) || return "<p>The Client's details can not be found [$login_id]</p>";
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
                untrusted_action      => 'remove_data',
                login_id              => $login_id,
                broker                => $broker,
                untrusted_action_type => $action_type
            }) . '">remove</a>';
    };

    ###############################################
    ## UNTRUSTED SECTION
    ###############################################
    my %client_status = map { $_->status_code => $_ } @{$client->client_status || []};
    foreach my $type (@{get_untrusted_types()}) {
        if (my $disabled = $client->get_status($type->{code})) {
            delete $client_status{$type->{code}};
            push(
                @output,
                {
                    clerk      => $disabled->staff_name,
                    reason     => $disabled->reason,
                    warning    => 'red',
                    section    => $type->{comments},
                    editlink   => $edit_client_with_status->($type->{linktype}),
                    removelink => $remove_client_from->($type->{linktype}),
                });
        }
    }

    # build the table
    my $output = '';
    if (@output) {
        $output =
              '<br /><table border="1" cellpadding="2" style="background-color:#cccccc">' . '<tr>'
            . '<th>STATUS</th>'
            . '<th>REASON/INFO</th>'
            . '<th>STAFF</th>'
            . '<th>EDIT</th>'
            . '<th>REMOVE</th>' . '</tr>';

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

# Show all remaining status info
        for my $status (sort keys %client_status) {
            my $info = $client_status{$status};
            $output .= '<tr>'
                . '<td align="left">'
                . $status . '</td>'
                . '<td><b>'
                . $info->reason
                . '</b></td>'
                . '<td><b>'
                . $info->staff_name
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
        Duplicate => ['Duplicate account'],
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

    return '' if !$loginid || $loginid =~ /^MT/;

    my $client = Client::Account->new({loginid => $loginid});

    my $docs = $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(<<'SQL', undef, $loginid);
SELECT id,
       file_name,
       expiration_date,
       comments,
       document_id,
       upload_date,
       date_trunc('day', age(now(), upload_date)) AS age
  FROM betonmarkets.client_authentication_document
 WHERE client_loginid = ?
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
        $input .= qq{comments <input type="text" style="width:100px" maxlength="20" name="comments_$id" value="$comments" $extra>};
        $input .= qq{document id <input type="text" style="width:100px" maxlength="20" name="document_id_$id" value="$document_id" $extra>};

        my $url = BOM::Backoffice::Script::DocumentUpload::get_s3_url($file_name);

        $links .= qq{<tr><td><a href="$url">$file_name</a></td>$age_display<td>$input};
        if ($show_delete && !$args{no_edit}) {
            my $onclick    = qq{javascript:return confirm('Are you sure you want to delete $file_name?')};
            my $delete_url = request()->url_for("backoffice/download_document.cgi?loginid=$loginid&doc_id=$id&deleteit=yes");
            $links .= qq{[<a onclick="$onclick" href="$delete_url">Delete</a>]};
        }
        $links .= "</td></tr>";
    }
    $links = "<table>$links</table>" if $links;
    return $links;
}

sub client_statement_summary {
    my $args = shift;
    my ($client, $before, $after) = @{$args}{'client', 'before', 'after'};
    my $max_number_of_lines = 65535;    #why not?
    my $currency;

    $currency = $args->{currency} if exists $args->{currency};
    $currency //= $client->currency;
    my $db = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
        })->db;

    my $txn_dm = BOM::Database::DataMapper::Transaction->new({
        client_loginid => $client->loginid,
        currency_code  => $currency,
        db             => $db,
    });
    my $transactions = $txn_dm->get_payments({
        before => $before,
        after  => $after,
        limit  => $max_number_of_lines
    });
    my $summary = {};

    foreach my $transaction (@{$transactions}) {
        my $k = $transaction->{action_type} eq 'deposit' ? 'deposits' : 'withdrawals';
        my $payment_system = '(unknown)';

        # EPG
        $payment_system = $1 if $transaction->{payment_remark} =~ /payment_solution=(\S+)/;

        # DoughFlow
        $payment_system = $1 if $transaction->{payment_remark} =~ /payment_processor=(\S+)/;

        # bank wire
        $payment_system = $1 if $transaction->{payment_remark} =~ /Wire\s+payment\s+from\s+([\S]+\s[\d\-]+) on/;
        $payment_system = $1 if $transaction->{payment_remark} =~ /Wire\s+deposit\s+.+\s+Recieved\s+by\s+([\S]+\s[\d\-]+)/;

        # transfer between accounts
        $payment_system = "internal_transfer" if $transaction->{payment_remark} =~ /Account transfer from /;

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
        balance      => $balance
    };
}

sub get_untrusted_types {
    return [{
            'linktype' => 'disabledlogins',
            'comments' => 'Disabled/Closed Accounts',
            'code'     => 'disabled'
        },
        {
            'linktype' => 'lockcashierlogins',
            'comments' => 'Cashier Lock Section',
            'code'     => 'cashier_locked'
        },
        {
            'linktype' => 'unwelcomelogins',
            'comments' => 'Unwelcome loginIDs',
            'code'     => 'unwelcome'
        },
        {
            'linktype' => 'lockwithdrawal',
            'comments' => 'Withdrawal Locked',
            'code'     => 'withdrawal_locked'
        },
        {
            'linktype' => 'jpactivationpending',
            'comments' => 'jp activation pending',
            'code'     => 'jp_activation_pending'
        },
        {
            'linktype' => 'jptransactiondetail',
            'comments' => 'jp bank details stored',
            'code'     => 'jp_transaction_detail'
        },
        {
            'linktype' => 'duplicateaccount',
            'comments' => 'Duplicate account',
            'code'     => 'duplicate_account'
        },
    ];
}

1;

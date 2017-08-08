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
use Finance::MIFIR::CONCAT qw(mifir_concat);

sub get_currency_options {
    my $currency_options;
    foreach my $currency (@{request()->available_currencies}) {
        $currency_options .= '<option value="' . $currency . '">' . $currency . '</option>';
    }
    return $currency_options;
}

sub print_client_details {

    my ($client, $staff) = @_;

    # IDENTITY sECTION
    my @mrms_options = BOM::Backoffice::FormAccounts::GetSalutations();

    # Extract year/month/day if we have them
    my ($dob_year, $dob_month, $dob_day) = ($client->date_of_birth // '') =~ /^(\d\d\d\d)-(\d\d)-(\d\d)$/;
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
    unless ($client->is_virtual) {
        # KYC/IDENTITY VERIFICATION SECTION
        $proveID = BOM::Platform::ProveID->new(
            client        => $client,
            search_option => 'ProveID_KYC'
        );
        my $user = BOM::Platform::User->new({email => $client->email});
        my @siblings = $user->clients(disabled_ok => 1);

        $show_uploaded_documents .= show_client_id_docs($_, show_delete => 1) for @siblings;
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
    $stateoptions .= qq|<option value="$_->{value}">$_->{text}</option>| for @$stateoptionlist;
    my $tnc_status = $client->get_status('tnc_approval');

    my @crs_tin_array = ();
    if (my $crs_tin_status = $client->get_status('crs_tin_information')) {
        my @dates = sort { Date::Utility->new($a)->epoch <=> Date::Utility->new($b)->epoch } split ",", $crs_tin_status->reason;
        for my $i (0 .. $#dates) {
            push @crs_tin_array, "Client submitted the TIN information Version " . ($i + 1) . " on " . $dates[$i];
        }
    }

    my $template_param = {
        client               => $client,
        client_phone_country => $client_phone_country,
        client_tnc_version   => $tnc_status ? $tnc_status->reason : '',
        countries            => \@countries,
        country_codes        => $country_codes,
        csr_tin_information  => \@crs_tin_array,
            dob_day_options  => $dob_day_options,
        dob_month_options      => $dob_month_options,
        dob_year_options       => $dob_year_options,
        financial_risk_status  => $client->get_status('financial_risk_approval'),
        has_social_signup      => defined $client->get_status('social_signup'),
        is_vip                 => $client->is_vip,
        lang                   => request()->language,
        language_options       => \@language_options,
        mifir_config           => $Finance::MIFIR::CONCAT::config,
        mrms_options           => \@mrms_options,
        promo_code_access      => $promo_code_access,
        proveID                => $proveID,
        secret_answer          => $secret_answer,
        self_exclusion_enabled => $self_exclusion_enabled,
        show_allow_omnibus => (not $client->is_virtual and $client->landing_company->short eq 'costarica' and not $client->sub_account_of) ? 1 : 0,
        show_funds_message => ($client->residence eq 'gb' and not $client->is_virtual) ? 1 : 0,
        show_risk_approval => ($client->landing_company->short eq 'maltainvest') ? 1 : 0,
        show_tnc_status => ($client->is_virtual) ? 0 : 1,
        show_uploaded_documents => $show_uploaded_documents,
        state_options           => set_selected_item($client->state, $stateoptions),
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
    foreach my $type (@{get_untrusted_types()}) {
        if (my $disabled = $client->get_status($type->{code})) {
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
            . '<th>SECTION</th>'
            . '<th>REASON</th>'
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
                . ';"><strong>WARNING : '
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

        $output .= '</table>';

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
    return (
        'Account closure',
        'Bonus code abuse',
        'Compact state probably',
        'Docs requested',
        'Fraudulent account',
        'Incomplete/false details',
        'Multiple accounts',
        'Multiple IPs',
        'Pending investigation',
        'Pending proof of age',
        'Others',
    );
}

## show_client_id_docs #######################################
# Purpose : generate the html to display client's documents.
# Relocated to here from Client module.
# If 'folder' arg present, this is a request to show docs from that folder.
# Otherwise it's a request to show the client's authentication docs.
##############################################################
sub show_client_id_docs {
    my ($client, %args) = @_;
    my $show_delete = $args{show_delete};
    my $folder      = $args{folder};
    my $links       = '';
    my $loginid     = $client->loginid;
    my @docs;
    if ($folder) {
        my $path = BOM::Platform::Runtime->instance->app_config->system->directory->db . "/clientIDscans/" . $client->broker . "/$folder";
        @docs = glob("$path/$loginid*");
        for (@docs) {
            s/\s/+/g;
            s/\&/%26/g;
        }
    } else {
        @docs = $client->client_authentication_document;
    }
    foreach my $doc (@docs) {
        my ($id, $document_file, $file_name, $download_file, $input);
        if ($folder) {
            $id            = 0;
            $document_file = $doc;
            ($file_name) = $document_file =~ m[clientIDscans/\w+/\w+/(.+)$];
            $download_file = $client->broker . "/$folder/$file_name";
            $input         = '';
        } else {
            $id            = $doc->id;
            $document_file = $doc->document_path;
            ($file_name) = $document_file =~ m[clientIDscans/\w+/(.+)$];
            $download_file = $client->broker . "/$file_name";
            my $date = $doc->expiration_date || '';
            $date = Date::Utility->new($date)->date_yyyymmdd if $date;
            my $comments    = $doc->comments;
            my $document_id = $doc->document_id;
            $input = qq{expires on <input type="text" style="width:100px" maxlength="15" name="expiration_date_$id" value="$date">};
            $input .= qq{comments <input type="text" style="width:100px" maxlength="20" name="comments_$id" value="$comments">};
            $input .= qq{document id <input type="text" style="width:100px" maxlength="20" name="document_id_$id" value="$document_id">};
        }
        my $file_size = -s $document_file || next;
        my $file_age  = int(-M $document_file);
        my $url       = request()->url_for("backoffice/download_document.cgi?path=$download_file");
        $links .= qq{<br/><a href="$url">$file_name</a>($file_size bytes, $file_age days old, $input)};
        if ($show_delete) {
            $url .= qq{&loginid=$loginid&doc_id=$id&deleteit=yes};
            my $onclick = qq{javascript:return confirm('Are you sure you want to delete $file_name?')};
            $links .= qq{[<a onclick="$onclick" href="$url">Delete</a>]};
        }
    }
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
        }];
}

1;

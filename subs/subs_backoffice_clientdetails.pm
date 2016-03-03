use strict 'vars';
use Encode;
use Carp qw( croak );

use Format::Util::Strings qw( set_selected_item );
use Date::Utility;
use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::Account;
use BOM::Platform::Client::Utility ();
use BOM::Database::DAO::Client;
use BOM::Platform::Context qw(request);
use BOM::Platform::Locale;
use BOM::Web::Form;

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
    my @mrms_options = BOM::Web::Form::GetSalutations();

    my ($dob_day, $dob_month, $dob_year);
    if ($client->date_of_birth =~ /^(\d\d\d\d)-(\d\d)-(\d\d)$/) {
        $dob_day   = $3;
        $dob_month = $2;
        $dob_year  = $1;

        $dob_day =~ s/^0//;
    }

    my $dob_day_optionlist = BOM::Web::Form::DOB_DayList($dob_day);
    my $dob_day_options;
    $dob_day_options .= qq|<option value="$_->{value}">$_->{value}</option>| for @$dob_day_optionlist;
    $dob_day_options = set_selected_item($dob_day, $dob_day_options);
    my $dob_month_options = set_selected_item(
        $dob_month,
        localize(
            '<option value=""></option><option value="01">Jan</option><option value="02">Feb</option><option value="03">Mar</option><option value="04">Apr</option><option value="05">May</option><option value="06">Jun</option><option value="07">Jul</option><option value="08">Aug</option><option value="09">Sep</option><option value="10">Oct</option><option value="11">Nov</option><option value="12">Dec</option>'
        ));
    my $dob_year_optionlist = BOM::Web::Form::DOB_YearList($dob_year);
    my $dob_year_options    = '<option value=""></option>';
    $dob_year_options .= qq|<option value="$_->{value}">$_->{value}</option>| for @$dob_year_optionlist;
    $dob_year_options = set_selected_item($dob_year, $dob_year_options);

    my @countries;
    my $country_codes = {};
    foreach my $country_name (sort BOM::Platform::Runtime->instance->countries->all_country_names) {
        push @countries, $country_name;
        $country_codes->{$country_name} = BOM::Platform::Runtime->instance->countries->code_from_country($country_name);
    }

    # KYC/IDENTITY VERIFICATION SECTION
    my $proveID = BOM::Platform::ProveID->new(
        client        => $client,
        search_option => 'ProveID_KYC'
    );
    my $checkID = BOM::Platform::ProveID->new(
        client        => $client,
        search_option => 'CheckID'
    );

    my $show_uploaded_documents = show_client_id_docs($client, show_delete => 1);

    # COMMUNICATION ADDRESSES
    my $client_phone_country = BOM::Platform::Runtime->instance->countries->code_from_phone($client->phone);
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

    my $template_param = {
        client                  => $client,
        self_exclusion_enabled  => $self_exclusion_enabled,
        lang                    => request()->language,
        mrms_options            => \@mrms_options,
        dob_day_options         => $dob_day_options,
        dob_month_options       => $dob_month_options,
        dob_year_options        => $dob_year_options,
        countries               => \@countries,
        country_codes           => $country_codes,
        proveID                 => $proveID,
        checkID                 => $checkID,
        show_uploaded_documents => $show_uploaded_documents,
        client_phone_country    => $client_phone_country,
        language_options        => \@language_options,
        secret_answer           => $secret_answer,
        promo_code_access       => $promo_code_access,
        is_vip                  => $client->is_vip,
        vip_since               => $client->vip_since,
        state_options           => set_selected_item($client->state, $stateoptions),
        show_funds_message      => ($client->residence eq 'gb' and not $client->is_virtual) ? 1 : 0,
        ukgc_funds_status       => $client->get_status('ukgc_funds_protection'),
        show_tnc_status => ($client->is_virtual) ? 0 : 1,
        tnc_approval_status => $tnc_status,
        client_tnc_version  => $tnc_status ? $tnc_status->reason : '',
    };

    BOM::Platform::Context::template->process('backoffice/client_edit.html.tt', $template_param, undef, {binmode => ':utf8'})
        || die BOM::Platform::Context::template->error();
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
    my $client   = BOM::Platform::Client->new({'loginid' => $login_id}) || return "<p>The Client's details can not be found [$login_id]</p>";
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
    if (my $disabled = $client->get_status('disabled')) {
        push(
            @output,
            {
                clerk      => $disabled->staff_name,
                reason     => $disabled->reason,
                warning    => 'red',
                section    => 'Disabled/Closed Accounts',
                editlink   => $edit_client_with_status->('disabledlogins'),
                removelink => $remove_client_from->('disabledlogins'),
            });
    }

    if (my $cashier_locked = $client->get_status('cashier_locked')) {
        push(
            @output,
            {
                clerk      => $cashier_locked->staff_name,
                reason     => $cashier_locked->reason,
                warning    => 'red',
                section    => 'Cashier Lock Section',
                editlink   => $edit_client_with_status->('lockcashierlogins'),
                removelink => $remove_client_from->('lockcashierlogins'),
            });
    }

    if (my $unwelcome = $client->get_status('unwelcome')) {
        push(
            @output,
            {
                clerk      => $unwelcome->staff_name,
                reason     => $unwelcome->reason,
                warning    => 'red',
                section    => 'Unwelcome loginIDs',
                editlink   => $edit_client_with_status->('unwelcomelogins'),
                removelink => $remove_client_from->('unwelcomelogins'),
            });
    }

    if (my $withdrawal_locked = $client->get_status('withdrawal_locked')) {
        push(
            @output,
            {
                clerk      => $withdrawal_locked->staff_name,
                reason     => $withdrawal_locked->reason,
                warning    => 'red',
                section    => 'Withdrawal Locked',
                editlink   => $edit_client_with_status->('lockwithdrawal'),
                removelink => $remove_client_from->('lockwithdrawal'),
            });
    }

    if (my $ok = $client->get_status('ok')) {
        my $onclick = "onclick='return append_dccode(this)'";
        push(
            @output,
            {
                clerk    => $ok->staff_name,
                reason   => $ok->reason,
                warning  => 'blue',
                section  => 'Add to OK Login',
                editlink => '<a href="'
                    . request()->url_for(
                    "backoffice/f_clientloginid.cgi",
                    {
                        trusted_action      => 'insert_data',
                        editlink            => 1,
                        login_id            => $login_id,
                        broker              => $broker,
                        trusted_action_type => 'oklogins'
                    })
                    . "\" $onclick>edit</a>",
                removelink => '<a href="'
                    . request()->url_for(
                    "backoffice/untrusted_client_edit.cgi",
                    {
                        trusted_action      => 'remove_data',
                        login_id            => $login_id,
                        broker              => $broker,
                        trusted_action_type => 'oklogins'
                    })
                    . "\" $onclick>remove</a>",
            });
    }

    # build the table
    my $output;
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
        my ($doc_id, $document_file, $file_name, $download_file, $input);
        if ($folder) {
            $doc_id        = 0;
            $document_file = $doc;
            ($file_name) = $document_file =~ m[clientIDscans/\w+/\w+/(.+)$];
            $download_file = $client->broker . "/$folder/$file_name";
            $input         = '';
        } else {
            $doc_id        = $doc->id;
            $document_file = $doc->document_path;
            ($file_name) = $document_file =~ m[clientIDscans/\w+/(.+)$];
            $download_file = $client->broker . "/$file_name";
            my $date = $doc->expiration_date || '';
            $date = Date::Utility->new($date)->date_ddmmmyyyy if $date;
            $input = qq{expires on <input type="text" style="width:100px" maxlength="15" name="expiration_date_$doc_id" value="$date">};
        }
        my $file_size = -s $document_file || next;
        my $file_age  = int(-M $document_file);
        my $url       = request()->url_for("backoffice/download_document.cgi?path=$download_file");
        $links .= qq{<br/><a href="$url">$file_name</a>($file_size bytes, $file_age days old, $input)};
        if ($show_delete) {
            $url .= qq{&loginid=$loginid&doc_id=$doc_id&deleteit=yes};
            my $onclick = qq{javascript:return confirm('Are you sure you want to delete $file_name?')};
            $links .= qq{[<a onclick="$onclick" href="$url">Delete</a>]};
        }
    }
    return $links;
}

## get_trusted_allow_login_reason ############################
# Purpose : all available trusted allowed login reason
##############################################################
sub get_trusted_allow_login_reason {
    return (
        'Client accessing from CDMA',
        'Client accessing from PDA or mobile',
        'Client\'s cashier section is locked or access denied',
        'Client\'s country is not in the allowed list',
        'Client is currently residing in country other than client\'s citizenship',
        'Client is fully authenticated',
        'Client is training under BOM gurus',
        'Client is travelling to other country',
        'Client login from a shared internet connection ( network, ISP, ADSL )',
        'Client login from internet cafe with shared IPs',
        'Client login from big proxies',
        'Client login from different IPs',
        'Client unable to access account and has no multiple accounts',
        'Client owned credit card issued by other country',
        'Client owned more than one account from different jurisidiction',
        'Multiple accounts with same IPs',
        'Received scanned documents from client',
        'Same IP but client only owned one account',
        'System recorded office IP when staff login using master password',
        'System triggered wrong IP',
        'System triggered wrong telephone or mobile',
        'System triggered wrong country code',
        'System error or bug',
        'Trusted or genuine client',
        'Test accounts',
        'Others',
    );
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

    my $db = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
        })->db;

    my $txn_dm = BOM::Database::DataMapper::Transaction->new({
        client_loginid => $client->loginid,
        currency_code  => $currency,
        db             => $db,
    });

    my $transactions = [];
    if (request()->param('depositswithdrawalsonly') eq 'yes') {
        $transactions = $txn_dm->get_payments({
            before => $before,
            after  => $after,
            limit  => $max_number_of_lines
        });
        foreach my $transaction (@{$transactions}) {
            $transaction->{balance_after} = $txn_dm->get_balance_after_transaction({transaction_time => $transaction->{transaction_time}});
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

1;

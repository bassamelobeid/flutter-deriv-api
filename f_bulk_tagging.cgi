#!/etc/rmg/bin/perl
package main;

=pod

=head1 DESCRIPTION

This script is kind of automative tool for self-tagging clients. It actually easify the
frustrative manuall process the marketing team used to do it for every individual affiliate

=cut

use strict;
use warnings;
use f_brokerincludeall;
use BOM::User::Client;
use Syntax::Keyword::Try;
use CGI;
use Text::CSV;
use BOM::User;

use constant {
    DOCUMENT_SIZE_LIMIT_IN_BYTES => 20 * 1024 * 1024,    # 20 MB
    DOCUMENT_SIZE_LIMIT_IN_MB    => 20
};

BOM::Backoffice::Sysinit::init();

sub update_affiliate_token_for_all_sibling_accounts {
    my ($affiliate_token, $email) = @_;
    my $user;

    # Updates that apply to both active client and its corresponding clients
    try {
        $user = BOM::User->new(email => $email);
        foreach my $client ($user->clients) {
            $client->myaffiliates_token($affiliate_token);
            my $client_loginid = $client->loginid;
            if (not $client->save) {
                code_exit_BO("<p class=\"error\">ERROR : Could not update client details for $client_loginid </p></p>");
            }
            print "<p class=\"success\">Client " . $client_loginid . " saved</p>";    # Corrected the variable name
        }
    } catch ($e) {
        $log->warnf("Error when getting user with email $email. More detail: %s", $e);
    }
}

my $q = CGI->new;

my $input                   = request()->params;
my $broker_code             = $input->{client_type} // 'CR';
my $clerk                   = BOM::Backoffice::Auth::get_staffname();
my $client_db               = BOM::Database::ClientDB->new({broker_code => $broker_code})->db->dbic->dbh;
my $show_success_message    = 0;
my $number_of_rows          = 0;
my $number_of_rows_affected = 0;

PrintContentType();

my $prev_dcc = $input->{DCcode} // '';

my $self_post = request()->url_for('backoffice/f_bulk_tagging.cgi');

BrokerPresentation("Bulk Tagging Tool");

if ($q->request_method() eq 'POST') {
    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => 'BULKTAGGING'
        })->validate_self_tagging_control_code($input->{DCcode});
    code_exit_BO(_get_display_error_message("ERROR: " . $dcc_error->get_mesg())) if $dcc_error;

    my $batch_file = ref $input->{csv_file_field} eq 'ARRAY' ? trim($input->{csv_file_field}->[0]) : trim($input->{csv_file_field});
    code_exit_BO(_get_display_error_message("ERROR: $batch_file: only csv files allowed\n")) unless $batch_file =~ /(csv)$/i;
    code_exit_BO(_get_display_error_message("ERROR: " . encode_entities($batch_file) . " is too large."))
        if $ENV{CONTENT_LENGTH} > (DOCUMENT_SIZE_LIMIT_IN_BYTES);

    $CGI::POST_MAX = DOCUMENT_SIZE_LIMIT_IN_BYTES;

    if ($q->param('csv_file_field')) {
        my $csv_file_handle = $q->upload('csv_file_field');
        my $csv             = Text::CSV->new({binary => 1}) or die "Cannot use CSV: " . Text::CSV->error_diag();
        my $header          = $csv->getline($csv_file_handle);
        my %holder;
        chomp(@$header);
        my ($first_column, $second_column) = @$header;
        if ($first_column eq "Email" && $second_column eq "New Token") {
            while (my $row = $csv->getline($csv_file_handle)) {
                chomp(@$row);
                $number_of_rows += 1;
                my ($email, $new_token) = @$row;
                update_affiliate_token_for_all_sibling_accounts($new_token, $email);
            }
            $show_success_message = 1;

        } else {
            code_exit_BO(
                _get_display_error_message("ERROR: CSV file headers are incorrect. They should be 3 columns named in order: Email|New Token"));

        }

    }

}

BOM::Backoffice::Request::template()->process(
    'backoffice/self_tagging.html.tt',
    {
        prev_dcc                => $prev_dcc,
        document_size_limit     => DOCUMENT_SIZE_LIMIT_IN_MB,
        self_post               => $self_post,
        show_success_message    => $show_success_message,
        number_of_rows          => $number_of_rows,
        number_of_rows_affected => $number_of_rows_affected,
    });

code_exit_BO();

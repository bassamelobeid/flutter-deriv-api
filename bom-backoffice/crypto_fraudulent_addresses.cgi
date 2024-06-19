#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Text::Trim qw(trim);
use f_brokerincludeall;
use JSON::MaybeUTF8               qw(decode_json_utf8);
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel );
use BOM::Backoffice::Sysinit      ();
use BOM::Cryptocurrency::BatchAPI;
BOM::Backoffice::Sysinit::init();
use POSIX;

use constant ROWS_LIMIT => 30;

=head2 get_trimmed_param

remove white spaces from the parameter received in the request

=over 4

=item * C<param> string to be trimmed

=back

return trimmed string or undef for empty values

=cut

sub get_trimmed_param {
    my $param = shift;
    $param = trim($param);
    return undef unless length $param;
    return $param;
}

my @batch_requests;

my $type = request()->param('type');

my $blocked_list;
my $search    = 0;
my $page      = 1;
my $max_pages = 1;

my $fraud_address   = get_trimmed_param(request()->param('fraud_address'));
my $fraud_loginid   = get_trimmed_param(request()->param('fraud_loginid'));
my $fraud_from_date = get_trimmed_param(request()->param('fraud_from_date'));
my $fraud_to_date   = get_trimmed_param(request()->param('fraud_to_date'));
my $dh_to           = undef;
$dh_to = Date::Utility->new($fraud_to_date)->plus_time_interval('1d')->datetime if $fraud_to_date;

if ($type && $type eq "search") {
    $page   = request()->param('page');
    $search = 1;
    my $offset = ($page - 1) * ROWS_LIMIT;

    push @batch_requests,
        {
        id     => 'list',
        action => 'address/get_blocked_list',
        body   => {
            address    => $fraud_address,
            date_start => $fraud_from_date,
            date_end   => $dh_to,
            loginid    => $fraud_loginid,
            limit      => ROWS_LIMIT,
            offset     => $offset,
        },
        };
} elsif ($type && $type eq "export") {
    PrintContentType_excel('fraud_addresses.csv');

    my $max_pages_csv = request->param('max_pages');
    my $limit_csv     = $max_pages_csv * ROWS_LIMIT;
    my $batch         = BOM::Cryptocurrency::BatchAPI->new();
    $batch->add_request(
        id     => 'export',
        action => 'address/get_blocked_list',
        body   => {
            address    => $fraud_address,
            date_start => $fraud_from_date,
            date_end   => $dh_to,
            loginid    => $fraud_loginid,
            limit      => $limit_csv,
            offset     => 0,
        },
    );
    my $csv_data = $batch->process()->[0]{body}{address_list};

    my $csv = Text::CSV->new({
            binary       => 1,
            always_quote => 1,
            quote_char   => '"',
            eol          => "\n"
        })    # should set binary attribute.
        or die "Cannot use CSV: " . Text::CSV->error_diag();

    my @header = (
        "Fraudulent address",
        "Currency",
        "Report count",
        "Login ID",
        "Investigation remarks",
        "Blocked",
        "Last update date",
        "Staff",
        "Creation date",
        "Categories"
    );
    $csv->combine(@header);
    print $csv->string;

    for my $row ($csv_data->@*) {
        my @row_array = (
            $row->{address},               $row->{currency_code}, $row->{address_report_count}, $row->{client_loginid},
            $row->{investigation_remarks}, $row->{is_blocked},    $row->{last_status_date},     $row->{last_status_update_by},
            $row->{insert_date},           $row->{categories});
        $csv->combine(@row_array);
        print $csv->string;
    }

    code_exit_BO();
}

PrintContentType();
BrokerPresentation("Crypto Fraudulent Addresses Extended Information");

if (my $updated_addresses = request()->param('updated_addresses')) {
    $updated_addresses = decode_json_utf8($updated_addresses);

    my @address_list;
    foreach my $address_info ($updated_addresses->@*) {
        push @address_list,
            {
            address    => $address_info->{address},
            is_blocked => $address_info->{is_blocked},
            remark     => $address_info->{remark},
            };
    }

    unshift @batch_requests, {    # To be processed first
        id     => 'update',
        action => 'address/set_blocked_bulk',
        body   => {
            address_list => [@address_list],
            staff_name   => BOM::Backoffice::Auth::get_staffname(),
        },
    };
}

if (@batch_requests) {
    my $batch = BOM::Cryptocurrency::BatchAPI->new();
    $batch->add_request($_->%*) for @batch_requests;
    $batch->process();

    $blocked_list = $batch->get_response_body('list')->{address_list};

    # Set successful update for displaying
    if (my $update_response = $batch->get_response_body('update')) {
        my %updated_successfully = map { $_->{address} => $_->{is_success} } $update_response->{address_list}->@*;
        for my $address_info ($blocked_list->@*) {
            $address_info->{has_updated} = 1 if $updated_successfully{$address_info->{address}};
        }
    }

    # Check and set the pagination limit
    if (scalar $blocked_list->@* > 0) {
        my $total_rows = ($blocked_list->@*)[0]->{total_count};
        $max_pages = POSIX::ceil($total_rows / ROWS_LIMIT);
    }
}

Bar('CRYPTO FRAUDULENT ADDRESSES');

BOM::Backoffice::Request::template()->process(
    'backoffice/crypto_fraudulent_addresses.html.tt',
    {
        is_update => request()->param('updated_addresses') ? 1 : 0,
        data_url  => request()->url_for('backoffice/crypto_fraudulent_addresses.cgi'),
        data      => $blocked_list,
        search    => $search,
        page      => $page,
        max_pages => $max_pages,
        from_date => $fraud_from_date,
        to_date   => $fraud_to_date,
        loginid   => $fraud_loginid,
        address   => $fraud_address,
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

code_exit_BO();

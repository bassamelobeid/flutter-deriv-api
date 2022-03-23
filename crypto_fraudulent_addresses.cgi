#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Text::Trim qw(trim);
use f_brokerincludeall;
use BOM::CTC::Database;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel );
use BOM::Backoffice::Sysinit ();
use BOM::Config;
BOM::Backoffice::Sysinit::init();
use POSIX;

use constant ROWS_LIMIT => 30;

our $currency_switch;

sub _get_currency_object {
    my $currency = shift;
    return $currency_switch->{$currency} //= BOM::CTC::Currency->new(currency_code => $currency);
}

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

my $type       = request()->param('type');
my $today_date = Date::Utility->new()->datetime_yyyymmdd_hhmmss;
my $post_data;

my $db = BOM::CTC::Database->new();
my $data;
my $search    = 0;
my $page      = 1;
my $max_pages = 1;
my %args;

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

    $data = $db->list_blacklist_associated_addresses($fraud_address, $fraud_loginid, $fraud_from_date, $dh_to, ROWS_LIMIT, $offset);

    # check and set the pagination limit
    if (scalar $data->@* > 0) {
        my $total_rows = ($data->@*)[0]->{total_count};
        $max_pages = POSIX::ceil($total_rows / ROWS_LIMIT);
    }
} elsif ($type && $type eq "export") {
    PrintContentType_excel('fraud_addresses.csv');

    my $max_pages_csv = request->param('max_pages');
    my $limit_csv     = $max_pages_csv * ROWS_LIMIT;
    my $csv_data      = $db->list_blacklist_associated_addresses($fraud_address, $fraud_loginid, $fraud_from_date, $dh_to, $limit_csv, 0);

    my $csv = Text::CSV->new({
            binary       => 1,
            always_quote => 1,
            quote_char   => '"',
            eol          => "\n"
        })    # should set binary attribute.
        or die "Cannot use CSV: " . Text::CSV->error_diag();

    my @header = (
        "address",               "currency_code", "address_report_count", "client_loginid",
        "investigation_remarks", "blocked",       "last_status_date",     "last_status_update_by",
        "timestamp"
    );
    $csv->combine(@header);
    print $csv->string;

    for my $row ($csv_data->@*) {
        my @row_array = (
            $row->{address},          $row->{currency_code},         $row->{address_report_count},
            $row->{client_loginid},   $row->{investigation_remarks}, $row->{blocked},
            $row->{last_status_date}, $row->{last_status_update_by}, $row->{tmstmp});
        $csv->combine(@row_array);
        print $csv->string;
    }

    code_exit_BO();
}

PrintContentType();
BrokerPresentation("Crypto Fraudulent Addresses Extended Information");

if (request()->param('json_data')) {
    $post_data = decode_json_utf8(request()->param('json_data'));

    foreach my $post_args (@{$post_data}) {
        %args = (
            remark     => $post_args->{remark},
            blocked    => $post_args->{blocked},
            address    => $post_args->{address},
            today_date => $today_date,
            staff_name => BOM::Backoffice::Auth0::get_staffname(),
        );

        $db->update_blacklist_addresses_bo(%args);
    }
}

# this is to create the link for each fraud address
foreach my $row ($data->@*) {
    my @currencies = split(',', $row->{currency_code});
    # we don't really care about the currency order here, any of them
    # will bring an effective provider so we can use the first one as parameter
    my $currency = _get_currency_object($currencies[0]);

    $row->{link} = sprintf("%s/%s", $currency->get_AML_config->{report_url}, $row->{address});
}

Bar('CRYPTO FRAUDULENT ADDRESSES');

BOM::Backoffice::Request::template()->process(
    'backoffice/crypto_fraudulent_addresses.html.tt',
    {
        data_url  => request()->url_for('backoffice/crypto_fraudulent_addresses.cgi'),
        data      => $data,
        search    => $search,
        page      => $page,
        max_pages => $max_pages,
        from_date => $fraud_from_date,
        to_date   => $fraud_to_date,
        loginid   => $fraud_loginid,
        address   => $fraud_address,
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

code_exit_BO();

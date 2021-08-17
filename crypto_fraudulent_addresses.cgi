#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use f_brokerincludeall;
use BOM::CTC::Database;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Config;
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Crypto Fraudulent Addresses Extended Information");

=head2 config

Returns the third party API config.

=cut

sub _config {
    my $currency_code = shift;
    return BOM::Config::crypto()->{$currency_code}->{thirdparty_api}->{fraud};
}

my $s_address  = request()->param('s_address');
my $loginid    = request()->param('loginid');
my $type       = request()->param('type');
my $today_date = Date::Utility->new()->datetime_yyyymmdd_hhmmss;
my $post_data;

my $db = BOM::CTC::Database->new();
my $data;
my %args;

if ($type && $type eq "search") {

    $data = $db->list_blacklist_associated_addresses($s_address, $loginid);

} elsif ($type && $type eq "search_all") {

    $data = $db->list_blacklist_associated_addresses();

}

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

# this is to create the link for each address
# currently only works on BTC|LTC|UST addresses
foreach my $row ($data->@*) {
    my $currency_code = $row->{currency_code};
    $currency_code = "BTC" if $currency_code =~ m/BTC|LTC|UST/sg;

    $row->{link} = sprintf("%s/%s", _config($currency_code)->{report_url}, $row->{address});
}

Bar('CRYPTO FRAUDULENT ADDRESSES');

BOM::Backoffice::Request::template()->process(
    'backoffice/crypto_fraudulent_addresses.html.tt',
    {
        data_url => request()->url_for('backoffice/crypto_fraudulent_addresses.cgi'),
        data     => $data,
        search   => 1,
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

code_exit_BO();

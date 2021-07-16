package BOM::Backoffice::ExperianBalance;
use strict;
use warnings;

my $urls = {
    login_page   => 'https://proveid.experian.com/signin/',
    login_post   => 'https://proveid.experian.com/signin/onsignin.cfm',
    logoff_page  => 'https://proveid.experian.com/signin/signoff.cfm',
    balance_page => 'https://proveid.experian.com/preferences/index.cfm',
};

=head2 _die_if_error

This fuction gets an HTTP response and if there's any error in headers or content, throws an exception.
It has three arguments:

=over 4

=item * C<title>: A string that will appear in the begining of exception messages (in order to be able to know which step has failed by looking at the logs)

=item * C<tx>: An HTML response object

=back

=cut

sub _die_if_error {
    my ($title, $tx) = @_;

    if (my $error = $tx->error) {
        die "$title failed with error: $error->{code} $error->{message}";
    } else {
        my $error_node = $tx->result->dom->at('div[class=errmsg]');
        return 1 unless $error_node;

        die "$title failed with error: " . ($error_node->all_text =~ s/\s+/ /gr);
    }

    return 1;

}

=head2 get_balance

Retruns the balance of our Experian account.

=over 4

=item * C<ua>: An HTML user agent

=item * C<login>: company's Experian user name

=item * C<password>: company's Experian password

=back

=cut

sub get_balance {
    my ($ua, $login, $password) = @_;

    my $tx = $ua->get($urls->{login_page});
    _die_if_error('Load Experian login page', $tx);

    my $csrf = eval { $tx->result->dom->at('input[name=_CSRF_token]')->attr('value') };
    die "Experian CSRF token not found" unless $csrf;
    $tx = $ua->post(
        $urls->{login_post} => form => {
            _CSRF_token => $csrf,
            login       => $login,
            password    => $password,
            btnSubmit   => 'Login'
        });

    _die_if_error('Experian login', $tx);

    $tx = $ua->get($urls->{balance_page});
    _die_if_error('Load Experian balance page', $tx);

    $ua->get($urls->{logoff_page});

    my $result_list = $tx->result->dom->find('[ResultList clearfix]');
    die 'Balance not found in the HTML' unless $result_list;

    my $r = $result_list->map('text')->join("");
    (my $used)  = $r =~ /Credits Used: (\d+)/;
    (my $limit) = $r =~ /Credits Limit: (\d+)/;

    return ($used, $limit);
}

1;

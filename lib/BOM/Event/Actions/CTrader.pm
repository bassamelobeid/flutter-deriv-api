package BOM::Event::Actions::CTrader;

use strict;
use warnings;

no indirect;

use BOM::Config;
use BOM::TradingPlatform;
use BOM::Database::CommissionDB;
use BOM::User::Client;
use WebService::MyAffiliates;
use Log::Any qw($log);

=head2 ctrader_account_created

Series of operation to perform for newly created ctrader acccount.

=over 4

=item * C<loginid> - BOM client instance's loginid

=item * C<binary_user_id> - User account's binary user id

=item * C<ctid_userid> - CTID of cTrader

=item * C<account_type> - Account type. Example: [real, demo]

=back

=cut

sub ctrader_account_created {
    my $params = shift;

    die 'Loginid needed'        unless $params->{loginid};
    die 'Binary user id needed' unless $params->{binary_user_id};
    die 'CTID UserId needed'    unless $params->{ctid_userid};
    die 'Account type needed'   unless $params->{account_type};

    my $myaffiliates_config = BOM::Config::third_party()->{myaffiliates};
    my $aff_webservice      = WebService::MyAffiliates->new(
        user    => $myaffiliates_config->{user},
        pass    => $myaffiliates_config->{pass},
        host    => $myaffiliates_config->{host},
        timeout => 10
    );

    my $db             = BOM::Database::CommissionDB::rose_db();
    my $affiliate_data = $db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                q{SELECT binary_user_id, external_affiliate_id FROM affiliate.affiliate WHERE binary_user_id=?},
                {Slice => {}},
                $params->{binary_user_id});
        });

    if ($affiliate_data) {
        for my $affiliate (@$affiliate_data) {
            my $aff_id         = $affiliate->{external_affiliate_id};
            my $affiliate_user = $aff_webservice->get_user($aff_id);
            if ($affiliate_user->{STATUS} eq 'accepted') {
                my $client = BOM::User::Client->new({loginid => $params->{loginid}});
                my $ct     = BOM::TradingPlatform->new(
                    platform => 'ctrader',
                    client   => $client
                );

                $ct->register_partnerid({
                        partnerid    => $params->{binary_user_id},
                        ctid_userid  => $params->{ctid_userid},
                        account_type => $params->{account_type}});
            }
        }
    }

    return 1;
}

1;

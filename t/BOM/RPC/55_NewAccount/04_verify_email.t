use strict;
use warnings;
use BOM::Test::Helper::Client qw( create_client );
use Test::More;
use BOM::User::Password;
use BOM::RPC::v3::NewAccount;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;

subtest 'Do not send verification when Impersonating' => sub {

    my $cr_client = create_client('CR');
    my $user      = BOM::User->create(
        email    => 'unit_test@binary.com',
        password => 'asdasd'
    );
    $user->add_client($cr_client);
    $cr_client->account('USD');

    my $oauth_model = BOM::Database::Model::OAuth->new;

    my $bo_app = $oauth_model->create_app({
        name         => 'App internal',
        scopes       => ['read', 'admin'],
        user_id      => 9999,
        redirect_uri => 'https://www.example.com',
        active       => 1
    });

    my $sql = 'INSERT INTO  oauth.official_apps VALUES (?, true, true)';
    $oauth_model->dbic->dbh->do($sql, undef, $bo_app->{app_id});
    my ($backoffice_access_token) = $oauth_model->store_access_token_only($bo_app->{app_id}, $cr_client->loginid);
    my $result = BOM::RPC::v3::NewAccount::verify_email({
            token => $backoffice_access_token,
            args  => {
                type         => "payment_withdraw",
                verify_email => 'unit_test@binary.com'
            },
            token_details => {loginid => $cr_client->loginid},
            language      => 'en',
            source        => 1,
        });
    is($result->{error}->{code}, 'Permission Denied', 'Received Correct code when Impersonating');
    is($result->{error}->{message_to_client}, "You can not perform a withdrawal while impersonating an account");

    # binary.com  app_id is 1
    my $binary_app = $oauth_model->get_app(1, 1);

    my ($binary_com_access_token) = $oauth_model->store_access_token_only($binary_app->{app_id}, $cr_client->loginid);
    $result = BOM::RPC::v3::NewAccount::verify_email({
            token => $binary_com_access_token,
            args  => {
                type         => "payment_withdraw",
                verify_email => 'unit_test@binary.com'
            },
            token_details => {loginid => $cr_client->loginid},
            language      => 'en',
            source        => 1,
        });

    ok(!defined($result->{error}), 'No Error when Not impersonating');

};

done_testing;

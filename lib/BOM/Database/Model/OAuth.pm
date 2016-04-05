package BOM::Database::Model::OAuth;

use Moose;
use Date::Utility;
use String::Random ();
use Try::Tiny;
use List::MoreUtils qw(uniq);
use BOM::Database::AuthDB;

has 'dbh' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbh {
    return BOM::Database::AuthDB::rose_db->dbh;
}

sub __parse_array {
    my ($array_string) = @_;
    return $array_string if ref($array_string) eq 'ARRAY';
    return [] unless $array_string;
    return BOM::Database::AuthDB::rose_db->parse_array($array_string);
}

my @token_scopes = ('read', 'trade', 'payments', 'admin');
my %available_scopes = map { $_ => 1 } @token_scopes;

sub __filter_valid_scopes {
    my (@s) = @_;
    return grep { $available_scopes{$_} } @s;
}

## app
sub verify_app {
    my ($self, $app_id) = @_;

    my $app = $self->dbh->selectrow_hashref("
        SELECT id, name, redirect_uri, scopes FROM oauth.apps WHERE id = ? AND active
    ", undef, $app_id);
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub confirm_scope {
    my ($self, $app_id, $loginid) = @_;

    my $dbh = $self->dbh;

    my ($is_exists, $exists_scopes) = $dbh->selectrow_array("
        SELECT true FROM oauth.user_scope_confirm WHERE app_id = ? AND loginid = ?
    ", undef, $app_id, $loginid);
    unless ($is_exists) {
        $dbh->do("INSERT INTO oauth.user_scope_confirm (app_id, loginid) VALUES (?, ?)", undef, $app_id, $loginid);
    }

    return 1;
}

sub is_scope_confirmed {
    my ($self, $app_id, $loginid) = @_;

    return 1 if $app_id eq 'binarycom';    # our app is all confirmed

    my ($confirmed_scopes) = $self->dbh->selectrow_array("
        SELECT true FROM oauth.user_scope_confirm WHERE app_id = ? AND loginid = ?
    ", undef, $app_id, $loginid);

    return $confirmed_scopes ? 1 : 0;
}

sub store_access_token_only {
    my ($self, $app_id, $loginid) = @_;

    my $dbh          = $self->dbh;
    my $expires_in   = 86400;                                                     # for one day
    my $access_token = 'a1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;
    $dbh->do("INSERT INTO oauth.access_token (access_token, app_id, loginid, expires) VALUES (?, ?, ?, ?)",
        undef, $access_token, $app_id, $loginid, $expires_time);

    return ($access_token, $expires_in);
}

sub get_loginid_by_access_token {
    my ($self, $token) = @_;

    ## extends access token expires
    my $expires_in = 86400;
    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;

    return $self->dbh->selectrow_array("
        UPDATE oauth.access_token
        SET last_used=NOW(), expires=?
        WHERE access_token = ? AND expires > NOW()
        RETURNING loginid, creation_time
    ", undef, $expires_time, $token);
}

sub get_scopes_by_access_token {
    my ($self, $access_token) = @_;

    my $sth = $self->dbh->prepare("
        SELECT app.scopes FROM oauth.access_token at
        JOIN oauth.apps app ON app.id=at.app_id
        WHERE access_token = ?
    ");
    $sth->execute($access_token);
    my $scopes = $sth->fetchrow_array;
    $scopes = __parse_array($scopes);
    return @$scopes;
}

sub is_name_taken {
    my ($self, $user_id, $name) = @_;

    return $self->dbh->selectrow_array("SELECT 1 FROM oauth.apps WHERE binary_user_id = ? AND name = ?", undef, $user_id, $name);
}

sub create_app {
    my ($self, $app) = @_;

    my $id = $app->{id} || 'id-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

    my $sth = $self->dbh->prepare("
        INSERT INTO oauth.apps
            (id, name, scopes, homepage, github, appstore, googleplay, redirect_uri, binary_user_id)
        VALUES
            (? ,?, ?, ?, ?, ?, ?, ?, ?)
    ");
    $sth->execute(
        $id,
        $app->{name},
        $app->{scopes},
        $app->{homepage}     || '',
        $app->{github}       || '',
        $app->{appstore}     || '',
        $app->{googleplay}   || '',
        $app->{redirect_uri} || '',
        $app->{user_id});

    return {
        app_id       => $id,
        name         => $app->{name},
        scopes       => $app->{scopes},
        redirect_uri => $app->{redirect_uri},
    };
}

sub get_app {
    my ($self, $user_id, $app_id) = @_;

    my $app = $self->dbh->selectrow_hashref("
        SELECT id as app_id, name, redirect_uri, scopes FROM oauth.apps WHERE id = ? AND binary_user_id = ? AND active
    ", undef, $app_id, $user_id);
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub get_apps_by_user_id {
    my ($self, $user_id) = @_;

    my $apps = $self->dbh->selectall_arrayref("
        SELECT
            id as app_id, name, redirect_uri, scopes
        FROM oauth.apps WHERE binary_user_id = ? AND active ORDER BY name
    ", {Slice => {}}, $user_id);
    return [] unless $apps;

    foreach (@$apps) {
        $_->{scopes} = __parse_array($_->{scopes});
    }

    return $apps;
}

sub delete_app {
    my ($self, $user_id, $app_id) = @_;

    my $app = $self->get_app($user_id, $app_id);
    return 0 unless $app;

    my $dbh = $self->dbh;

    ## delete real delete
    foreach my $table ('user_scope_confirm', 'access_token') {
        $dbh->do("DELETE FROM oauth.$table WHERE app_id = ?", undef, $app_id);
    }

    $dbh->do("DELETE FROM oauth.apps WHERE id = ?", undef, $app_id);

    return 1;
}

sub get_used_apps_by_loginid {
    my ($self, $loginid) = @_;

    my $apps = $self->dbh->selectall_arrayref("
        SELECT
            u.app_id, name, a.scopes
        FROM oauth.apps a JOIN oauth.user_scope_confirm u ON a.id=u.app_id
        WHERE loginid = ? AND a.active ORDER BY a.name
    ", {Slice => {}}, $loginid);
    return [] unless $apps;

    my $get_last_used_sth = $self->dbh->prepare("
        SELECT MAX(last_used)::timestamp(0) FROM oauth.access_token WHERE app_id = ?
    ");

    foreach (@$apps) {
        $_->{scopes} = __parse_array($_->{scopes});
        $get_last_used_sth->execute($_->{app_id});
        $_->{last_used} = $get_last_used_sth->fetchrow_array;
    }

    return $apps;
}

sub revoke_app {
    my ($self, $app_id, $loginid) = @_;

    my $dbh = $self->dbh;
    foreach my $table ('user_scope_confirm', 'access_token') {
        $dbh->do("DELETE FROM oauth.$table WHERE app_id = ? AND loginid = ?", undef, $app_id, $loginid);
    }

    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

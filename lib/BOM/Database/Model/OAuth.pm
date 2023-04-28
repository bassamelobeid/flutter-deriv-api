package BOM::Database::Model::OAuth;

use Moose;
use Date::Utility;
use BOM::Database::AuthDB;
use Carp qw(croak);

use constant {
    TOKEN_GENERATION_ATTEMPTS => 5,
    REFRESH_TOKEN_LENGTH      => 29,
    REFRESH_TOKEN_TIMEOUT     => 60 * 60 * 24 * 60,    # 60 days.
    CTRADER_TOKEN_LENGTH      => 29,
    CTRADER_TOKEN_TTL         => 60 * 60 * 24 * 60,
};

has 'dbic' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbic {
    return BOM::Database::AuthDB::rose_db()->dbic;
}

sub __parse_array {
    my ($array_string) = @_;
    return $array_string if ref($array_string) eq 'ARRAY';
    return [] unless $array_string;
    return BOM::Database::AuthDB::rose_db()->parse_array($array_string);
}

my @token_scopes     = ('read', 'trade', 'payments', 'admin');
my %available_scopes = map { $_ => 1 } @token_scopes;

sub __filter_valid_scopes {
    my (@s) = @_;
    return grep { $available_scopes{$_} } @s;
}

## app
sub verify_app {
    my ($self, $app_id) = @_;

    return unless $app_id =~ /^[0-9]+$/ && $app_id < sprintf("%.0f", 2**63);    # upper range of Postgres BIGINT

    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("
        SELECT id, name, redirect_uri, scopes, app_markup_percentage, bypass_verification, secret, verification_uri FROM oauth.apps WHERE id = ? AND active
    ", undef, $app_id);
        });
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

=head2 get_names_by_app_id($app_id)

Get Names by App ID

Takes in either an arrayref or a single integer and returns a hash of the ID(s) passed in and their respective names.

=cut

sub get_names_by_app_id {
    my ($self, $app_id) = @_;

    $app_id = [$app_id] unless ref $app_id eq 'ARRAY';
    # We may be called with a large number of duplicates by code that maps transactions to the app_id source. We filter those out here to reduce a tiny bit of database load and also keep debugging output more readable when tracing the SQL queries.
    $app_id = [List::Util::uniq(@$app_id)];

    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectall_hashref("SELECT * FROM oauth.get_app_names(?)", "id", undef, $app_id);
        });

    $app = {map { $_ => $app->{$_}->{name} } keys %$app};

    return $app;
}

=head2 add_official_app

add an app_id to official_apps table

=over 4

=item * C<app_id> - application ID

=item * C<is_primary> - is primary website

=item * C<is_internal> - is internal 

=back

Return app_id and is_primary_website and is_internal

=cut

sub add_official_app {
    my ($self, $app_id, $is_primary, $is_internal) = @_;

    my $result = $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
        INSERT INTO oauth.official_apps
            (app_id, is_primary_website, is_internal)
        VALUES
            (?, ?, ?)
        RETURNING * ");
            $sth->execute($app_id, $is_primary, $is_internal || 0,);

            return $sth->fetchrow_hashref();
        });

    return $result;
}

=head2 is_official_app

Checks if the app is among official

=over 4

=item * C<app_id> - application ID

=back

Returns true if the app is present in official_apps table

=cut

sub is_official_app {
    my ($self, $app_id) = @_;

    return 0 unless $app_id and $app_id =~ /^\d+$/;

    my ($is_official) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT EXISTS(SELECT 1 FROM oauth.official_apps WHERE app_id = ?)", undef, $app_id);
        });

    return $is_official ? 1 : 0;
}

=head2 is_primary_website

Checks if the app is among official apps and is a primary website.

=over 4

=item * C<app_id> - application ID

=back

Returns true if the app is official and primary.

=cut

sub is_primary_website {
    my ($self, $app_id) = @_;

    return 0 unless $app_id and $app_id =~ /^\d+$/;

    my ($is_primary_website) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("
        SELECT is_primary_website FROM oauth.official_apps WHERE app_id = ?
    ", undef, $app_id);
        });

    return $is_primary_website ? 1 : 0;
}

=head2 is_internal

Checks if the app is an internal App like Backoffice.  
Currently only used to check if authentication is from impersonation.  

=over 4

=item * C<app_id> - application ID

=back

Returns true if the app is an internal one false otherwise.  

=cut

sub is_internal {
    my ($self, $app_id) = @_;

    return 0 unless $app_id and $app_id =~ /^\d+$/;

    my ($is_internal) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("
        SELECT is_internal FROM oauth.official_apps WHERE app_id = ?
    ", undef, $app_id);
        });

    return $is_internal;
}

sub confirm_scope {
    my ($self, $app_id, $loginid) = @_;

    $self->dbic->run(
        ping => sub {
            $_->selectrow_array("
        SELECT true FROM oauth.user_scope_confirm WHERE app_id = ? AND loginid = ?
    ", undef, $app_id, $loginid)
                or $_->do("INSERT INTO oauth.user_scope_confirm (app_id, loginid) VALUES (?, ?)", undef, $app_id, $loginid);
        });
    return 1;
}

sub is_scope_confirmed {
    my ($self, $app_id, $loginid) = @_;

    my ($confirmed_scopes) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("
        SELECT true FROM oauth.user_scope_confirm WHERE app_id = ? AND loginid = ?
    ", undef, $app_id, $loginid);
        });

    return $confirmed_scopes ? 1 : 0;
}

sub store_access_token_only {
    my ($self, $app_id, $loginid, $ua_fingerprint) = @_;
    return $self->dbic->run(fixup =>
            sub { $_->selectrow_array("SELECT * FROM oauth.create_token(29, ?, ?, '60d'::INTERVAL, ?)", undef, $app_id, $loginid, $ua_fingerprint) });
}

sub get_token_details {
    my ($self, $token) = @_;

    my $expires_in = '60 days';

    my $details = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref(<<'SQL', undef, $token, $expires_in) });
SELECT loginid, creation_time, ua_fingerprint, scopes
  FROM oauth.get_token_details($1, $2::INTERVAL)
SQL
    $details->{scopes} = __parse_array($details->{scopes});

    return $details;
}

sub get_verification_uri_by_app_id {
    my ($self, $app_id) = @_;

    my ($verification_uri) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("
        SELECT verification_uri FROM oauth.apps WHERE id = ? AND active
    ", undef, $app_id);
        });

    return $verification_uri;
}

sub get_scopes_by_access_token {
    my ($self, $access_token) = @_;

    my $scopes = $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
        SELECT app.scopes FROM oauth.access_token at
        JOIN oauth.apps app ON app.id=at.app_id
        WHERE access_token = ?
    ");
            $sth->execute($access_token);
            return $sth->fetchrow_array;
        });
    $scopes = __parse_array($scopes);
    return @$scopes;
}

sub is_name_taken {
    my ($self, $user_id, $name) = @_;

    return $self->dbic->run(
        fixup => sub { $_->selectrow_array("SELECT 1 FROM oauth.apps WHERE binary_user_id = ? AND name = ?", undef, $user_id, $name) });
}

sub create_app {
    my ($self, $app) = @_;

    my $result = $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
        INSERT INTO oauth.apps
            (name, scopes, homepage, github, appstore, googleplay, redirect_uri, verification_uri, app_markup_percentage, binary_user_id)
        VALUES
            (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING * ");
            $sth->execute(
                $app->{name},
                $app->{scopes},
                $app->{homepage}              || '',
                $app->{github}                || '',
                $app->{appstore}              || '',
                $app->{googleplay}            || '',
                $app->{redirect_uri}          || '',
                $app->{verification_uri}      || '',
                $app->{app_markup_percentage} || 0,
                $app->{user_id});

            my $result = $sth->fetchrow_hashref();
            return $result;
        });
    $result->{scopes} = __parse_array($result->{scopes});
    $result->{app_id} = $result->{id};
    delete @$result{qw(binary_user_id stamp id bypass_verification secret)};
    return $result;
}

=head2 update_app


B<NOTE> update_app does: update application details by calling app_update function in auth database.

Function args:

=over 4

=item * C<app_id> - application ID "Int"

=item * C<app> - hash reference for application data.

=back

Returns a hash reference for the application updated data

=cut

sub update_app {
    my ($self, $app_id, $app) = @_;

    my $updated_app = $self->dbic->run(
        ping => sub {
            my $sth = $_->prepare("select * from oauth.app_update(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");

            $sth->execute(
                $app_id,                  $app->{name},     $app->{scopes},     $app->{homepage},
                $app->{github},           $app->{appstore}, $app->{googleplay}, $app->{redirect_uri},
                $app->{verification_uri}, $app->{app_markup_percentage}, $app->{active});
            my $result = $sth->fetchrow_hashref();
            return $result;
        });
    $updated_app->{scopes} = __parse_array($updated_app->{scopes});
    return $updated_app;
}

sub get_app {
    my ($self, $user_id, $app_id, $active) = @_;
    $active = $active // 1;    #defined($active) ? $active : 1;
    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("
        SELECT
            id as app_id, name, redirect_uri, verification_uri, scopes,
            homepage, github, appstore, googleplay, app_markup_percentage, active
        FROM oauth.apps WHERE id = ? AND binary_user_id = ? AND active = ?", undef, $app_id, $user_id, $active);
        });
    return unless $app;

    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub get_app_by_id {
    my ($self, $app_id) = @_;
    my $app = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT *  FROM oauth.apps WHERE id = ?", undef, $app_id);
        });

    return unless $app;
    $app->{scopes} = __parse_array($app->{scopes});
    return $app;
}

sub get_apps_by_user_id {
    my ($self, $user_id) = @_;

    my $apps = $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("
        SELECT
            id as app_id, name, redirect_uri, verification_uri, scopes,
            homepage, github, appstore, googleplay, app_markup_percentage, active
        FROM oauth.apps WHERE binary_user_id = ? AND active ORDER BY name", {Slice => {}}, $user_id);
        });
    return [] unless $apps;

    foreach (@$apps) {
        $_->{scopes} = __parse_array($_->{scopes});
    }

    return $apps;
}

sub get_app_ids_by_user_id {
    my ($self, $user_id) = @_;

    my $app_ids = $self->dbic->run(
        fixup => sub {
            $_->selectcol_arrayref("
        SELECT
            id
        FROM oauth.apps WHERE binary_user_id = ?", undef, $user_id);
        });
    return $app_ids || [];
}

sub get_used_apps_by_loginid {
    my ($self, $loginid) = @_;

    return $self->dbic->run(
        fixup => sub {
            my $dbh  = $_;
            my $apps = $dbh->selectall_arrayref("
        SELECT
            u.app_id, a.name, a.scopes, a.app_markup_percentage,
            u.last_login as last_used
        FROM oauth.apps a JOIN oauth.user_scope_confirm u ON a.id=u.app_id
        WHERE u.loginid = ? AND a.active ORDER BY a.name
    ", {Slice => {}}, $loginid);
            return [] unless $apps;
            $_->{scopes} = __parse_array($_->{scopes}) for @$apps;
            return $apps;
        });

}

sub revoke_app {
    my ($self, $app_id, $loginid) = @_;

    my $dbic = $self->dbic;
    $dbic->run(
        ping => sub {
            foreach my $table ('user_scope_confirm', 'access_token') {
                $_->do("DELETE FROM oauth.$table WHERE app_id = ? AND loginid = ?", undef, $app_id, $loginid);
            }
        });
    return 1;
}

sub revoke_tokens_by_loginid {
    my ($self, $loginid) = @_;
    $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM oauth.access_token WHERE loginid = ?", undef, $loginid);
        });
    return 1;
}

=head2 revoke_tokens_by_loignid_and_ua_fingerprint

Delete all the access tokens for given loginids and ua_fingerprints

=over 4

=item * C<loginid>

=item * C<ua_fingerprint>

=back

=cut

sub revoke_tokens_by_loignid_and_ua_fingerprint {
    my ($self, $p_loginid, $p_ua_fingerprint) = @_;

    $self->dbic->run(
        ping => sub {
            $_->do("SELECT FROM oauth.delete_access_token(?::TEXT, ?::TEXT)", undef, $p_loginid, $p_ua_fingerprint);
        });

    return 1;
}

sub revoke_tokens_by_loginid_app {
    my ($self, $loginid, $app_id) = @_;
    $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM oauth.access_token WHERE loginid = ? AND app_id = ?", undef, $loginid, $app_id);
        });
    return 1;
}

sub has_other_login_sessions {
    my ($self, $loginid) = @_;

    # "Binary.com backoffice" app has id = 4, we use it to create token for BO impersonate. So should be excluded here.
    my $login_cnt = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT count(*) FROM oauth.access_token WHERE loginid = ? AND expires > now() AND app_id <> 4", undef, $loginid);
        });
    return ($login_cnt >= 1);
}

=head2 get_app_id_by_token

retrieve app_id from a given token

=over 4

=item * C<Token> I receives token to find app_id

=back

Returns app_id if it successfully found app_id and returns undef otherwise.

=cut

sub get_app_id_by_token {
    my ($self, $token) = @_;

    my @result =
        $self->dbic->run(fixup => sub { $_->selectrow_array("SELECT app_id FROM oauth.access_token WHERE access_token = ?", undef, $token) });
    return $result[0];
}

sub user_has_app_id {
    my ($self, $user_id, $app_id) = @_;

    return $self->dbic->run(
        fixup => sub { $_->selectrow_array("SELECT id FROM oauth.apps WHERE binary_user_id = ? AND id = ?", undef, $user_id, $app_id) });
}

sub block_app {
    my ($self, $app_id, $user_id) = @_;
    my $app = $self->get_app_by_id($app_id);
    return 0 unless $app;
    return 0 if ($user_id && $app->{binary_user_id} ne $user_id);
    $app->{active} = 0;
    return $self->update_app($app_id, $app);
}

sub unblock_app {
    my ($self, $app_id) = @_;
    my $app = $self->get_app_by_id($app_id);
    $app->{active} = 1;
    return $self->update_app($app_id, $app);
}

=head2 create_app_token

Wrapper for the `oauth.create_app_token` function.

Creates a new entry for the application and token given in the `oauth.app_token` table.

It takes the following arguments:

=over 4

=item C<$app_id> the given application id

=item C<$token> the new token

=back

Returns 1.

=cut

sub create_app_token {
    my ($self, $app_id, $token) = @_;

    $self->dbic->run(
        ping => sub {
            $_->do("SELECT * FROM oauth.create_app_token(?::BIGINT, ?::TEXT)", undef, $app_id, $token);
        });

    return 1;
}

=head2 get_app_tokens

Wrapper for the `oauth.get_app_tokens` function.

Grabs from the `oauth.app_token` table all the tokens linked to the given application id.

It takes the following arguments:

=over 4

=item * C<$app_id> the given application id

=back

Returns an arrayref of tokens.

=cut

sub get_app_tokens {
    my ($self, $app_id) = @_;

    return $self->dbic->run(fixup => sub { $_->selectcol_arrayref("SELECT token FROM oauth.get_app_tokens(?)", undef, $app_id) });
}

=head2 generate_refresh_token

Wrapper for the `oauth.create_refresh_token` function.

It takes the following arguments:

=over 4

=item * C<$binary_user_id> binary user id.
=item * C<$app_id> source app id.
=item * C<$token_length> length of refresh token.
=item * C<$expires_in_sec> expiry time required in seconds
=item * C<$retries> (optional) number of retries before giving up

=back

Returns a refresh token.

=cut

sub generate_refresh_token {
    my ($self, $binary_user_id, $app_id, $token_length, $expires_in_sec, $retries) = @_;
    $token_length   //= REFRESH_TOKEN_LENGTH;
    $expires_in_sec //= REFRESH_TOKEN_TIMEOUT;
    $retries        //= TOKEN_GENERATION_ATTEMPTS;

    my ($token) = $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT * FROM oauth.create_refresh_token(?::INT, ?::BIGINT, ?::INT, ?::BIGINT)",
                undef, $token_length, $binary_user_id, $expires_in_sec, $app_id);
        });

    return $token if $token;

    $retries //= 0;

    return undef if $retries <= 0;

    return $self->generate_refresh_token($token_length, $binary_user_id, $expires_in_sec, $app_id, $retries - 1);
}

=head2 get_user_app_details_by_refresh_token

select user and app info based on valid refresh_tokens
It takes the following arguments:

=over 4

=item * C<$refresh_token> refresh token.

=back

Returns a record based on refresh_token provided.

=cut

sub get_user_app_details_by_refresh_token {
    my ($self, $refresh_token) = @_;
    return $self->dbic->run(fixup =>
            sub { $_->selectrow_hashref("SELECT * FROM ONLY oauth.refresh_token WHERE token = ? AND expiry_time > NOW()", undef, $refresh_token) });
}

=head2 get_refresh_tokens_by_user_app_id

select all refresh tokens accosiated with user_id and app_id
It takes the following arguments:

=over 4

=item * C<$user_id> binary user id.
=item * C<$app_id> app id to logout from.

=back

Returns list of refresh_tokens.

=cut

sub get_refresh_tokens_by_user_app_id {
    my ($self, $user_id, $app_id) = @_;
    return $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT token FROM ONLY oauth.refresh_token WHERE binary_user_id = ? AND app_id = ? AND expiry_time > NOW()",
                undef, $user_id, $app_id);
        });
}

=head2 get_refresh_tokens_by_user_id

select all refresh tokens accosiated with user_id.
It takes the following arguments:

=over 4

=item * C<$user_id> binary user id.

=back

Returns list of refresh_tokens.

=cut

sub get_refresh_tokens_by_user_id {
    my ($self, $user_id) = @_;
    return $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT token FROM ONLY oauth.refresh_token WHERE binary_user_id = ? AND expiry_time > NOW()", undef, $user_id);
        });
}

=head2 revoke_refresh_tokens_by_user_id

Deletes all valid refresh_token from oauth.refresh_token table for a specific user.
It takes the following arguments:

=over 4

=item * C<$user_id> binary_user_id.

=back

=cut

sub revoke_refresh_tokens_by_user_id {
    my ($self, $user_id) = @_;

    $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM oauth.refresh_token WHERE binary_user_id = ? AND expiry_time > NOW()", undef, $user_id);
        });
    return 1;
}

=head2 revoke_refresh_tokens_by_user_app_id

Deletes valid refresh_token from oauth.refresh_token table based on binary user and app id.
It takes the following arguments:

=over 4

=item * C<$user_id> binary_user_id.
=item * C<$app_id> current app used.

=back

=cut

sub revoke_refresh_tokens_by_user_app_id {
    my ($self, $user_id, $app_id) = @_;

    $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM oauth.refresh_token WHERE binary_user_id = ? AND app_id = ? AND expiry_time > NOW()", undef, $user_id, $app_id);
        });
    return 1;
}

=head2 generate_ctrader_token

Wrapper for the `oauth.create_ctrader_token` function.

It takes the following arguments:

=over 4

=item * C<user_id> binary user id.
=item * C<ctid> source app id.
=item * C<token_length> length of ctrader token.
=item * C<expires_in_sec> expiry time required in seconds
=item * C<retries> (optional) number of retries before giving up
=item * C<ua_fingerprint> hashsum of UserAgent string

=back

Returns a ctrader token.

=cut

sub generate_ctrader_token {
    my ($self, $args) = @_;

    $args->{token_length}   //= CTRADER_TOKEN_LENGTH;
    $args->{expires_in_sec} //= CTRADER_TOKEN_TTL;
    $args->{retries}        //= TOKEN_GENERATION_ATTEMPTS;
    $args->{ua_fingerprint} //= '';

    $args->{$_} or croak "$_ is mandatory argument" for (qw[user_id ctid]);

    my $token = $self->dbic->run(
        fixup => sub {
            my $db = $_;
            for (1 .. $args->{retries}) {
                my ($token) = $db->selectrow_array("SELECT access_token FROM oauth.create_ctrader_token(?::INT, ?::BIGINT, ?::INT, ?::TEXT, ?::TEXT)",
                    undef, $args->@{qw(token_length user_id expires_in_sec ctid ua_fingerprint)});
                return $token if $token;
            }

            return undef;
        });

    return $token;
}

=head2 get_details_of_ctrader_token

select user info based on valid ctrader token
It takes the following arguments:

=over 4

=item * C<$ctrader_token> ctrader token.

=back

Returns a record based on ctrader_token provided.

=cut

sub get_details_of_ctrader_token {
    my ($self, $ctrader_token) = @_;
    return $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT * FROM ONLY oauth.ctrader_token WHERE access_token = ? AND expires > NOW()", undef, $ctrader_token);
        });
}

=head2 get_ctrader_tokens_by_user_id

select all ctrader tokens accosiated with user_id.
It takes the following arguments:

=over 4

=item * C<$user_id> binary user id.

=back

Returns list of ctrader_tokens.

=cut

sub get_ctrader_tokens_by_user_id {
    my ($self, $user_id) = @_;
    return $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT access_token FROM ONLY oauth.ctrader_token WHERE binary_user_id = ? AND expires > NOW()", undef, $user_id);
        });
}

=head2 revoke_ctrader_tokens_by_user_id

Deletes all valid ctrader_token from oauth.ctrader_token table for a specific user.
It takes the following arguments:

=over 4

=item * C<$user_id> binary_user_id.

=back

=cut

sub revoke_ctrader_tokens_by_user_id {
    my ($self, $user_id) = @_;

    $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM oauth.ctrader_token WHERE binary_user_id = ?", undef, $user_id);
        });
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

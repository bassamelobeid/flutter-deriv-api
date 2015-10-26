package BOM::WebSocketAPI::v3::Accounts;

use strict;
use warnings;

use Try::Tiny;
use Mojo::DOM;

use BOM::Product::ContractFactory;
use BOM::Platform::Runtime;
use BOM::Product::Transaction;
use BOM::System::Password;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Email qw(send_email);
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Platform::Runtime::LandingCompany::Registry;

sub landing_company {
    my ($c, $args) = @_;

    my $lc = BOM::Platform::Runtime::LandingCompany::Registry->new->get($args->{landing_company});
    return {
        msg_type => 'landing_company',
        error    => {
            message => "Unknown landing company",
            code    => "UnknownLandingCompany"
        }} unless $lc;

    return {
        msg_type        => 'landing_company',
        landing_company => {
            shortcode                         => $lc->short,
            name                              => $lc->name,
            address                           => $lc->address,
            country                           => $lc->country,
            legal_default_currency            => $lc->legal_default_currency,
            legal_allowed_currencies          => $lc->legal_allowed_currencies,
            legal_allowed_markets             => $lc->legal_allowed_markets,
            legal_allowed_contract_categories => $lc->legal_allowed_contract_categories,
        }};
}

sub statement {
    my ($c, $args) = @_;

    my $statement = get_transactions($c, $args);
    return {
        echo_req  => $args,
        msg_type  => 'statement',
        statement => $statement,
    };
}

sub get_transactions {
    my ($c, $args) = @_;

    my $log = $c->app->log;
    my $acc = $c->stash('account');

    # note, there seems to be a big performance penalty associated with the 'description' option..

    my $and_description = $args->{description};

    $args->{sort_by} = 'transaction_time desc';
    $args->{limit}  ||= 100;
    $args->{offset} ||= 0;
    my $dt_fm = $args->{dt_fm};
    my $dt_to = $args->{dt_to};

    for ($dt_fm, $dt_to) {
        next unless $_;
        my $dt = eval { DateTime->from_epoch(epoch => $_) }
            || return $c->_fail("date expression [$_] should be a valid epoch value");
        $_ = $dt;
    }

    my $query = [];
    push @$query, action_type => $args->{action_type} if $args->{action_type};
    push @$query, transaction_time => {ge => $dt_fm} if $dt_fm;
    push @$query, transaction_time => {lt => $dt_to} if $dt_to;
    $args->{query} = $query if @$query;

    $log->debug("transaction query opts are " . $c->dumper($args));

    my $count = 0;
    my @trxs;
    if ($acc) {
        @trxs  = $acc->find_transaction(%$args);    # Rose
        $count = scalar(@trxs);
    }

    my $trxs = [
        map {
            my $trx    = $_;
            my $struct = {
                contract_id      => $trx->financial_market_bet_id,
                transaction_time => $trx->transaction_time->epoch,
                amount           => $trx->amount,
                action_type      => $trx->action_type,
                balance_after    => $trx->balance_after,
                transaction_id   => $trx->id,
            };
            if ($and_description) {
                $struct->{longcode} = '';
                if (my $fmb = $trx->financial_market_bet) {
                    if (my $con = eval { BOM::Product::ContractFactory::produce_contract($fmb->short_code, $acc->currency_code) }) {
                        $struct->{longcode}  = Mojo::DOM->new->parse($con->longcode)->all_text;
                        $struct->{shortcode} = $con->shortcode;
                    }
                }
            }
            $struct
        } @trxs
    ];

    return {
        transactions => $trxs,
        count        => $count
    };
}

sub profit_table {
    my ($c, $args) = @_;

    my $profit_table = __get_sold($c, $args);
    return {
        echo_req     => $args,
        msg_type     => 'profit_table',
        profit_table => $profit_table,
    };
}

sub __get_sold {
    my ($c, $args) = @_;

    my $client = $c->stash('client');
    my $acc    = $c->stash('account');

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $client->loginid,
            currency_code  => $client->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
                    operation      => 'replica',
                }
            )->db,
        });

    $args->{after}  = $args->{dt_fm} if $args->{dt_fm};
    $args->{before} = $args->{dt_to} if $args->{dt_to};
    my $data = $fmb_dm->get_sold_bets_of_account($args);

    ## remove useless and plus new
    $data->{transactions} = [];
    my $and_description = $args->{description};
    foreach my $row (@{delete $data->{rows}}) {
        my %trx = map { $_ => $row->{$_} } (qw/sell_price buy_price purchase_time sell_time/);
        $trx{contract_id}    = $row->{id};
        $trx{transaction_id} = $row->{txn_id};
        if ($and_description) {
            $trx{longcode} = '';
            if (my $con = try { BOM::Product::ContractFactory::produce_contract($row->{short_code}, $acc->currency_code) }) {
                $trx{longcode}  = Mojo::DOM->new->parse($con->longcode)->all_text;
                $trx{shortcode} = $con->shortcode;
            }
        }
        push @{$data->{transactions}}, \%trx;
    }

    return $data;
}

sub balance {
    my ($c, $args) = @_;

    my $client = $c->stash('client');

    my @client_balances;
    for my $cl ($client->siblings) {
        next unless $cl->default_account;

        push @client_balances,
            {
            loginid  => $cl->loginid,
            currency => $cl->default_account->currency_code,
            balance  => $cl->default_account->balance,
            };
    }

    return {
        msg_type => 'balance',
        balance  => \@client_balances,
    };
}

sub change_password {
    my ($c, $args) = @_;

    my $client_obj = $c->stash('client');
    my $user = BOM::Platform::User->new({email => $client_obj->email});

    my $err = sub {
        my ($message) = @_;
        return {
            msg_type => 'change_password',
            error    => {
                message => $message,
                code    => "ChangePasswordError"
            },
        };
    };

    ## args validation is done with JSON::Schema in entry_point, here we do others
    return $err->(localize('New password is same as old password.'))
        if $args->{new_password} eq $args->{old_password};
    return $err->(localize("Old password is wrong."))
        unless BOM::System::Password::checkpw($args->{old_password}, $user->password);

    my $new_password = BOM::System::Password::hashpw($args->{new_password});
    $user->password($new_password);
    $user->save;

    foreach my $client ($user->clients) {
        $client->password($new_password);
        $client->save;
    }

    my $r = $c->stash('r');
    BOM::System::AuditLog::log('password has been changed', $client_obj->email);
    send_email({
            from    => $r->website->config->get('customer_support.email'),
            to      => $client_obj->email,
            subject => localize('Your password has been changed.'),
            message => [
                localize(
                    'The password for your account [_1] has been changed. This request originated from IP address [_2]. If this request was not performed by you, please immediately contact Customer Support.',
                    $client_obj->email,
                    $r->client_ip
                )
            ],
            use_email_template => 1,
        });

    return {
        msg_type        => 'change_password',
        change_password => 1
    };
}

1;

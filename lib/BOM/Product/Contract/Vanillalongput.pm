package BOM::Product::Contract::Vanillalongput;

use Moose;
extends 'BOM::Product::Contract';
with 'BOM::Product::Role::Vanilla', 'BOM::Product::Role::SingleBarrier', 'BOM::Product::Role::ExpireAtEnd';

use BOM::Product::Pricing::Engine::BlackScholes;
use BOM::Product::Exception;
use Format::Util::Numbers qw/financialrounding/;

=head1 DESCRIPTION

Vanilla Option is the most basic derivative contract.
Unlike our other contracts, you cannot define payout for vanilla option, you can only define the stake.
Payout is depends on the difference between Strike price and Underlying price at expiry.

Payout = max(K - S, 0) x n

where
S = strike price
K = Underlying price at expiry
n = implied number of contracts

python code:

    import numpy as np
    from scipy.stats import norm

    def bsmcall(r,S,K,T,sigma):
        d1=(np.log(S/K) +(r+(sigma**2)/2)*T)/(sigma*np.sqrt(T))
        d2=d1-sigma*np.sqrt(T)
        price=K*np.exp(-r*T)*norm.cdf(-d2)-S*norm.cdf(-d1)
        return price

=cut

=head2 check_expiry_conditions

Checks expiry condition of a vanilla long put contract.
For vanilla option contract is expired only when expiry time is reached.
Contract will have value if exit tick price is lower than strike price.

=cut

sub check_expiry_conditions {
    my $self = shift;

    my $number_of_contracts = $self->number_of_contracts;
    # we need to adjust payout per pip back to number of contracts for financials
    $number_of_contracts = $number_of_contracts / $self->underlying->pip_size unless $self->is_synthetic;
    if ($self->exit_tick) {
        my $exit_quote = $self->exit_tick->quote;
        my $value =
              ($exit_quote < $self->barrier->as_absolute)
            ? ($self->barrier->as_absolute - $exit_quote) * $number_of_contracts
            : 0;
        $value = financialrounding('price', $self->currency, $value);
        $self->value($value);
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

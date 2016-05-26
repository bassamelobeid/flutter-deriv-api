package GenerateStaticData;

use MooseX::Singleton;
use BOM::Platform::Runtime;
use JSON qw(to_json);
use Encode;
use HTML::Entities;
use URI::Escape;
use DateTime;
use Digest::MD5;
use File::Slurp;
use YAML::XS qw(LoadFile);

extends 'BOM::View::JavascriptConfig';

use BOM::Market::Registry;
use BOM::Market::SubMarket::Registry;
use BOM::Market::UnderlyingDB;
use BOM::Market::Underlying;
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::I18N;
use BOM::Product::Contract::Category;
use BOM::Product::Offerings qw(get_offerings_with_filter);

my $contract_categories = LoadFile('/home/git/regentmarkets/bom/config/files/contract_categories.yml');
my $contract_type_config = LoadFile('/home/git/regentmarkets/bom/config/files/contract_types.yml');

sub generate_data_files {
    my $self = shift;

    my $website_path = $self->_js_dir_path;
    $self->_make_nobody_dir("$website_path/data/");
    print "\tGenerating $website_path/data/texts.js\n";
    File::Slurp::write_file("$website_path/data/texts.js", {binmode => ':utf8'}, $self->_texts);

    return;
}

sub _texts {
    my $self = shift;

    my $js = "var texts_json = {};\n";
    foreach my $language (@{BOM::Platform::Runtime->instance->app_config->cgi->supported_languages}) {
        $self->_localize_handler(BOM::Platform::Context::I18N::handle_for($language));

        my @texts;
        push @texts, $self->localize('Day');
        push @texts, $self->localize('Month');
        push @texts, $self->localize('Year');
        push @texts, $self->localize('Please wait.<br />Your request is being processed.');
        push @texts, $self->localize('loading...');
        push @texts, $self->localize('Failed to update trade description.');
        push @texts, $self->localize('Please try again.');
        push @texts, $self->localize("(Bejing/CST -8 hours)");
        push @texts, $self->localize('You must accept the terms and conditions to open an account.');
        push @texts, $self->localize('We are not accepting accounts from residents of this country at the present time.');
        # highchart localization text
        push @texts, $self->localize('Print chart');
        push @texts, $self->localize('Save as JPEG');
        push @texts, $self->localize('Save as PNG');
        push @texts, $self->localize('Save as SVG');
        push @texts, $self->localize('Save as PDF');
        push @texts, $self->localize('Save as CSV');
        push @texts, $self->localize('From');
        push @texts, $self->localize('To');
        push @texts, $self->localize('Zoom');
        push @texts, $self->localize('Sunday');
        push @texts, $self->localize('Monday');
        push @texts, $self->localize('Tuesday');
        push @texts, $self->localize('Wednesday');
        push @texts, $self->localize('Thursday');
        push @texts, $self->localize('Friday');
        push @texts, $self->localize('Saturday');
        push @texts, $self->localize('Jan');
        push @texts, $self->localize('Feb');
        push @texts, $self->localize('Mar');
        push @texts, $self->localize('Apr');
        push @texts, $self->localize('May');
        push @texts, $self->localize('Jun');
        push @texts, $self->localize('Jul');
        push @texts, $self->localize('Aug');
        push @texts, $self->localize('Sep');
        push @texts, $self->localize('Oct');
        push @texts, $self->localize('Nov');
        push @texts, $self->localize('Dec');
        push @texts, $self->localize('January');
        push @texts, $self->localize('February');
        push @texts, $self->localize('March');
        push @texts, $self->localize('April');
        push @texts, $self->localize('May');
        push @texts, $self->localize('June');
        push @texts, $self->localize('July');
        push @texts, $self->localize('August');
        push @texts, $self->localize('September');
        push @texts, $self->localize('October');
        push @texts, $self->localize('November');
        push @texts, $self->localize('December');
        push @texts, $self->localize('Week of');
        push @texts, $self->localize('year');
        push @texts, $self->localize('years');
        push @texts, $self->localize('month');
        push @texts, $self->localize('months');
        push @texts, $self->localize('day');
        push @texts, $self->localize('hour');
        push @texts, $self->localize('minute');
        push @texts, $self->localize('second');
        push @texts, $self->localize('Purchase Time');
        push @texts, $self->localize('Start Time');
        push @texts, $self->localize('Entry Spot');
        push @texts, $self->localize('Low Barrier');
        push @texts, $self->localize('High Barrier');
        push @texts, $self->localize('Next');
        push @texts, $self->localize('Previous');
        push @texts, $self->localize('Su');
        push @texts, $self->localize('Mo');
        push @texts, $self->localize('Tu');
        push @texts, $self->localize('We');
        push @texts, $self->localize('Th');
        push @texts, $self->localize('Fr');
        push @texts, $self->localize('Sa');
        push @texts, $self->localize('This contract won');
        push @texts, $self->localize('This contract lost');
        push @texts, $self->localize('Loss');
        push @texts, $self->localize('Profit');
        push @texts,
            $self->localize(
            'We are not able to stream live prices at the moment. To enjoy live streaming of prices try refreshing the page, if you get this issue after repeated attempts try a different browser'
            );
        push @texts, $self->localize('No Live price update');
        push @texts, $self->localize('Please enter a date that is at least 6 months from now.');
        push @texts, $self->localize("When you click 'Ok' you will be excluded from trading on the site until the selected date.");
        push @texts, $self->localize('Please confirm the trade on your statement before proceeding.');
        push @texts, $self->localize('There was a problem accessing the server.');
        push @texts, $self->localize('There was a problem accessing the server during purchase.');
        push @texts, $self->localize('Virtual Account');
        push @texts, $self->localize('Real Account');
        push @texts, $self->localize('Investment Account');
        push @texts, $self->localize('Gaming Account');
        push @texts, $self->localize('The two passwords that you entered do not match.');
        push @texts, $self->localize('Invalid email address');
        push @texts, $self->localize('Your password cannot be the same as your email');

        # text used by websocket trading page javascript
        push @texts, $self->localize('Start time');
        push @texts, $self->localize('Spot');
        push @texts, $self->localize('Barrier');
        push @texts, $self->localize('Barrier offset');
        push @texts, $self->localize('High barrier');
        push @texts, $self->localize('High barrier offset');
        push @texts, $self->localize('Low barrier');
        push @texts, $self->localize('Low barrier offset');
        push @texts, $self->localize('Payout');
        push @texts, $self->localize('Stake');
        push @texts, $self->localize('Purchase');
        push @texts, $self->localize('Duration');
        push @texts, $self->localize('End Time');
        push @texts, $self->localize('[ctx,minimum duration, for example minimum 15 seconds]min');
        push @texts, $self->localize('minimum available duration');
        push @texts, $self->localize('Enter the barrier in terms of the difference from the spot price. If you enter +0.005, then you will be purchasing a contract with a barrier 0.005 higher than the entry spot. The entry spot will be the next tick after your order has been received');
        push @texts, $self->localize('seconds');
        push @texts, $self->localize('minutes');
        push @texts, $self->localize('hours');
        push @texts, $self->localize('days');
        push @texts, $self->localize('ticks');
        push @texts, $self->localize('Net profit');
        push @texts, $self->localize('Return');
        push @texts, $self->localize('Now');
        push @texts, $self->localize('Contract Confirmation');
        push @texts, $self->localize('Your transaction reference is');
        push @texts, $self->localize('Your current balance is');
        push @texts, $self->localize('Rise/Fall');
        push @texts, $self->localize('Higher/Lower');
        push @texts, $self->localize('Period');
        push @texts, $self->localize('Exercise period');
        push @texts, $self->localize('Last Digit Prediction');
        push @texts, $self->localize('Potential Payout');
        push @texts, $self->localize('Total Cost');
        push @texts, $self->localize('Potential Profit');
        push @texts, $self->localize('Exercise period');
        push @texts, $self->localize('Amount per point');
        push @texts, $self->localize('Stop-loss');
        push @texts, $self->localize('Stop-type');
        push @texts, $self->localize('Points');
        push @texts, $self->localize('View');
        push @texts, $self->localize('Random');
        push @texts, $self->localize('In/Out');
        push @texts, $self->localize('Statement');
        push @texts, $self->localize('Next Day');
        push @texts, $self->localize('Previous Day');
        push @texts, $self->localize('Jump To');
        push @texts, $self->localize('Date');
        push @texts, $self->localize('Ref.');
        push @texts, $self->localize('Action');
        push @texts, $self->localize('Sell');
        push @texts, $self->localize('Buy');
        push @texts, $self->localize('Description');
        push @texts, $self->localize('Credit/Debit');
        push @texts, $self->localize('Balance');
        push @texts, $self->localize('points');
        push @texts, $self->localize('Tick');
        push @texts, $self->localize('Date (GMT)');
        push @texts, $self->localize('Contract');
        push @texts, $self->localize('Purchase Price');
        push @texts, $self->localize('Sale Date');
        push @texts, $self->localize('Sale Price');
        push @texts, $self->localize('Profit/Loss');
        push @texts, $self->localize('Profit Table');
        push @texts, $self->localize('Total Profit/Loss');
        push @texts, $self->localize('Long');
        push @texts, $self->localize('Short');
        push @texts, $self->localize('Deposit of');
        push @texts, $self->localize('is required. Current spread');
        push @texts, $self->localize('Matches/Differs');
        push @texts, $self->localize('Chart');
        push @texts, $self->localize('Explanation');
        push @texts, $self->localize('Last Digit Stats');
        push @texts, $self->localize('Prices');
        push @texts, $self->localize('Authorise your account.');
        push @texts, $self->localize('Even/Odd');
        push @texts, $self->localize('Over/Under');
        push @texts, $self->localize('Waiting for entry tick.');

        #strings for limitsws page
        push @texts, $self->localize('Trading and Withdrawal Limits');
        push @texts, $self->localize('Item');
        push @texts, $self->localize('Limit');
        push @texts, $self->localize('Maximum number of open positions');
        push @texts, $self->localize('Represents the maximum number of outstanding contracts in your portfolio. Each line in your portfolio counts for one open position. Once the maximum is reached, you will not be able to open new positions without closing an existing position first.');
        push @texts, $self->localize('Maximum account cash balance');
        push @texts, $self->localize('Represents the maximum amount of cash that you may hold in your account.  If the maximum is reached, you will be asked to withdraw funds.');
        push @texts, $self->localize('Maximum daily turnover');
        push @texts, $self->localize('Represents the maximum volume of contracts that you may purchase in any given trading day.');
        push @texts, $self->localize('Maximum aggregate payouts on open positions');
        push @texts, $self->localize('Presents the maximum aggregate payouts on outstanding contracts in your portfolio. If the maximum is attained, you may not purchase additional contracts without first closing out existing positions.');
        push @texts, $self->localize('Trading Limits');
        push @texts, $self->localize('Withdrawal Limits');
        push @texts, $self->localize('Your account is fully authenticated and your withdrawal limits have been lifted.');
        push @texts, $self->localize('Your withdrawal limit is [_1] [_2].');
        push @texts, $self->localize('Your withdrawal limit is [_1] [_2] (or equivalent in other currency).');
        push @texts, $self->localize('You have already withdrawn [_1] [_2].');
        push @texts, $self->localize('You have already withdrawn the equivalent of [_1] [_2].');
        push @texts, $self->localize('Therefore your current immediate maximum withdrawal (subject to your account having sufficient funds) is [_1] [_2].');
        push @texts, $self->localize('Therefore your current immediate maximum withdrawal (subject to your account having sufficient funds) is [_1] [_2] (or equivalent in other currency).');
        push @texts, $self->localize('Your [_1] day withdrawal limit is currently [_2] [_3] (or equivalent in other currency).');
        push @texts, $self->localize('You have already withdrawn the equivalent of [_1] [_2] in aggregate over the last [_3] days.');

        #strings for detailsws
        push @texts, $self->localize('This field is required.');
        push @texts, $self->localize('You should enter between [_1] characters.');
        push @texts, $self->localize('Only [_1] are allowed.');
        push @texts, $self->localize('letters');
        push @texts, $self->localize('numbers');
        push @texts, $self->localize('space');
        push @texts, $self->localize('period');
        push @texts, $self->localize('comma');
        push @texts, $self->localize('Sorry, an error occurred while processing your account.');
        push @texts, $self->localize('Your settings have been updated successfully.');
        push @texts, $self->localize('m');
        push @texts, $self->localize('f');
        push @texts, $self->localize('Office worker');
        push @texts, $self->localize('Director');
        push @texts, $self->localize('Public worker');
        push @texts, $self->localize('Self-employed');
        push @texts, $self->localize('Housewife / Househusband');
        push @texts, $self->localize('Contract / Temporary / Part Time');
        push @texts, $self->localize('Student');
        push @texts, $self->localize('Unemployed');
        push @texts, $self->localize('Others');
        push @texts, $self->localize('Less than 1 million JPY');
        push @texts, $self->localize('1-3 million JPY');
        push @texts, $self->localize('3-5 million JPY');
        push @texts, $self->localize('5-10 million JPY');
        push @texts, $self->localize('10-30 million JPY');
        push @texts, $self->localize('30-50 million JPY');
        push @texts, $self->localize('50-100 million JPY');
        push @texts, $self->localize('Over 100 million JPY');
        push @texts, $self->localize('No experience');
        push @texts, $self->localize('Less than 6 months');
        push @texts, $self->localize('6 months to 1 year');
        push @texts, $self->localize('1-3 years');
        push @texts, $self->localize('3-5 years');
        push @texts, $self->localize('Over 5 years');
        push @texts, $self->localize('Targeting short-term profits');
        push @texts, $self->localize('Targeting medium-term / long-term profits');
        push @texts, $self->localize('Both the above');
        push @texts, $self->localize('Hedging');
        push @texts, $self->localize('Foreign currency deposit');
        push @texts, $self->localize('Margin FX');

        #strings for home and virtualws page
        push @texts, $self->localize('verification token');
        push @texts, $self->localize('Please submit a valid [_1].');
        push @texts, $self->localize('password');
        push @texts, $self->localize('The two passwords that you entered do not match.');
        push @texts, $self->localize('Your token has expired. Please click <a class="pjaxload" href="[_1]">here</a> to restart the verification process.');
        push @texts, $self->localize('Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site. If you have forgotten the password of your existing account, please <a href="[_1]">try our password recovery tool</a> or contact customer service.');
        push @texts, $self->localize('Try adding more numbers.');
        push @texts, $self->localize('Try adding more letters.');
        push @texts, $self->localize('Try adding more letters or numbers.');
        push @texts, $self->localize('Password score is: [_1]. Passing score is: 20.');
        push @texts, $self->localize('Password should have lower and uppercase letters with numbers.');
        push @texts, $self->localize('Password is not strong enough.');
        push @texts, $self->localize('Password is weak');
        push @texts, $self->localize('Password is moderate');
        push @texts, $self->localize('Password is strong');
        push @texts, $self->localize('Password is very strong');
        push @texts, $self->localize('Please [_1] to view this page');
        push @texts, $self->localize('login');
        push @texts, $self->localize('Your session duration limit will end in [_1] seconds.');

        #strings for realws page
        push @texts, $self->localize('hyphen');
        push @texts, $self->localize('apostrophe');
        push @texts, $self->localize('Mr');
        push @texts, $self->localize('Mrs');
        push @texts, $self->localize('Ms');
        push @texts, $self->localize('Miss');
        push @texts, $self->localize('Please input a valid date');
        push @texts, $self->localize('Please select');
        push @texts, $self->localize('Sorry, account opening is unavailable.');
        push @texts, $self->localize('Minimum of [_1] characters required.');
        push @texts, $self->localize('Sorry, this feature is not available.');

        #strings for trading_timesws page
        push @texts, $self->localize('Asset');
        push @texts, $self->localize('Opens');
        push @texts, $self->localize('Closes');
        push @texts, $self->localize('Settles');
        push @texts, $self->localize('Upcoming Events');

        #strings for paymentagent_withdrawws page
        push @texts, $self->localize('You are not authorized for withdrawal via payment agent.');
        push @texts, $self->localize('Please select a payment agent');
        push @texts, $self->localize('The Payment Agent facility is currently not available in your country.');
        push @texts, $self->localize('Invalid amount, minimum is');
        push @texts, $self->localize('Invalid amount, maximum is');
        push @texts, $self->localize('Your request to withdraw [_1] [_2] from your account [_3] to Payment Agent [_4] account has been successfully processed.');
        push @texts, $self->localize('Only 2 decimal points are allowed.');

        #strings for api_tokenws page
        push @texts, $self->localize('New token created.');
        push @texts, $self->localize('An error occured.');
        push @texts, $self->localize('The maximum number of tokens ([_1]) has been reached.');
        push @texts, $self->localize('Name');
        push @texts, $self->localize('Token');
        push @texts, $self->localize('Last Used');
        push @texts, $self->localize('Never Used');
        push @texts, $self->localize('Delete');
        push @texts, $self->localize('Are you sure that you want to permanently delete token');

        #strings for Walkthrough Guide
        push @texts, $self->localize('Walkthrough Guide');
        push @texts, $self->localize('Finish');
        push @texts, $self->localize('Step');
        #strings for Walkthrough Guide -> trading page
        push @texts, $self->localize('Select your market');
        push @texts, $self->localize('Select your underlying asset');
        push @texts, $self->localize('Select your trade type');
        push @texts, $self->localize('Adjust trade parameters');
        push @texts, $self->localize('Predict the direction<br />and purchase');

        #strings for top_up_virtualws
        push @texts, $self->localize('Sorry, this feature is available to virtual accounts only.');
        push @texts, $self->localize('[_1] [_2] has been credited to your Virtual money account [_3]');

        #strings for self_exclusionws
        push @texts, $self->localize('Your changes have been updated.');
        push @texts, $self->localize('Please enter an integer value');
        push @texts, $self->localize('Please enter a number between 0 and [_1]');
        push @texts, $self->localize('Session duration limit cannot be more than 6 weeks.');
        push @texts, $self->localize('You did not change anything.');
        push @texts, $self->localize('Please select a valid date');
        push @texts, $self->localize('Exclude time must be after today.');
        push @texts, $self->localize('Exclude time cannot be less than 6 months.');
        push @texts, $self->localize('Exclude time cannot be for more than 5 years.');
        push @texts, $self->localize('When you click "Ok" you will be excluded from trading on the site until the selected date.');

        #strings for change_passwordws
        push @texts, $self->localize('Old password is wrong.');

        #strings for profittable and statement
        push @texts, $self->localize('Your account has no trading activity.');

        #strings for authenticate page
        push @texts, $self->localize('Your account is fully authenticated. You can view your [_1]trading limits here');
        push @texts, $self->localize('To authenticate your account, kindly email the following to [_1]');
        push @texts, $self->localize('- A scanned copy of your passport, driving licence (provisional or full) or identity card, showing your name and date of birth.');
        push @texts, $self->localize('and');
        push @texts, $self->localize('- A scanned copy of a utility bill or bank statement (no more than 3 months old).');
        push @texts, $self->localize('This feature is not relevant to virtual-money accounts.');

        #strings for japanws page
        push @texts, $self->localize('Questions');
        push @texts, $self->localize('True');
        push @texts, $self->localize('False');
        push @texts, $self->localize('There was some invalid character in an input field.');
        push @texts, $self->localize('Please follow the pattern 3 numbers, a dash, followed by 4 numbers.');
        push @texts, $self->localize('Score');
        push @texts, $self->localize('Date');
        push @texts, $self->localize('{JAPAN ONLY}Take knowledge test');
        push @texts, $self->localize('{JAPAN ONLY}Knowledge Test Result');
        push @texts, $self->localize('{JAPAN ONLY}Knowledge Test');
        push @texts, $self->localize('{JAPAN ONLY}Section 1: Structure');
        push @texts, $self->localize('{JAPAN ONLY}Section 2: Method');
        push @texts, $self->localize('{JAPAN ONLY}Section 3: Outline');
        push @texts, $self->localize('{JAPAN ONLY}Section 4: Risk');
        push @texts, $self->localize('{JAPAN ONLY}Section 5: Calculation');
        push @texts, $self->localize('{JAPAN ONLY}An option holder must buy ( or sell ) the underlying asset at a predetermined price within a specified period ( or at a specific time ).');
        push @texts, $self->localize('{JAPAN ONLY}A Currency Option confers the right to sell one currency in exchange for another currency as the underlying asset. For example, the right to sell Yen and buy Dollars is known as a Yen Put / Dollar Call Option, or just Yen Put for short; and the opposite right to buy Yen and sell Dollar is called a Yen Call / Dollar Put Option, or just Yen Call for short.');
        push @texts, $self->localize('{JAPAN ONLY}There are two types of option delivery: One requires exchanging the underlying asset, and the other requires a payment which depends on the difference between the fair market price and the exercise price. A Binary Option is the second type where if the fair market price meets certain conditions with respect to the exercise price, then an agreed fixed amount will be paid to the option buyer.');
        push @texts, $self->localize('{JAPAN ONLY}A  Net Settlement type of option is one where the underlying asset does not include yen, but the option fee and settlement are paid in yen; it therefore requires some definition of how the settlement amounts will be calculated and converted to yen.');
        push @texts, $self->localize('{JAPAN ONLY}A Binary Option contains the right for the buyer to receive a certain fixed amount if the market price reaches the exercise price by the exercise time, but it does not contain any rights to sell or buy the underlying asset.');
        push @texts, $self->localize('{JAPAN ONLY}There are some types of Binary Option, such as Range Binary Options, Touch or No-Touch Binary Options, that are exceptions to the general rule where payment is made at a known exercise time. For these types of option a payment is made automatically at Exit Time when certain conditions have been met.');
        push @texts, $self->localize('{JAPAN ONLY}There are many types of Binary Option, including some such as Range Binary Options and Touch or No-Touch Binary Options which do not always require automatic payment at Exercise Time and which will be settled earlier if certain conditions have been met. However, in all cases, for a payment to be required, the option must end In The Money.');
        push @texts, $self->localize('{JAPAN ONLY}A Currency Binary Option is one where there is a target for a particular currency pair, so a strike price for the exchange rate is agreed, and a payout will be due if the judgment price meets the conditions of being over or under the target strike price, depending on the option type, by the exercise time.');
        push @texts, $self->localize('{JAPAN ONLY}For a currency binary option which has the underlying exchange rate of dollars against yen, the right to receive a payout if the yen becomes weaker is known as a dollar-put binary option.');
        push @texts, $self->localize('{JAPAN ONLY}For a currency binary option with the underlying exchange rate of dollars against yen, the right to receive a payout if the yen becomes stronger is known as a dollar-put binary option.');
        push @texts, $self->localize('{JAPAN ONLY}If you sell a currency binary call option at a price of 500 yen, with an underlying of dollar against yen, the payout is 1,000 yen, and the strike price is 100, then if the judgment price at exercise time is 99, you will need to payout 1,000 yen to the buyer of the option.');
        push @texts, $self->localize('{JAPAN ONLY}If you sell a currency binary put option at a price of 500 yen, with an underlying of dollar against yen, the payout is 1,000 yen, and the strike price is 100, then if the judgment price at exercise time is 99, you will need to payout 1,000 yen to the buyer of the option.');
        push @texts, $self->localize('{JAPAN ONLY}If you buy a currency binary call option at a price of 500 yen, with an underlying of dollar against yen, the payout is 1,000 yen, and the strike price is 100, then if the judgment price at exercise time is 99, you will receive a payout 1,000 yen from the seller of the option.');
        push @texts, $self->localize('{JAPAN ONLY}If you buy a currency binary put option at a price of 500 yen, with an underlying of dollar against yen, the payout is 1,000 yen, and the strike price is 100, then if the judgment price at exercise time is 99, you will receive a payout 1,000 yen from the seller of the option.');
        push @texts, $self->localize('{JAPAN ONLY}If you buy a currency binary option at a price of 500 yen, and the judgment price meets the conditions so you receive a payout of 1,000 yen, then your profit can be calculated 500 yen after subtracting the 500 yen that was paid as a fee to the option seller.');
        push @texts, $self->localize('{JAPAN ONLY}If you sell a currency binary option at a price of 500 yen, and the judgment price meets the conditions so you need to payout 1,000 yen, then your profit will be minus 500 yen after subtracting the 500 yen that was received as a fee from the option buyer.');
        push @texts, $self->localize('{JAPAN ONLY}To avoid or hedge the future price of an underlying asset which you hold, you should buy a call option.');
        push @texts, $self->localize('{JAPAN ONLY}To compensate for any rise in the price of an underlying asset that you intend to buy in future, you should buy a call option.');
        push @texts, $self->localize('{JAPAN ONLY}If you believe the underlying asset price will move by a large amount in either direction, you can benefit by buying both a call and a put option, with the exercise prices set above and below the current underlying price.');
        push @texts, $self->localize('{JAPAN ONLY}If you believe the underlying asset price will be only moderately volatile, you could still benefit by buying both a call and put option with exercise prices that are above and below the exercise price.');
        push @texts, $self->localize('{JAPAN ONLY}A Covered option position is where you hold an offsetting position in the underlying asset.');
        push @texts, $self->localize('{JAPAN ONLY}A binary call option buyer will benefit from a correct prediction that the asset price will decline to below the strike price by the judgment time.');
        push @texts, $self->localize('{JAPAN ONLY}A binary put option buyer will benefit from a correct prediction that the asset price will decline to below the strike price by the judgment time.');
        push @texts, $self->localize('{JAPAN ONLY}A binary put options buyer will benefit from a correct prediction that the asset price will rise above the strike price by the judgment time.');
        push @texts, $self->localize('{JAPAN ONLY}A binary call options buyer will benefit from a correct prediction that the asset price will rise above the strike price by the judgment time.');
        push @texts, $self->localize('{JAPAN ONLY}When buying a vanilla call option, the break-even price at the exercise point is the strike price plus the option price paid in units of the underlying.');
        push @texts, $self->localize('{JAPAN ONLY}When buying a vanilla put option, the break-even price at the exercise point is the strike price minus the option price paid in units of the underlying.');
        push @texts, $self->localize('{JAPAN ONLY}Using binary options for hedging a position in the underlying asset means that only part of the loss or gain can be hedged, because the payout amount is fixed.');
        push @texts, $self->localize('{JAPAN ONLY}It is possible to use two binary options to make a profit if the asset price settles inbetween the two strikes. It is also possible to buy a single range option that will achieve the same result.');
        push @texts, $self->localize('{JAPAN ONLY}It is possible to use two binary options to make a profit if the asset price settles outside the two strikes. It is also possible to buy a single range option that will achieve the same result.');
        push @texts, $self->localize('{JAPAN ONLY}In Japan there are defined trading periods for binary options must be 2 hours or longer, and all trades must be conducted at the start of each trading period.');
        push @texts, $self->localize('{JAPAN ONLY}A bought or sold binary option may be closed-out before exercise time by selling or buying-back the option, or alternatively by cancelling.');
        push @texts, $self->localize('{JAPAN ONLY}In contrast to other types of FX options, short positions in FX Binary Options cannot be closed-out as they are not subject to loss-cut regulations.');
        push @texts, $self->localize('{JAPAN ONLY}Short positions in FX Binary Options must be covered by initial margin and any further losses must be covered by further margin deposits.');
        push @texts, $self->localize("{JAPAN ONLY}Although customers and brokers will set limits on customers trading losses, even if those losses are exceeded, it is the customer's responsibility to close the position and so mandatory loss-cuts will not be executed by the broker company.");
        push @texts, $self->localize('{JAPAN ONLY}Options may be European or American style of exercise, and those which can be exercised at only one expiry time are the European style options.');
        push @texts, $self->localize('{JAPAN ONLY}For a call option, if the price of the underlying asset is higher than the option exercise price, it is know as an in-the-money option.');
        push @texts, $self->localize('{JAPAN ONLY}For a call option, if the price of the underlying asset is higher than the option exercise price, it is know as an out-of-the-money option.');
        push @texts, $self->localize('{JAPAN ONLY}For both call and put options, if the underlying asset price is the same as the exercise price, it is known as an at-the-money option.');
        push @texts, $self->localize('{JAPAN ONLY}For a put option, if the underlying asset price is lower than the option exercise price, it is known as an out-of-the-money option.');
        push @texts, $self->localize('{JAPAN ONLY}For a put option, if the underlying asset price is higher than the option exercise price, it is known as an in-the-money option.');
        push @texts, $self->localize('{JAPAN ONLY}The Exercise Price is the level at which the option buyer has the right to trade the underlying, and is also used for binary options to determine whether the buyer should receive a payout.');
        push @texts, $self->localize('{JAPAN ONLY}The Exit Price is the price that is observed at the judgment time, and is used to determine whether a payout should be made.');
        push @texts, $self->localize('{JAPAN ONLY}The payout is the amount that the option seller must pay to the buyer if the buyer exercises his right when the conditions for a payout have been satisfied.');
        push @texts, $self->localize('{JAPAN ONLY}In OTC currency binary options trading, if the exchange rate during the trading period moves by more than expected in one direction, and there are no longer any exercise prices which can continue to trade, it is possible under certain conditions to add further exercise prices. However, even when further exercise price have been added, the prices of the original options will not be affected.');
        push @texts, $self->localize('{JAPAN ONLY}The exit price is important in binary options. In case of handling the OTC currency-related binary options trading for private individuals, the broker company must perform inspections of the exit prices which have been used for determining option payout, and must check whether there is an error in the data in cases where that the company has used rated data provided by third company.');
        push @texts, $self->localize("{JAPAN ONLY}About OTC currency for binary options trading, summarizes the profit and loss result of all transactions that have been made between the customer, to publish the information in the company's home page, at any time while the customer is doing the transaction before the start, or the transaction, the information Make sure, for that you're willing to trade under the calm judgment, we are committed to a variety of environmental improvement.");
        push @texts, $self->localize('{JAPAN ONLY}For an individual investor, all profits from OTC currency options trading are tax-free.');
        push @texts, $self->localize('{JAPAN ONLY}For an individual investor, profits and losses from OTC currency options traing cannot be combined with profits and losses from margin FX and securities-related OTC options.');
        push @texts, $self->localize('{JAPAN ONLY}Unless special arrangements are made, cooling-off will not be available after OTC binary options trading contract has been made.');
        push @texts, $self->localize('{JAPAN ONLY}If the buyer of an option does not exercise the option rights, there will be no fee payable to the option seller.');
        push @texts, $self->localize('{JAPAN ONLY}If the buyer of an option waives his right to exercise, a transaction in the underlying asset will not be dealt between the seller and the buyer.');
        push @texts, $self->localize('{JAPAN ONLY}The seller of an option should receive the option premium from the buyer, even if the buyer waives the right to exercise the option.');
        push @texts, $self->localize('{JAPAN ONLY}If an option buyer wishes to exercise the option rights, the seller may still reject the deal.');
        push @texts, $self->localize('{JAPAN ONLY}Options are said to be leveraged products because in the case of large moves in the underlying asset price, the values of the options can increase by large amounts compared to the price paid for the option.');
        push @texts, $self->localize('{JAPAN ONLY}The buyer of a vanilla option can choose whether to exercise the option or not. His loss is limited to the price paid for the option, whereas his potential profit is unlimited.');
        push @texts, $self->localize('{JAPAN ONLY}The seller of a vanilla option can not choose whether to exercise the option or not. His profit is limited to the price received for the option, whereas his potential loss is unlimited and could be substantial.');
        push @texts, $self->localize('{JAPAN ONLY}If the exercise period passes without the option being exercised by the buyer, the option premium received by the seller will be the profit made on the trade.');
        push @texts, $self->localize('{JAPAN ONLY}Even if the option is exercise or not exercised, the original option premium remains with the option seller.');
        push @texts, $self->localize('{JAPAN ONLY}The maximum loss for the buyer of an option is the price paid, and the maximium loss for the option seller will be the payout amount minus the opion price he received.');
        push @texts, $self->localize('{JAPAN ONLY}Because option prices are determined by the probability of being exercised, it cannot be said that cheaper options have any natural advantage over expensive options.');
        push @texts, $self->localize('{JAPAN ONLY}Binary options have lower risk than vanilla options for option sellers, because with binary options the maximum loss is fixed.');
        push @texts, $self->localize('{JAPAN ONLY}Even though losses in binary options are limited, it is still necessary to take care not to engage in excessive speculative trading and to moderate your transactions volume.');
        push @texts, $self->localize('{JAPAN ONLY}If the probablility of a payout is 50% then when the potential payout is less than 100% of the price paid for the option, the expected return on the investment will be less than 100%.');
        push @texts, $self->localize('{JAPAN ONLY}It cannot be said that binary options trading is unconditionally advanteous over regular spot fx trading, because investors may lose all of their investment whereas in spot fx trading there will still be some value in the trading position.');
        push @texts, $self->localize('{JAPAN ONLY}The particular details of binary options are all the same, no matter which broking company you trade with.');
        push @texts, $self->localize('{JAPAN ONLY}The price of OTC binary options of the same conditions, (sometimes) the price varies depending on transactions dealers handling financial instruments business.');
        push @texts, $self->localize('{JAPAN ONLY}Price of OTC currency option is the calculated value based on multiple elements and is determined by relative trading basically.');
        push @texts, $self->localize('{JAPAN ONLY}Regarding to the OTC price of financial instruments, in case that financial instruments business operator suggests both of  bid and ask price (or trading price and cancellation price), generally there is a difference of them. This option will be wider as the expiration approaches.');
        push @texts, $self->localize('{JAPAN ONLY}Price of the option, the price of the underlying asset, price fluctuation rate of the underlying assets, the time until the exercise date, subject to any of the impact of interest rates.');
        push @texts, $self->localize('{JAPAN ONLY}The price of an option can be affected by the underlying asset price, by the volatility rate of the underlying asset, or by the time remaining to the exercise time.');
        push @texts, $self->localize('{JAPAN ONLY}Price of call option will be lower interest rates of the underlying assets is low, but the price of the put option, go up when the interest rates of the underlying assets is low.');
        push @texts, $self->localize('{JAPAN ONLY}If the exercise prices and exercise times are the same for an American style and European style option, then the American style option will have a higher price.');
        push @texts, $self->localize('{JAPAN ONLY}In case of the right to buy the underlying asset (call option), when the underlying asset price falls, the option price will increase.');
        push @texts, $self->localize('{JAPAN ONLY}In case of the right to sell the underlying asset (put option), when the underlying asset price rises, the option price will increase.');
        push @texts, $self->localize('{JAPAN ONLY}For an out-of-the-money option, the further away from the underlying asset price that the option exercise price is, the lower the price of the option will be.');
        push @texts, $self->localize('{JAPAN ONLY}For an in-the-money option, the further away from the underlying asset price that the option exercise price is, the lower the price of the option will be.');
        push @texts, $self->localize('{JAPAN ONLY}If implied volatility increases then the prices of both call and put types of plain vanilla options will increase.');
        push @texts, $self->localize('{JAPAN ONLY}As the expected volatility of the underlying asset increases, a plain vanilla option price will move higher.');
        push @texts, $self->localize('{JAPAN ONLY}For a plain vanilla option, as the time to the exercise point shortens, the price of the option will decrease.');
        push @texts, $self->localize('{JAPAN ONLY}An option price is the sum of the intrinsic-value and the time-value.');
        push @texts, $self->localize('{JAPAN ONLY}If the underlying asset price is 100 yen, the exercise price is 80 yen, and the call option price is 45 yen, then it can be said that the option\'s intrinsic-value is 20 yen, and its time-value is 25 yen.');
        push @texts, $self->localize('{JAPAN ONLY}The time-value of an option represents the expected value of the option at the exercise point, and may be positive, even when the intrinsic-value is zero.');
        push @texts, $self->localize('{JAPAN ONLY}As the time to the exercise point shortens, the time-value of a plain vanilla option decreases.');
        push @texts, $self->localize('{JAPAN ONLY}A binary option price cannot exceed the payout amount.');
        push @texts, $self->localize('{JAPAN ONLY}In general a binary option price will not exceed the payout amount.');
        push @texts, $self->localize('{JAPAN ONLY}Unlike a plain vanilla option, an in-the-money binary option will have a lower price, the further away it is from the exercise point.');
        push @texts, $self->localize('{JAPAN ONLY}In general the price of a binary option will be lower than the price of a plain vanilla option because the payout amount is fixed.');
        push @texts, $self->localize('{JAPAN ONLY}A binary option which is out-of-the-money will have a lower price than an option which is in-the-money because the probability of receiving the payout amount is lower.');
        push @texts, $self->localize('{JAPAN ONLY}A binary option which is in-the-money will have a higher value than an option that is out-of-the-money because there will be a higher probability of receiving the payout amount.');
        push @texts, $self->localize('{JAPAN ONLY}As the exercise deadline approaches, the price of an in-the-money binary option will move towards the payout amount.');
        push @texts, $self->localize('{JAPAN ONLY}As the exercise deadline approaches, the price of an out-of-the-money binary option will move towards zero.');
        push @texts, $self->localize('{JAPAN ONLY}The price of a binary option is affected by not only the change in the underlying asset price, but also the change in remaining time to the exercise point.');
        push @texts, $self->localize('{JAPAN ONLY}Implied volatility is a prediction of the future rate of change in the underlying asset.');
        push @texts, $self->localize('{JAPAN ONLY}Historical volatility is a prediction of the future rate of change in the underlying asset.');
        push @texts, $self->localize('{JAPAN ONLY}Delta refers to  a percentage change of the option price with respect to the change in the underlying asset price.');
        push @texts, $self->localize('{JAPAN ONLY}Option prices are normally dependant on elements such as the underlying asset price, the exercise price, the length of time until the exercise point, volatility, and interest rates. Apart from the fixed exercise price, all other elements are changing constantly, so an understanding of the relationships between each element and changes in the options price is necessary for the management of options trading risk.');
        push @texts, $self->localize('{JAPAN ONLY}Option prices are normally dependant on elements such as the underlying asset price, the exercise price, the length of time until the exercise point, volatility, and interest rates. However, when the remaining time to the exercise point is very short, there is no need to consider these when managing option trading risk, as all these elements are constant.');
        push @texts, $self->localize('{JAPAN ONLY}The Black-Scholes model is widely used to calculate theoretical option prices.');
        push @texts, $self->localize('{JAPAN ONLY}A modified version of the Black-Scholes model is widely used to calculate the theoretical prices of binary options.');
        push @texts, $self->localize('{JAPAN ONLY}Congratulations, you have pass the test, our Customer Support will contact you shortly.');
        push @texts, $self->localize('{JAPAN ONLY}Sorry, you have failed the test, please try again after 24 hours.');
        push @texts, $self->localize('{JAPAN ONLY}Dear customer, you are not allowed to take knowledge test until [_1]. Last test taken at [_2].');
        push @texts, $self->localize('{JAPAN ONLY}Dear customer, you\'ve already completed the knowledge test, please proceed to next step.');
        push @texts, $self->localize('{JAPAN ONLY}Please complete the following questions.');
        push @texts, $self->localize('{JAPAN ONLY}The test is unavailable now, test can only be taken again on next business day with respect of most recent test.');
        push @texts, $self->localize('{JAPAN ONLY}[_1] [_2] payout if [_3] is strictly higher or equal than Exercise price at close  on [_4].');
        push @texts, $self->localize('{JAPAN ONLY}[_1] [_2] payout if [_3] is strictly lower than Exercise price at close on [_4].');
        push @texts, $self->localize('{JAPAN ONLY}[_1] [_2] payout if [_3] does not touch Exercise price through close on [_4].');
        push @texts, $self->localize('{JAPAN ONLY}[_1] [_2] payout if [_3] touches Exercise price through close on [_4].');
        push @texts, $self->localize('{JAPAN ONLY}[_1] [_2] payout if [_3] ends on or between low and high values of Exercise price at close on [_4].');
        push @texts, $self->localize('{JAPAN ONLY}[_1] [_2] payout if [_3] ends otside low and high values of Exercise price at close on [_4].');
        push @texts, $self->localize('{JAPAN ONLY}[_1] [_2] payout if [_3] stays between low and high values of Exercise price through close on [_4].');
        push @texts, $self->localize('{JAPAN ONLY}[_1] [_2] payout if [_3] goes ouside of low and high values of Exercise price through close on [_4].');
        push @texts, $self->localize('{JAPAN ONLY}BUY price per unit');
        push @texts, $self->localize('{JAPAN ONLY}SELL price  per unit');
        push @texts, $self->localize('{JAPAN ONLY}Units');
        push @texts, $self->localize('{JAPAN ONLY}Even if all details of the binary options match perfectly, there may still be differences in the prices shown by different broking companies.');
        push @texts, $self->localize('{JAPAN ONLY}Prices for currency options are calculated relative the value of theunderlying spot price, and are dependant on multiple factors which may vary.');
        push @texts, $self->localize('{JAPAN ONLY}Where broking companies show bid and offer prices for purchasing and sell-back of positions, these prices may become further apart the nearer you are to the exercise time.');
        push @texts, $self->localize('{JAPAN ONLY}Option prices depend on the spot price, the time to expiry, the volatility of the spot rate and interest rates.');
        push @texts, $self->localize('{JAPAN ONLY}The price of a vanilla call option will be lower when price of the underlying asset is low, but the price of the put option will be higher when the price of the underlying asset is low.');
        push @texts, $self->localize('{JAPAN ONLY}This knowledge test is required by law. As we provide the test, we know customers better whether the customers are suitable investors to be carried out the binary options trading, and customers can start trading with us.');
        push @texts, $self->localize('{JAPAN ONLY}To invest a binary options investment accurately, the customer are required knowledge and experience related to derivative transactions.');
        push @texts, $self->localize('{JAPAN ONLY}This test is for the purpose of confirming if the customers have basic knowledge related to options trading .');
        push @texts, $self->localize('{JAPAN ONLY}It is determined that proper by the results of this test, if you want to start the transaction, and then also as a trouble on the transaction occurred between the Company , the Company despite missing is knowledge related to options trading trading cause of action and you agree that you will not is that it has admitted .');
        push @texts, $self->localize('{JAPAN ONLY}It is determined the customers have basic knowledge of option trading by the results of the knowledge test. If the customers start trading, the customers need to agree not have lawsuit despite the customer are shortage of knowledge related to options trading, and it cause damages, we admit to open the trading account.');
        push @texts, $self->localize('{JAPAN ONLY}It prohibits the copying of the questions . In addition , You agree that you will not leak to third party');
        push @texts, $self->localize('You need to finish all 20 questions.');


        #strings for digit_infows
        push @texts, $self->localize('Select market');
        push @texts, $self->localize('Number of ticks');
        push @texts, $self->localize('Last digit stats for the latest [_1] ticks on [_2]');

        #strings for my_accountws
        push @texts, $self->localize('You are currently logged in to your real money account with [_1] ([_2]).');
        push @texts, $self->localize('You are currently logged in to your virtual money account ([_2]).');
        push @texts, $self->localize('Deposit [_1] [_2] virtual money into your account [_3]');
        push @texts, $self->localize('Your [_1] account is unavailable. For any questions please contact [_2].');
        push @texts, $self->localize('Your [_1] accounts are unavailable. For any questions please contact [_2].');
        push @texts, $self->localize('Customer Support');

        #strings for tnc_approvalws
        push @texts, $self->localize('[_1] has updated its [_2]. By clicking OK, you confirm that you have read and accepted the updated [_2].');
        push @texts, $self->localize('Terms & Conditions');
        push @texts, $self->localize('Ok');

        #strings for paymentagentws
        push @texts, $self->localize('Amount');
        push @texts, $self->localize('Deposit');
        push @texts, $self->localize('Login ID');
        push @texts, $self->localize('Back');
        push @texts, $self->localize('Confirm');
        push @texts, $self->localize('View your statement');
        push @texts, $self->localize('Please deposit before transfer to client.');
        push @texts, $self->localize('Please fill in the Login ID and Amount you wish to transfer to your Client in the form below:');
        push @texts, $self->localize('Transfer to Login ID');
        push @texts, $self->localize('Please enter a valid amount.');
        push @texts, $self->localize('Our site does not charge any transfer fees.');
        push @texts, $self->localize('Once you click the \'Submit\' button, the funds will be withdrawn from your account and transferred to your Client\'s account.');
        push @texts, $self->localize('Your Client will receive an email notification informing him/her that the transfer has been processed.');
        push @texts, $self->localize('Please confirm the transaction details in order to complete the transfer:');
        push @texts, $self->localize('Transfer to');
        push @texts, $self->localize('Your request to transfer [_1] [_2] from [_3] to [_4] has been successfully processed.');

        #strings for iphistoryws
        push @texts, $self->localize('Date and Time');
        push @texts, $self->localize('Browser');
        push @texts, $self->localize('IP Address');
        push @texts, $self->localize('Status');
        push @texts, $self->localize('Successful');
        push @texts, $self->localize('Failed');
        push @texts, $self->localize('Your account has no Login/Logout activity.');
        push @texts, $self->localize('Login History');

        #strings for reality_check
        push @texts, $self->localize('Please enter a number greater or equal to [_1].');
        push @texts, $self->localize('Please enter a number between [_1].');
        push @texts, $self->localize('Your trading statistics since [_1].');

        #strings for securityws
        push @texts, $self->localize('Unlock Cashier');
        push @texts, $self->localize('Your cashier is locked as per your request - to unlock it, please enter the password.');
        push @texts, $self->localize('Lock Cashier');
        push @texts, $self->localize('An additional password can be used to restrict access to the cashier.');
        push @texts, $self->localize('Update');

        #strings for job details page
        push @texts, $self->localize('Information Technology');
        push @texts, $self->localize('DevOps Manager');
        push @texts, $self->localize('Senior Front-End Developer');
        push @texts, $self->localize('Senior Perl Developer');
        push @texts, $self->localize('Quality Assurance');
        push @texts, $self->localize('Quality Assurance Engineer');
        push @texts, $self->localize('Quantitative Analysis');
        push @texts, $self->localize('Quantitative Developer');
        push @texts, $self->localize('Quantitative Analyst');
        push @texts, $self->localize('Marketing');
        push @texts, $self->localize('Marketing Project Manager');
        push @texts, $self->localize('Social Media Executive');
        push @texts, $self->localize('Country Manager');
        push @texts, $self->localize('Graphic Designers');
        push @texts, $self->localize('Marketing Executives');
        push @texts, $self->localize('Copywriter');
        push @texts, $self->localize('Translator');
        push @texts, $self->localize('Proofreader');
        push @texts, $self->localize('Accounting');
        push @texts, $self->localize('Accounts And Payments Executive');
        push @texts, $self->localize('Compliance');
        push @texts, $self->localize('Compliance Executive');
        push @texts, $self->localize('Anti-Fraud Officer');
        push @texts, $self->localize('Global Customer Service Representatives');
        push @texts, $self->localize('Human Resources');
        push @texts, $self->localize('Human Resource Executive');
        push @texts, $self->localize('Administrator');
        push @texts, $self->localize('Administrative Executive');
        push @texts, $self->localize('Internal Audit');
        push @texts, $self->localize('Internal Auditor');

        #strings for view popup ws
        push @texts, $self->localize('Contract Information');
        push @texts, $self->localize('Contract Expiry');
        push @texts, $self->localize('Contract Sold');
        push @texts, $self->localize('Current');
        push @texts, $self->localize('Open');
        push @texts, $self->localize('Closed');
        push @texts, $self->localize('Entry Level');
        push @texts, $self->localize('Exit Level');
        push @texts, $self->localize('Stop Loss Level');
        push @texts, $self->localize('Stop Profit Level');
        push @texts, $self->localize('Current Level');
        push @texts, $self->localize('Profit/Loss (points)');
        push @texts, $self->localize('not available');
        push @texts, $self->localize('Contract is not started yet');
        push @texts, $self->localize('Price');
        push @texts, $self->localize('Spot Time');
        push @texts, $self->localize('Exit Spot Time');
        push @texts, $self->localize('Exit Spot');
        push @texts, $self->localize('Indicative');
        push @texts, $self->localize('This contract has WON');
        push @texts, $self->localize('This contract has LOST');
        push @texts, $self->localize('Sorry, an error occurred while processing your request.');
        push @texts, $self->localize('There was an error');
        push @texts, $self->localize('Sell at market');
        push @texts, $self->localize('You have sold this contract at [_1] [_2]');
        push @texts, $self->localize('Your transaction reference number is [_1]');
        push @texts, $self->localize('Note');
        push @texts, $self->localize('Contract will be sold at the prevailing market price when the request is received by our servers. This price may differ from the indicated price.');
        push @texts, $self->localize('Contract ID');
        push @texts, $self->localize('Reference ID');
        push @texts, $self->localize('Remaining Time');

        # strings for financial assessment
        push @texts, $self->localize('Financial Assessment');
        push @texts, $self->localize('Forex trading experience');
        push @texts, $self->localize('Forex trading frequency');
        push @texts, $self->localize('Indices trading experience');
        push @texts, $self->localize('Indices trading frequency');
        push @texts, $self->localize('Commodities trading experience');
        push @texts, $self->localize('Commodities trading frequency');
        push @texts, $self->localize('Stocks trading experience');
        push @texts, $self->localize('Stocks trading frequency');
        push @texts, $self->localize('Binary options or other financial derivatives trading experience');
        push @texts, $self->localize('Binary options or other financial derivatives trading frequency');
        push @texts, $self->localize('Other financial instruments trading experience');
        push @texts, $self->localize('Other financial instruments trading frequency');
        push @texts, $self->localize('Industry of Employment');
        push @texts, $self->localize('Level of Education');
        push @texts, $self->localize('Income Source');
        push @texts, $self->localize('Net Annual Income');
        push @texts, $self->localize('Estimated Net Worth');
        push @texts, $self->localize('0-1 year');
        push @texts, $self->localize('1-2 years');
        push @texts, $self->localize('Over 3 years');
        push @texts, $self->localize('0-5 transactions in the past 12 months');
        push @texts, $self->localize('6-10 transactions in the past 12 months');
        push @texts, $self->localize('40 transactions or more in the past 12 months');
        push @texts, $self->localize('Construction');
        push @texts, $self->localize('Education');
        push @texts, $self->localize('Finance');
        push @texts, $self->localize('Health');
        push @texts, $self->localize('Tourism');
        push @texts, $self->localize('Other');
        push @texts, $self->localize('Primary');
        push @texts, $self->localize('Secondary');
        push @texts, $self->localize('Tertiary');
        push @texts, $self->localize('Salaried Employee');
        push @texts, $self->localize('Self-Employed');
        push @texts, $self->localize('Investments & Dividends');
        push @texts, $self->localize('Pension');
        push @texts, $self->localize('Less than $25,000');
        push @texts, $self->localize('$25,000 - $100,000');
        push @texts, $self->localize('$100,000 - $500,000');
        push @texts, $self->localize('Over $500,001');
        push @texts, $self->localize('Less than $100,000');
        push @texts, $self->localize('$100,000 - $250,000');
        push @texts, $self->localize('$250,000 - $1,000,000');
        push @texts, $self->localize('Over $1,000,000');
        push @texts, $self->localize('The financial trading services contained within this site are only suitable for customers who are able to bear the loss of all the money they invest and who understand and have experience of the risk involved in the acquistion of financial contracts. Transactions in financial contracts carry a high degree of risk. If purchased contracts expire worthless, you will suffer a total loss of your investment, which consists of the contract premium.');
        push @texts, $self->localize('Your details have been updated.');
        push @texts, $self->localize('Please complete the following financial assessment form before continuing.');
        push @texts, $self->localize('Due to recent changes in the regulations, we are required to ask our clients to complete the following Financial Assessment. Please note that you will not be able to continue trading until this is completed.');

        # Strings for applicationsws
        push @texts, $self->localize('Applications');
        push @texts, $self->localize('You have not granted access to any applications.');
        push @texts, $self->localize('Permissions');
        push @texts, $self->localize('Last Used');
        push @texts, $self->localize('Never');
        push @texts, $self->localize('Revoke access');
        push @texts, $self->localize('Keep track of your authorised applications.');

        # Strings for lostpasswordws
        push @texts, $self->localize('Please check your email to retrieve the token needed to reset your password.');
        push @texts, $self->localize('[_1] Please click the link below to restart the password recovery process. If you require further assistance, please contact our Customer Support.');
        push @texts, $self->localize('Details');
        push @texts, $self->localize('Password Reset');
        push @texts, $self->localize('Verification Token');
        push @texts, $self->localize('Please check your email for the value of this token');
        push @texts, $self->localize('New Password');
        push @texts, $self->localize('Confirm New Password');
        push @texts, $self->localize('Date of Birth');
        push @texts, $self->localize('Format: yyyy-mm-dd (not required for virtual-money accounts)');
        push @texts, $self->localize('Reset Password');
        push @texts, $self->localize('Your password has been successfully reset. Please log into your account using your new password.');
        push @texts, $self->localize('Verification code format incorrect.');
        push @texts, $self->localize('Password must contains at least 1 digit, 1 uppercase letter and 1 lowercase letter.');
        push @texts, $self->localize('Password does not match.');
        push @texts, $self->localize('Invalid date of birth.');
        push @texts, $self->localize('Failed to reset password. [_1], please retry.');

        #strings for cashierws page
        push @texts, $self->localize('Your cashier is locked as per your request - to unlock it, please click [_1]here');
        push @texts, $self->localize('For added security, please check your email to retrieve the verification token.');
        push @texts, $self->localize('Please choose which currency you would like to transact in.');
        push @texts, $self->localize('There was a problem validating your personal details. Please fix the fields [_1]here');
        push @texts, $self->localize('If you need assistance feel free to contact our [_1]Customer Support');
        push @texts, $self->localize('Your account is not fully authenticated. Please visit the <a href="[_1]">authentication</a> page for more information.');

        for (BOM::Market::Registry->instance->display_markets) {
            my @underlyings;
            if ($_->name eq 'forex' or $_->name eq 'commodities') {
                @underlyings = map { BOM::Market::Underlying->new($_) } BOM::Market::UnderlyingDB->get_symbols_for(
                    market   => $_->name,
                    bet_type => 'ANY',
                );
            } else {
                @underlyings = map { BOM::Market::Underlying->new($_) } BOM::Market::UnderlyingDB->get_symbols_for(
                    market           => $_->name,
                    bet_type         => 'ANY',
                    exclude_disabled => 1

                );
            }
            push @texts, $self->localize($_->display_name);
            push @texts, map { $self->localize($_->display_name) } @underlyings;

            foreach my $submarket (BOM::Market::SubMarket::Registry->instance->find_by_market($_->name)) {
                push @texts, $self->localize($submarket->display_name);
            }
        }

        #add contract categories as well
        my @all_categories = map {BOM::Product::Contract::Category->new($_)} keys %{$contract_categories};
        foreach my $contract_category (@all_categories) {
            if ($contract_category->display_name) {
                push @texts, $self->localize($contract_category->display_name);
            }
        }

        #add contract type as well
        foreach my $contract_type (get_offerings_with_filter('contract_type')) {
            my $display_name = $contract_type_config->{$contract_type}->{display_name};
            if ($display_name) {
                push @texts, $self->localize($display_name);
            }
        }

        my %as_hash = @texts;
        $js .= "texts_json['" . $language . "'] = " . JSON::to_json(\%as_hash) . ";\n";
    }

    return $js;
}

sub _make_nobody_dir {
    my $self = shift;
    my $dir  = shift;
    if (not -d $dir) {
        mkdir $dir;
    }

    my ($login, $pass, $uid, $gid) = getpwnam("nobody");
    chown($uid, $gid, $dir);
    return;
}

has '_localize_handler' => (
    is => 'rw',
);

sub localize {
    my ($self, $text) = @_;
    my $translated = $self->_localize_handler->maketext($text, '[_1]', '[_2]', '[_3]', '[_4]');
    if ($text eq $translated) {    #Not Translated.
        return;
    }
    $text =~ s/[\s.]/_/g;
    return ($text, $translated);
}

1;

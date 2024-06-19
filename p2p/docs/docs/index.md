# Welcome to the P2P Service

## Roadmap & status

1. Move code to new repo -> *done*
2. Refactor bom-events (https://app.clickup.com/t/20696747/FCTARC-197) -> *in progress*
3. Refactor backoffice (https://app.clickup.com/t/20696747/FCTARC-151) -> *not started*
4. Design, implement and integrate P2P database (https://app.clickup.com/t/20696747/P2PS-1862) -> *in progress*
5. Design and implement wallet migration procedure -> *not started*
6. Design, implement API and integrate with monolith -> *not started*
7. Inependent release -> *not started*


## What is P2P?

P2P = Peer to Peer

P2P allows Deriv users to buy and sell Deriv credits from or to other users.

- A user will place an advertisment to sell or buy their Deriv credits.
- Another user will place an order on the advert.
- The users will arrange payment between themselves using a third party payment system.
- Once both users have confirmed the payment has been made, funds are transfered between the 2 Deriv accounts.

Example:<br>
John has $100 in his USD CR account. He creates an advert to sell $100.<br>
John lives in Brazil so the currency of the advert is BRL.<br>
John sets the exchange rate to 5.00, based on current market rate.<br>
John sets some acceptable payment methods, for example Bank Transfer and Skrill.<br>
Mary places an order against the advert to buy $50.<br>
Mary sends 250 BRL to John via Skrill (USD 50 at the exchange rate of 5.00).<br>
Mary clicks "I've paid" in P2P.<br>
John clicks "I've received payment" in P2P.<br>
P2P transfers 50.00 from John's CR account to Mary's CR account.<br>


## Core concepts

**Advertiser**<br>
A Deriv user who has registered for P2P.<br>
Advertisers have:

- A unique P2P nickname which they choose
- Statistics visible to other advertisers such as rating, turnover
- Preferences such as showing or hiding all ads
- Statuses such as temporary ban

**Advert**<br>
An offer to buy or sell Deriv credits.<br>
Adverts have:

- Type (buy or sell)
- Total amount
- Currency for payment
- Supported payment methods
- Exchange rate
- Minimum and maximum order amount
- Active/inactive status

**Order**<br>
Placed against an advert to buy or sell all or part of an advert's amount.<br>
Orders have:

- Status e.g. pending, buyer-confirmed, completed
- Amount

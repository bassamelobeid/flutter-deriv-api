Overview
============================
Authentication/Authorization server for Deriv and third party app login via Deriv. 

Different login flows are supported as web, responsive web and mobile login.

Different methods of login supported are password, singlesignon, social login. As well generating jwt tokens for certain services.

The main login flow creates access keys to authenticate the websocket after a successful login.

Vision
============================
The goal is to develop a secure and modular authentication/authorization server for bom-oauth, potentially introducing it as a new service. To incorporate login methods such as Passkeys, Passwords, Social Login, etc., as microservices through plugins.

In order to improve security and streamline authentication across multiple services, we are transitioning to OAuth 2.0 and leveraging the use of JWT tokens.


TEST
============================

    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/001_structure.t

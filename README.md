# BOM::Config

## Overview
`BOM::Config` is a Perl module designed for comprehensive configuration management within the BOM suite of modules. It focuses on handling configurations for various services and components of an e-commerce platform, leveraging YAML files for configuration data storage.
Note that this does not include feed or market data systems.

## Description
The module provides an efficient and straightforward way to load and manage configurations for different aspects of e-commerce platforms, including pricing, payment agents, third-party integrations, and more. It supports serialized object generation based on state and environment, ensuring adaptable configuration handling.

## Features
- **YAML File Reading:** Reads configuration information from YAML files.
- **Multiple Configuration Support:** Offers methods to retrieve configurations for various services like feed listeners, AES keys, third-party credentials, etc.
- **Chef Integration:** YAML files are rendered using the `binary_config` cookbook in Chef, ensuring a seamless integration with existing infrastructure.
- **Environment Specific Configurations:** Supports configurations tailored to specific environments (e.g., production, QA).
- **Security Focused:** Includes features for handling sensitive data like API keys and payment information with added focus on security in non-production environments.

## Usage Examples

### Getting Node Information

```perl
use BOM::Config;
my $node_config = BOM::Config::node();
my $environment = $node_config->{node}->{environment};
```

### Accessing Third Party Credentials
```perl
my $third_party_config = BOM::Config::third_party();
my $customerio_details = $third_party_config->{customerio};
```

### Handling Payment Agent Configuration
```perl
my $payment_agent_config = BOM::Config::payment_agent();
```
### Retrieving Global App Configuration
To get an instance of the global app-config class, use the BOM::Config::Runtime module. This instance provides access to the application's configuration settings.
```perl
use BOM::Config::Runtime;
my $config = BOM::Config::Runtime->instance->app_config();
```

## Do's and Don'ts

### Do's
1. **Read and Understand Configurations**: Before using a configuration, make sure you understand its purpose and how it affects the system.
2. **Follow Security Best Practices**: Handle sensitive information, like API keys and credentials, with utmost care. Ensure they are not exposed in non-production environments.
3. **Use Environment-Specific Configurations**: Leverage the module's ability to handle different environments. Use appropriate configurations for development, testing, and production.
4. **Keep YAML Files Updated**: Regularly update the YAML configuration files to reflect the latest settings and parameters of your e-commerce platform.
5. **Test Configurations Thoroughly**: Before deploying changes, test configurations in a controlled environment to prevent unexpected issues.
6. **Document Custom Changes**: If you make custom changes to configurations or the module, document them for future reference and for other team members.

### Don'ts
1. **Don’t Hardcode Sensitive Data**: Avoid hardcoding credentials or sensitive data within the module or your codebase.
2. **Don’t Overwrite Configuration Files Blindly**: Be cautious when modifying configuration files. Overwriting them without understanding the implications can lead to system failures.

Following these guidelines will help ensure that you use the `BOM::Config` module effectively and securely.
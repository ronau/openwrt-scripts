# DynDNS Update Script

A shell script for updating DynDNS records with both IPv4 and IPv6 support. Designed for OpenWrt routers but can be used on any Linux system with the required dependencies.

## Features

- IPv4 address updates
- IPv6 address updates (direct IP and prefix-based)
- Configurable update URL template
- Dry run mode
- Test mode for individual functions
- Detailed logging

### IPv6 Support

The script supports two types of IPv6 updates:

1. Direct IPv6 address updates (`IPV6_DOMAINS`):
   - Updates domains to point to the WAN6 interface's public IPv6 address

2. Prefix-based updates (`IPV6_MAPPINGS`):
   - Uses the WAN6 prefix combined with configured interface IDs
   - Format: "domain/interface_id" (e.g., "example.com/1234")
   - Useful for static IPv6 addresses within your prefix

## Requirements

- ubus (for OpenWrt network interface information), should be present on OpenWrt routers
- nslookup, should be present on virtually all systems
- curl, install via `opkg install curl` on OpenWrt (or using LuCI)
- jq (for JSON parsing), install via `opkg install jq` on OpenWrt (or using LuCI)

## Configuration

Edit the following variables in the script:

### Network Interfaces

```sh
WAN_INTERFACE="wan"
WAN6_INTERFACE="wan6"
```

### Domain Configuration

```sh
# List of domains (space-separated) that should point to the WAN interface's IPv4 address
IPV4_DOMAINS="mydomain1.tld mydomain2.tld mydomain3.tld"

# List of domains that should point to the WAN6 interface's IPv6 address
IPV6_DOMAINS="mydomain1.tld mydomain2.tld mydomain3.tld"

# List of domains (space-separated) that should point to IPv6 addresses of devices behind your router
# Each entry consists of a domain name and the IPv6 interface ID of the target device, separated by a slash.
IPV6_MAPPINGS="host1.mydomain1.tld/1234:45ff:fe67:890a host2.mydomain1.tld/5678:90ff:feab:cdef"
```

Use empty strings for the functionality you don't need (e.g. if you don't have a public IPv6 address, set `IPV6_DOMAINS=""` and `IPV6_MAPPINGS=""`).


### DynDNS Provider Settings

```sh
DYNDNS_URL_TEMPLATE="https://dynamicdns.provider.com/update?username=${DYNDNS_USERNAME}&password=${DYNDNS_PASSWORD}&hostname=%domain%&myip=%ip%"
DYNDNS_USERNAME="your-username"
DYNDNS_PASSWORD="your-password"
```

### Additional Settings

```sh
CURL_OPTS="-sS" # Curl options
LOG_FILE="/var/log/dyndns_update.log" # Log file location
```

Depending on your individual setup, the following additional curl options might be useful:

```sh
--interface pppoe-wan --capath /etc/ssl/certs
```


## Usage

### Normal Operation

./dyndns.sh

### Dry Run Mode
Test what would happen without making actual updates:

./dyndns.sh dry-run

### Test Mode

Test individual functions:

```sh
# Show available test functions
./dyndns.sh test

# Test WAN IP detection
./dyndns.sh test get_wan_ip

# Test WAN6 IP detection
./dyndns.sh test get_wan6_ip

# Test WAN6 prefix detection
./dyndns.sh test get_wan6_prefix

# Test DNS IP resolution (A or AAAA)
./dyndns.sh test get_dns_ip mydomain1.tld A

# Test update URL call
./dyndns.sh test do_curl_update mydomain1.tld 192.168.1.1
```

## Logging

All operations are logged to the configured log file (default: `/var/log/dyndns_update.log`).


## OpenWrt Installation

1. Copy the script to `/usr/local/bin/dyndns.sh`
    - Create the directory if it doesn't exist: `mkdir -p -m 755 /usr/local/bin`
    - Optionally, add this directory to PATH in `/etc/profile`: `export PATH=$PATH:/usr/local/bin`
2. Make it executable: `chmod +x /usr/local/bin/dyndns.sh`
3. Configure your settings
4. Add a cron job to run it periodically:
   ```sh
   # Run every hour
   0 * * * * /usr/local/bin/dyndns.sh
   ```
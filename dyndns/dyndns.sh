#!/bin/sh

# Required packages: curl, nslookup, ubus, jq


# Configuration
WAN_INTERFACE="wan"
WAN6_INTERFACE="wan6"

# IPV4_DOMAINS: List of domains that should point to the WAN interface's IPv4 address
IPV4_DOMAINS="mydomain1.tld mydomain2.tld mydomain3.tld"

# IPV6_DOMAINS: List of domains that should point to the WAN6 interface's IPv6 address
IPV6_DOMAINS="mydomain1.tld mydomain2.tld mydomain3.tld"

# IPV6_MAPPINGS format: "domain/interface_id domain2/interface_id2"
# Each entry consists of a domain name and its corresponding interface ID, separated by a slash.
IPV6_MAPPINGS="host1.mydomain1.tld/1234:45ff:fe67:890a host2.mydomain1.tld/5678:90ff:feab:cdef"

DYNDNS_USERNAME="your-username"
DYNDNS_PASSWORD="your-password"
# Update URL template. Use %domain% and %ip% as placeholders
DYNDNS_URL_TEMPLATE="https://dynamicdns.provider.com/update?username=${DYNDNS_USERNAME}&password=${DYNDNS_PASSWORD}&hostname=%domain%&myip=%ip%"

# Additional curl parameters (e.g. "-k" to allow insecure connections, "-4" to force IPv4)
# Used when calling DynDNS Update URL
CURL_OPTS="-sS"

LOG_FILE="/var/log/dyndns_update.log"

# Dry run flag (set by command line argument)
DRY_RUN=0




# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Get current WAN IP address (using OpenWrt's ubus)
get_wan_ip() {
    wan_ip=$(ubus call network.interface.${WAN_INTERFACE} status | jq -r '.["ipv4-address"][0].address')
    if [ -z "$wan_ip" ]; then
        log_message "Error: Could not determine WAN IP address"
        exit 1
    fi
    echo "$wan_ip"
}

# Get current WAN6 IP address (using OpenWrt's ubus)
get_wan6_ip() {
    wan6_ip=$(ubus call network.interface.${WAN6_INTERFACE} status | jq -r '.["ipv6-address"][0].address')
    if [ -z "$wan6_ip" ]; then
        log_message "Error: Could not determine WAN6 IP address"
        exit 1
    fi
    echo "$wan6_ip"
}

# Get current WAN6 prefix (using OpenWrt's ubus)
get_wan6_prefix() {
    prefix=$(ubus call network.interface.${WAN6_INTERFACE} status | jq -r '.["ipv6-prefix"][0].address')
    prefix_length=$(ubus call network.interface.${WAN6_INTERFACE} status | jq -r '.["ipv6-prefix"][0].mask')
    
    if [ -z "$prefix" ] || [ -z "$prefix_length" ]; then
        log_message "Error: Could not determine WAN6 prefix"
        exit 1
    fi
    
    # Return the prefix with its length
    echo "${prefix}/${prefix_length}"
}

# Get current DNS A or AAAA record
get_dns_ip() {
    domain="$1"
    record_type="$2"  # "A" or "AAAA"
    
    case "$record_type" in
        "A")
            dns_ip=$(nslookup -type=A "$domain" 2>/dev/null | grep -A1 "^Name:" | grep "^Address:" | awk '{print $2}')
            ;;
        "AAAA")
            dns_ip=$(nslookup -type=AAAA "$domain" 2>/dev/null | grep -A1 "^Name:" | grep "^Address:" | awk '{print $2}')
            ;;
        *)
            log_message "Error: Invalid record type '$record_type'. Must be 'A' or 'AAAA'"
            exit 1
            ;;
    esac
    
    if [ -z "$dns_ip" ]; then
        log_message "Error: Could not resolve DNS $record_type record for $domain"
        exit 1
    fi
    echo "$dns_ip"
}

# Perform the actual DynDNS update call
do_curl_update() {
    domain="$1"
    current_ip="$2"
    update_url=$(echo "$DYNDNS_URL_TEMPLATE" | sed "s/%domain%/${domain}/g; s/%ip%/${current_ip}/g")
    
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY RUN: curl -w \"\\n%{http_code}\" $CURL_OPTS \"$update_url\""
        log_message "DRY RUN: curl -w \"\\n%{http_code}\" $CURL_OPTS \"$update_url\""
        return 0
    else
        # Use -w to get HTTP status code
        response=$(curl -w "\n%{http_code}" $CURL_OPTS "$update_url")
        return_code=$?
        
        # Extract status code (last line) and response body
        http_code=$(echo "$response" | tail -n1)
        response_body=$(echo "$response" | sed '$d')
        
        if [ $return_code -ne 0 ]; then
            log_message "Error: curl failed for ${domain} with return code ${return_code}"
            return $return_code
        elif [ "$http_code" != "200" ]; then
            log_message "Error: update failed for ${domain} with HTTP status ${http_code}: ${response_body}"
            return 1
        else
            log_message "Successfully updated ${domain} to IP ${current_ip}"
            return 0
        fi
    fi
}

# Common update logic for both IPv4 and IPv6
update_domains() {
    ip_type="$1"          # "v4" or "v6" or "v6_prefix"
    current_ip="$2"        # Current WAN IP or prefix
    domains_to_update="$3" # Space-separated list of domains
    success=0
    failed=0
    
    if [ -n "$domains_to_update" ]; then
        log_message "Updating $ip_type records for the following domains: $domains_to_update"
        for domain in $domains_to_update; do
            case "$ip_type" in
                "v4"|"v6")  # separate this, if v4 and v6 need to be updated differently
                    if do_curl_update "$domain" "$current_ip"; then
                        success=$((success + 1))
                    else
                        failed=$((failed + 1))
                    fi
                    ;;
                "v6_prefix")
                    # Get interface_id for this domain and construct full IPv6 address
                    interface_id=$(echo "$domain" | cut -d'/' -f2)
                    domain=$(echo "$domain" | cut -d'/' -f1)
                    full_ip=$(echo "$current_ip" | cut -d'/' -f1)::${interface_id}
                    if do_curl_update "$domain" "$full_ip"; then
                        success=$((success + 1))
                    else
                        failed=$((failed + 1))
                    fi
                    ;;
            esac
        done
        
        # Log summary of updates
        if [ $failed -eq 0 ]; then
            log_message "All ${success} $ip_type domain(s) updated successfully"
            return 0
        else
            log_message "$ip_type update completed with ${success} successful and ${failed} failed updates"
            return 1
        fi
    else
        log_message "All $ip_type domains are up to date"
        return 0
    fi
}

# IPv4 main logic
main4() {
    wan_ip=$(get_wan_ip)
    domains_to_update=""
    
    # Check each domain's current IP
    for domain in $IPV4_DOMAINS; do
        dns_ip=$(get_dns_ip "$domain" "A")
        
        if [ "$wan_ip" = "$dns_ip" ]; then
            log_message "IP addresses match for ${domain} (${wan_ip}). No update needed."
        else
            log_message "IP mismatch detected for ${domain} - WAN IP: ${wan_ip}, DNS IP: ${dns_ip}"
            domains_to_update="$domains_to_update $domain"
        fi
    done
    
    # Update domains with IPv4 addresses
    if [ -n "$domains_to_update" ]; then
        update_domains "v4" "$wan_ip" "$domains_to_update"
        return $?
    fi
    return 0
}

# IPv6 direct IP logic
main6_ip() {
    wan6_ip=$(get_wan6_ip)
    domains_to_update_ip=""
    
    # Check each domain that should point to WAN6 IP
    for domain in $IPV6_DOMAINS; do
        dns_ip=$(get_dns_ip "$domain" "AAAA")
        
        if [ "$wan6_ip" = "$dns_ip" ]; then
            log_message "IPv6 addresses match for ${domain} (${wan6_ip}). No update needed."
        else
            log_message "IPv6 address mismatch detected for ${domain} - WAN IP: ${wan6_ip}, DNS IP: ${dns_ip}"
            domains_to_update_ip="$domains_to_update_ip $domain"
        fi
    done
    
    # Update domains with direct IP
    if [ -n "$domains_to_update_ip" ]; then
        update_domains "v6" "$wan6_ip" "$domains_to_update_ip"
        return $?
    fi
    return 0
}

# IPv6 prefix mapping logic
main6_prefix() {
    wan6_prefix=$(get_wan6_prefix)
    domains_to_update_prefix=""
    
    # Check each domain's current IPv6 prefix mapping
    for ipv6_entry in $IPV6_MAPPINGS; do
        domain=$(echo "$ipv6_entry" | cut -d'/' -f1)
        interface_id=$(echo "$ipv6_entry" | cut -d'/' -f2)
        dns_ip=$(get_dns_ip "$domain" "AAAA")
        
        # Extract prefix from DNS AAAA record (everything before last 4 segments)
        dns_prefix=$(echo "$dns_ip" | sed -E 's/:[^:]*:[^:]*:[^:]*:[^:]*$//')
        
        # Extract prefix from WAN6 prefix (remove prefix length and trailing colons)
        current_prefix=$(echo "$wan6_prefix" | cut -d'/' -f1 | sed 's/::$//')
        
        if [ "$current_prefix" = "$dns_prefix" ]; then
            log_message "IPv6 prefixes match for ${domain} (${current_prefix}). No update needed."
        else
            log_message "IPv6 prefix mismatch detected for ${domain} - WAN prefix: ${current_prefix}, DNS prefix: ${dns_prefix}"
            domains_to_update_prefix="$domains_to_update_prefix $ipv6_entry"
        fi
    done
    
    # Update domains with prefix mappings
    if [ -n "$domains_to_update_prefix" ]; then
        update_domains "v6_prefix" "$wan6_prefix" "$domains_to_update_prefix"
        return $?
    fi
    return 0
}

# Main logic
main() {
    main4
    main4_result=$?
    
    main6_ip
    main6_ip_result=$?
    
    main6_prefix
    main6_prefix_result=$?
    
    # Return failure if any update failed
    [ $main4_result -eq 0 ] && [ $main6_ip_result -eq 0 ] && [ $main6_prefix_result -eq 0 ]
    return $?
}

# Test functions
test_get_wan_ip() {
    echo "Testing get_wan_ip..."
    ip=$(get_wan_ip)
    return_code=$?
    echo "WAN IP: $ip"
    if [ $return_code -ne 0 ]; then
        echo "ERROR: Function returned $return_code"
        return $return_code
    fi
}

test_get_wan6_ip() {
    echo "Testing get_wan6_ip..."
    ip=$(get_wan6_ip)
    return_code=$?
    echo "WAN6 IP: $ip"
    if [ $return_code -ne 0 ]; then
        echo "ERROR: Function returned $return_code"
        return $return_code
    fi
}

test_get_wan6_prefix() {
    echo "Testing get_wan6_prefix..."
    prefix=$(get_wan6_prefix)
    return_code=$?
    echo "WAN6 prefix: $prefix"
    if [ $return_code -ne 0 ]; then
        echo "ERROR: Function returned $return_code"
        return $return_code
    fi
}

test_get_dns_ip() {
    if [ -z "$1" ]; then
        echo "Usage: $0 test_get_dns_ip <domain> [A|AAAA]"
        return 1
    fi
    domain="$1"
    record="${2:-A}"  # Default to A record if not specified
    echo "Testing get_dns_ip for $domain ($record)..."
    ip=$(get_dns_ip "$domain" "$record")
    return_code=$?
    echo "DNS IP: $ip"
    if [ $return_code -ne 0 ]; then
        echo "ERROR: Function returned $return_code"
        return $return_code
    fi
}

test_do_curl_update() {
    if [ -z "$2" ]; then
        echo "Usage: $0 test_do_curl_update <domain> <ip>"
        return 1
    fi
    domain="$1"
    ip="$2"
    echo "Testing do_curl_update for $domain with IP $ip..."
    do_curl_update "$domain" "$ip"
    echo "Return code: $?"
}

# Test mode handler
test_mode() {
    case "$1" in
        "get_wan_ip")
            test_get_wan_ip
            ;;
        "get_wan6_ip")
            test_get_wan6_ip
            ;;
        "get_wan6_prefix")
            test_get_wan6_prefix
            ;;
        "get_dns_ip")
            test_get_dns_ip "$2" "$3"
            ;;
        "do_curl_update")
            test_do_curl_update "$2" "$3"
            ;;
        *)
            echo "Available test functions:"
            echo "  get_wan_ip        - Test WAN IP detection"
            echo "  get_wan6_ip       - Test WAN6 IP detection"
            echo "  get_wan6_prefix   - Test WAN6 prefix detection"
            echo "  get_dns_ip        - Test DNS IP resolution (args: domain [A|AAAA])"
            echo "  do_curl_update    - Test update URL call (args: domain ip)"
            return 1
            ;;
    esac
}

# Main script logic
case "$1" in
    "test")
        shift
        test_mode "$@"
        ;;
    "dry-run")
        DRY_RUN=1
        main
        ;;
    *)
        main
        ;;
esac

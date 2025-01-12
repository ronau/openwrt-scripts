#!/bin/sh

# Required packages: curl, nslookup, ubus, jq


# Configuration
DOMAINS="your-domain1.example.com your-domain2.example.com your-domain3.example.com"
PASSWORD="your-password"
LOG_FILE="/var/log/dyndns_update.log"
WAN_INTERFACE="wan"
WAN6_INTERFACE="wan6"

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
            dns_ip=$(nslookup -type=A "$domain" 2>/dev/null | grep "Address:" | tail -n1 | awk '{print $2}')
            ;;
        "AAAA")
            dns_ip=$(nslookup -type=AAAA "$domain" 2>/dev/null | grep "Address:" | tail -n1 | awk '{print $2}')
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
    update_url="https://dynamicdns.provider.com/update?hostname=${domain}&password=${PASSWORD}"
    
    response=$(curl -s "$update_url")
    return_code=$?
    
    if [ $return_code -eq 0 ]; then
        log_message "Successfully updated DynDNS record for ${domain} to ${current_ip}"
        return 0
    else
        log_message "Failed to update DynDNS record for ${domain}: ${response}"
        return 1
    fi
}

# Update DynDNS record for multiple domains
update_dyndns() {
    current_ip="$1"
    success=0
    failed=0
    
    # Loop through each domain and update
    for domain in $DOMAINS; do
        if do_curl_update "$domain" "$current_ip"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    # Return success only if all updates succeeded
    if [ $failed -eq 0 ]; then
        log_message "All ${success} domain(s) updated successfully"
        return 0
    else
        log_message "Update completed with ${success} successful and ${failed} failed updates"
        return 1
    fi
}

# Main logic
main() {
    wan_ip=$(get_wan_ip)
    update_needed=0
    domains_to_update=""
    
    # Check each domain's current IP
    for domain in $DOMAINS; do
        dns_ip=$(get_dns_ip "$domain")
        
        if [ "$wan_ip" = "$dns_ip" ]; then
            log_message "IP addresses match for ${domain} (${wan_ip}). No update needed."
        else
            log_message "IP mismatch detected for ${domain} - WAN IP: ${wan_ip}, DNS IP: ${dns_ip}"
            update_needed=1
            domains_to_update="$domains_to_update $domain"
        fi
    done
    
    # Update only the domains that need it
    if [ $update_needed -eq 1 ]; then
        for domain in $domains_to_update; do
            do_curl_update "$domain" "$wan_ip"
        done
    else
        log_message "All domains are up to date"
    fi
}

# Run main function
main

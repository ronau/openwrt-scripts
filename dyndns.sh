#!/bin/sh

# Required packages: curl, nslookup, ubus, jq


# Configuration
WAN_INTERFACE="wan"
WAN6_INTERFACE="wan6"

IPV4_DOMAINS="your-domain1.example.com your-domain2.example.com your-domain3.example.com"
# IPV6_MAPPINGS format: "domain/interface_id domain2/interface_id2"
# Each entry consists of a domain name and its corresponding interface ID, separated by a slash.
IPV6_MAPPINGS="your-domain1.example.com/1234 your-domain2.example.com/5678"

# IPV6_DOMAINS: List of domains that should point to the WAN6 interface's IPv6 address
IPV6_DOMAINS="ipv6.example.com ipv6.example2.com"

DYNDNS_PASSWORD="your-password"
LOG_FILE="/var/log/dyndns_update.log"

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
    update_url="https://dynamicdns.provider.com/update?hostname=${domain}&password=${DYNDNS_PASSWORD}"
    
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
    
    update_domains "v4" "$wan_ip" "$domains_to_update"
    return $?
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
        
        # Extract prefix from WAN6 prefix (remove prefix length)
        current_prefix=$(echo "$wan6_prefix" | cut -d'/' -f1)
        
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

# Main logic
main() {
    main4
    main4_result=$?
    
    main6_prefix
    main6_prefix_result=$?
    
    main6_ip
    main6_ip_result=$?
    
    # Return failure if any update failed
    [ $main4_result -eq 0 ] && [ $main6_prefix_result -eq 0 ] && [ $main6_ip_result -eq 0 ]
    return $?
}

# Run main function
main

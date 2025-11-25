#!/usr/bin/env bash

# Function to check if CIDR1 is contained within CIDR2
cidr_contains() {
    local cidr1="$1"  # potentially contained
    local cidr2="$2"  # potentially containing
    
    # Extract network and prefix
    local net1="${cidr1%/*}" prefix1="${cidr1#*/}"
    local net2="${cidr2%/*}" prefix2="${cidr2#*/}"
    
    # If prefix2 >= prefix1, cidr2 cannot contain cidr1
    [[ "$prefix2" -ge "$prefix1" ]] && return 1
    
    # Convert IPs to integers for comparison
    local ip1_int ip2_int mask
    
    ip1_int=$(printf '%d\n' $(echo "$net1" | sed 's/\./ /g' | xargs printf '0x%02x%02x%02x%02x\n'))
    ip2_int=$(printf '%d\n' $(echo "$net2" | sed 's/\./ /g' | xargs printf '0x%02x%02x%02x%02x\n'))
    
    # Create mask for the more permissive network
    mask=$((0xFFFFFFFF << (32 - prefix2)))
    
    # Check if both IPs are in the same network when masked
    [[ $((ip1_int & mask)) -eq $((ip2_int & mask)) ]]
}

# Read all CIDRs into array
mapfile -t cidrs < <(cat)

# Remove empty lines
cidrs=("${cidrs[@]//[[:space:]]/}")
cidrs=("${cidrs[@]/#[[:space:]]*/}")

# Sort by prefix length (most permissive first)
IFS=$'\n' sorted_cidrs=($(printf '%s\n' "${cidrs[@]}" | sort -t/ -k2 -n))

optimized=()

for cidr in "${sorted_cidrs[@]}"; do
    [[ -z "$cidr" ]] && continue
    
    is_redundant=false
    
    # Check if this CIDR is covered by any existing optimized CIDR
    for existing in "${optimized[@]}"; do
        if cidr_contains "$cidr" "$existing"; then
            is_redundant=true
            break
        fi
    done
    
    if [[ "$is_redundant" == "false" ]]; then
        optimized+=("$cidr")
    fi
done

# Output optimized list, sorted
printf '%s\n' "${optimized[@]}" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n

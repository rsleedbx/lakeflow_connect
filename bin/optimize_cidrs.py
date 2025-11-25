#!/usr/bin/env python3
import sys

try:
    from netaddr import IPNetwork, cidr_merge
    HAS_NETADDR = True
except ImportError:
    import ipaddress
    HAS_NETADDR = False

def optimize_cidrs_netaddr(cidrs):
    """Remove redundant CIDR ranges using netaddr (preferred)"""
    try:
        # Convert strings to IPNetwork objects
        networks = [IPNetwork(cidr.strip()) for cidr in cidrs if cidr.strip()]
        
        # Use netaddr's cidr_merge to automatically optimize overlapping ranges
        merged = cidr_merge(networks)
        
        # Convert back to strings and sort
        return sorted([str(net) for net in merged])
    except Exception as e:
        print(f"Error processing CIDRs with netaddr: {e}", file=sys.stderr)
        return sorted(set(cidrs))

def optimize_cidrs_stdlib(cidrs):
    """Remove redundant CIDR ranges using standard library"""
    try:
        # Convert to ipaddress objects and sort by prefix length (most permissive first)
        networks = []
        for cidr in cidrs:
            if cidr.strip():
                networks.append(ipaddress.ip_network(cidr.strip(), strict=False))
        
        networks.sort(key=lambda x: x.prefixlen)
        
        optimized = []
        for network in networks:
            # Check if this network is already covered by a more permissive one
            is_redundant = False
            for existing in optimized:
                if network.subnet_of(existing):
                    is_redundant = True
                    break
            
            if not is_redundant:
                optimized.append(network)
        
        return sorted([str(net) for net in optimized])
    except Exception as e:
        print(f"Error processing CIDRs: {e}", file=sys.stderr)
        return sorted(set(cidrs))

def optimize_cidrs(cidrs):
    """Remove redundant CIDR ranges"""
    if HAS_NETADDR:
        return optimize_cidrs_netaddr(cidrs)
    else:
        return optimize_cidrs_stdlib(cidrs)

if __name__ == "__main__":
    # Read from stdin
    data = sys.stdin.read().strip()
    cidrs = data.split('\n') if data else []
    
    # Filter out empty lines
    cidrs = [cidr.strip() for cidr in cidrs if cidr.strip()]
    
    # Optimize and output
    optimized = optimize_cidrs(cidrs)
    for cidr in optimized:
        print(cidr)

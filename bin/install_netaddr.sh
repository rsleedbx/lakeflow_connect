#!/usr/bin/env bash

# Script to install netaddr for better CIDR optimization
# Usage: ./install_netaddr.sh

echo "Installing netaddr for optimal CIDR range optimization..."

# Try different installation methods
if command -v pip3 >/dev/null 2>&1; then
    echo "Attempting to install with pip3..."
    if pip3 install --user netaddr 2>/dev/null; then
        echo "✅ netaddr installed successfully with pip3 --user"
        exit 0
    elif pip3 install --break-system-packages netaddr 2>/dev/null; then
        echo "✅ netaddr installed successfully with --break-system-packages"
        exit 0
    fi
fi

# Try with brew if available
if command -v brew >/dev/null 2>&1; then
    echo "Attempting to install with brew..."
    if brew install python-netaddr 2>/dev/null; then
        echo "✅ netaddr installed successfully with brew"
        exit 0
    fi
fi

# Try with conda if available
if command -v conda >/dev/null 2>&1; then
    echo "Attempting to install with conda..."
    if conda install -c conda-forge netaddr -y 2>/dev/null; then
        echo "✅ netaddr installed successfully with conda"
        exit 0
    fi
fi

echo "⚠️  Could not install netaddr automatically."
echo "   The script will fall back to using Python's standard ipaddress library."
echo "   For better performance, install netaddr manually:"
echo "   - pip3 install --user netaddr"
echo "   - brew install python-netaddr"
echo "   - conda install -c conda-forge netaddr"

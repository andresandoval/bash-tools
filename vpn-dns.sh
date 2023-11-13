#!/bin/bash

echo "Getting current DNS servers, this takes a couple of seconds"

/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -Command '
$ErrorActionPreference="SilentlyContinue"
Get-NetAdapter -InterfaceDescription "PANGP Virtual Ethernet Adapter*" | Get-DnsClientServerAddress | Select -ExpandProperty ServerAddresses
Get-NetAdapter | ?{-not ($_.InterfaceDescription -like "PANGP Virtual Ethernet Adapter*") } | Get-DnsClientServerAddress | Select -ExpandProperty ServerAddresses
' | \
        awk 'BEGIN { print "# Generated by vpn fix func on", strftime("%c"); print } { print "nameserver", $1 }' | \
        tr -d '\r' > /etc/resolv.conf
#clear

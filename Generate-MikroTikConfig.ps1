[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object]$Default = $null,

        [switch]$Required
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        if ($Required) {
            throw "Missing required property '$Name'."
        }

        return $Default
    }

    return $property.Value
}

function ConvertTo-RosString {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ""
    }

    $escaped = $Value.Replace("\", "\\")
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace('$', '\$')
    $escaped = $escaped.Replace("`r", "")
    $escaped = $escaped.Replace("`n", "\n")
    return '"' + $escaped + '"'
}

function Get-IpWithoutPrefix {
    param([Parameter(Mandatory = $true)][string]$Address)
    return ($Address -split "/", 2)[0]
}

function Add-Line {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Lines,

        [AllowEmptyString()]
        [string]$Text = ""
    )

    [void]$Lines.AppendLine($Text)
}

function Assert-InterfaceName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Name -notmatch '^[A-Za-z0-9_.:+-]+$') {
        throw "Invalid interface name '$Name' in $Context."
    }
}

function Assert-UniqueInterfaceAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Assignments,

        [Parameter(Mandatory = $true)]
        [string]$Interface,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    if ($Assignments.ContainsKey($Interface)) {
        throw "Interface '$Interface' is assigned to both '$($Assignments[$Interface])' and '$Purpose'."
    }

    $Assignments[$Interface] = $Purpose
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json

$role = [string](Get-PropertyValue -Object $config -Name "role" -Required)
$identity = [string](Get-PropertyValue -Object $config -Name "identity" -Required)
$bridge = [string](Get-PropertyValue -Object $config -Name "bridge" -Required)
$timeZone = [string](Get-PropertyValue -Object $config -Name "timeZone" -Default "Europe/Kyiv")
$requireCleanConfig = [bool](Get-PropertyValue -Object $config -Name "requireCleanConfig" -Default $true)
$wirelessDriver = [string](Get-PropertyValue -Object $config -Name "wirelessDriver" -Default "none")
$trunkPorts = @((Get-PropertyValue -Object $config -Name "trunkPorts" -Required))
$vlans = @((Get-PropertyValue -Object $config -Name "vlans" -Required))
$managementVlanId = [int](Get-PropertyValue -Object $config -Name "managementVlan" -Required)
$wifi = Get-PropertyValue -Object $config -Name "wifi" -Default $null

if ($role -notin @("gateway", "access-point")) {
    throw "role must be 'gateway' or 'access-point'."
}

if ($wirelessDriver -notin @("none", "wifi", "wireless")) {
    throw "wirelessDriver must be 'none', 'wifi', or 'wireless'."
}

if ($trunkPorts.Count -eq 0) {
    throw "At least one trunk port is required."
}

if ($vlans.Count -eq 0) {
    throw "At least one VLAN is required."
}

Assert-InterfaceName -Name $bridge -Context "bridge"

$vlanById = @{}
$interfaceAssignments = @{}
$requiredInterfaces = New-Object System.Collections.Generic.HashSet[string]

foreach ($trunkPort in $trunkPorts) {
    $trunkPort = [string]$trunkPort
    Assert-InterfaceName -Name $trunkPort -Context "trunkPorts"
    Assert-UniqueInterfaceAssignment -Assignments $interfaceAssignments -Interface $trunkPort -Purpose "trunk"
    [void]$requiredInterfaces.Add($trunkPort)
}

foreach ($vlan in $vlans) {
    $id = [int](Get-PropertyValue -Object $vlan -Name "id" -Required)
    $name = [string](Get-PropertyValue -Object $vlan -Name "name" -Required)
    $subnet = [string](Get-PropertyValue -Object $vlan -Name "subnet" -Required)
    $accessPorts = @((Get-PropertyValue -Object $vlan -Name "accessPorts" -Default @()))

    if ($id -lt 1 -or $id -gt 4094) {
        throw "VLAN ID '$id' is outside the supported range 1-4094."
    }

    if ($vlanById.ContainsKey($id)) {
        throw "Duplicate VLAN ID '$id'."
    }

    if ($name -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "VLAN name '$name' contains unsupported characters."
    }

    if ($subnet -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
        throw "VLAN '$name' has an invalid subnet '$subnet'."
    }

    $vlanById[$id] = $vlan

    foreach ($accessPort in $accessPorts) {
        $accessPort = [string]$accessPort
        Assert-InterfaceName -Name $accessPort -Context "VLAN $id accessPorts"
        Assert-UniqueInterfaceAssignment -Assignments $interfaceAssignments -Interface $accessPort -Purpose "VLAN $id access"
        [void]$requiredInterfaces.Add($accessPort)
    }
}

if (-not $vlanById.ContainsKey($managementVlanId)) {
    throw "managementVlan '$managementVlanId' is not present in vlans."
}

$wifiNetworks = @()
$wifiCountry = "Ukraine"
$wifiInstallation = "indoor"
$hasPlaceholderSecrets = $false
if ($null -ne $wifi -and [bool](Get-PropertyValue -Object $wifi -Name "enabled" -Default $false)) {
    if ($wirelessDriver -eq "none") {
        throw "wifi.enabled is true but wirelessDriver is 'none'."
    }

    $wifiNetworks = @((Get-PropertyValue -Object $wifi -Name "networks" -Required))
    $wifiCountry = [string](Get-PropertyValue -Object $wifi -Name "country" -Default "Ukraine")
    $wifiInstallation = [string](Get-PropertyValue -Object $wifi -Name "installation" -Default "indoor")
    if ($wifiNetworks.Count -eq 0) {
        throw "wifi.networks must contain at least one entry."
    }

    if ($wifiInstallation -notin @("indoor", "outdoor")) {
        throw "wifi.installation must be 'indoor' or 'outdoor'."
    }

    if ([string]::IsNullOrWhiteSpace($wifiCountry)) {
        throw "wifi.country must not be empty."
    }

    $wifiNames = @{}
    foreach ($network in $wifiNetworks) {
        $networkName = [string](Get-PropertyValue -Object $network -Name "name" -Required)
        $interface = [string](Get-PropertyValue -Object $network -Name "interface" -Required)
        $vlanId = [int](Get-PropertyValue -Object $network -Name "vlan" -Required)
        $ssid = [string](Get-PropertyValue -Object $network -Name "ssid" -Required)
        $passphrase = [string](Get-PropertyValue -Object $network -Name "passphrase" -Required)
        $authenticationTypes = [string](Get-PropertyValue -Object $network -Name "authenticationTypes" -Default "wpa2-psk,wpa3-psk")

        Assert-InterfaceName -Name $interface -Context "wifi.networks"
        Assert-UniqueInterfaceAssignment -Assignments $interfaceAssignments -Interface $interface -Purpose "WiFi VLAN $vlanId"
        [void]$requiredInterfaces.Add($interface)

        if ($networkName -notmatch '^[A-Za-z0-9_.-]+$') {
            throw "WiFi network name '$networkName' contains unsupported characters."
        }

        if ($wifiNames.ContainsKey($networkName)) {
            throw "Duplicate WiFi network name '$networkName'."
        }
        $wifiNames[$networkName] = $true

        if (-not $vlanById.ContainsKey($vlanId)) {
            throw "WiFi interface '$interface' refers to unknown VLAN '$vlanId'."
        }

        if ([string]::IsNullOrWhiteSpace($ssid)) {
            throw "WiFi interface '$interface' has an empty SSID."
        }

        if ($passphrase.Length -lt 12 -or $passphrase.Length -gt 63) {
            throw "WiFi passphrase for '$interface' must be 12-63 characters."
        }

        if ($passphrase -like "CHANGE-ME-*") {
            $hasPlaceholderSecrets = $true
        }

        if ($authenticationTypes -notmatch '^[a-z0-9,-]+$') {
            throw "WiFi authenticationTypes for '$interface' contains unsupported characters."
        }
    }
}

$wan = $null
if ($role -eq "gateway") {
    $wan = Get-PropertyValue -Object $config -Name "wan" -Required
    $wanInterface = [string](Get-PropertyValue -Object $wan -Name "interface" -Required)
    $wanMode = [string](Get-PropertyValue -Object $wan -Name "mode" -Default "dhcp")

    Assert-InterfaceName -Name $wanInterface -Context "wan.interface"
    Assert-UniqueInterfaceAssignment -Assignments $interfaceAssignments -Interface $wanInterface -Purpose "WAN"
    [void]$requiredInterfaces.Add($wanInterface)

    if ($wanMode -ne "dhcp") {
        throw "This first version supports only wan.mode='dhcp'."
    }

    foreach ($vlan in $vlans) {
        [void](Get-PropertyValue -Object $vlan -Name "routerAddress" -Required)
        $dhcp = Get-PropertyValue -Object $vlan -Name "dhcp" -Required
        if ([bool](Get-PropertyValue -Object $dhcp -Name "enabled" -Default $true)) {
            [void](Get-PropertyValue -Object $dhcp -Name "pool" -Required)
        }
    }
}

$management = $null
if ($role -eq "access-point") {
    $management = Get-PropertyValue -Object $config -Name "management" -Required
    [void](Get-PropertyValue -Object $management -Name "address" -Required)
    [void](Get-PropertyValue -Object $management -Name "gateway" -Required)
}

$lines = New-Object System.Text.StringBuilder
$configFileName = [System.IO.Path]::GetFileName($resolvedConfigPath)

Add-Line $lines "# Generated by Generate-MikroTikConfig.ps1"
Add-Line $lines "# Source: $configFileName"
Add-Line $lines "# Role: $role"
Add-Line $lines "# Import only on RouterOS 7 after reviewing the generated file."
if ($hasPlaceholderSecrets) {
    Add-Line $lines "# WARNING: placeholder WiFi passphrases are still present."
}
Add-Line $lines ""
Add-Line $lines ":local cfgTag $(ConvertTo-RosString "universal-vlan-v1")"
Add-Line $lines ":log info (`"Starting `$cfgTag for $identity`")"
Add-Line $lines ""

if ($requireCleanConfig) {
    Add-Line $lines "# Safety guard: this configuration expects reset-configuration no-defaults=yes."
    Add-Line $lines ":if ([:len [/interface bridge find]] > 0) do={ :error `"Existing bridge configuration found. Reset with no-defaults or use a dedicated migration config.`" }"
    Add-Line $lines ":if ([:len [/ip address find]] > 0) do={ :error `"Existing IP addresses found. Reset with no-defaults or use a dedicated migration config.`" }"
    Add-Line $lines ":if ([:len [/ip firewall filter find]] > 0) do={ :error `"Existing firewall rules found. Reset with no-defaults or use a dedicated migration config.`" }"
    Add-Line $lines ""
}

Add-Line $lines "# Preflight: verify all configured interfaces exist."
foreach ($interface in ($requiredInterfaces | Sort-Object)) {
    Add-Line $lines ":if ([:len [/interface find where name=$(ConvertTo-RosString $interface)]] = 0) do={ :error $(ConvertTo-RosString "Missing interface: $interface") }"
}
Add-Line $lines ""

Add-Line $lines "/system identity"
Add-Line $lines "set name=$(ConvertTo-RosString $identity)"
Add-Line $lines "/system clock"
Add-Line $lines "set time-zone-name=$(ConvertTo-RosString $timeZone)"
Add-Line $lines ""

Add-Line $lines "# Build the bridge without VLAN filtering. Filtering is enabled at the end."
Add-Line $lines "/interface bridge"
Add-Line $lines "add name=$(ConvertTo-RosString $bridge) protocol-mode=rstp vlan-filtering=no ingress-filtering=yes frame-types=admit-only-vlan-tagged comment=$(ConvertTo-RosString "Managed by universal-vlan-v1")"
Add-Line $lines ""

if ($role -eq "gateway") {
    Add-Line $lines "/interface list"
    Add-Line $lines "add name=WAN comment=$(ConvertTo-RosString "Managed by universal-vlan-v1")"
    Add-Line $lines "add name=LAN comment=$(ConvertTo-RosString "Managed by universal-vlan-v1")"
    Add-Line $lines "add name=MGMT comment=$(ConvertTo-RosString "Managed by universal-vlan-v1")"
    Add-Line $lines "/interface list member"
    Add-Line $lines "add interface=$(ConvertTo-RosString $wanInterface) list=WAN"
    Add-Line $lines ""
}
else {
    Add-Line $lines "/interface list"
    Add-Line $lines "add name=MGMT comment=$(ConvertTo-RosString "Managed by universal-vlan-v1")"
    Add-Line $lines ""
}

Add-Line $lines "# VLAN interfaces expose only the VLANs that need access to this router's CPU."
Add-Line $lines "/interface vlan"
foreach ($vlan in $vlans) {
    $id = [int]$vlan.id
    if ($role -eq "gateway" -or $id -eq $managementVlanId) {
        $vlanInterface = "vlan$id-$($vlan.name)"
        Add-Line $lines "add interface=$(ConvertTo-RosString $bridge) name=$(ConvertTo-RosString $vlanInterface) vlan-id=$id comment=$(ConvertTo-RosString ([string](Get-PropertyValue -Object $vlan -Name "comment" -Default $vlan.name)))"
    }
}
Add-Line $lines ""

if ($wifiNetworks.Count -gt 0) {
    if ($wirelessDriver -eq "wifi") {
        Add-Line $lines "# New RouterOS WiFi stack. VLAN assignment is done by bridge PVIDs."
        Add-Line $lines "/interface wifi security"
        foreach ($network in $wifiNetworks) {
            $profileName = "sec-$([string]$network.name)"
            $authTypes = [string](Get-PropertyValue -Object $network -Name "authenticationTypes" -Default "wpa2-psk,wpa3-psk")
            Add-Line $lines "add name=$(ConvertTo-RosString $profileName) authentication-types=$authTypes passphrase=$(ConvertTo-RosString ([string]$network.passphrase))"
        }
        Add-Line $lines "/interface wifi datapath"
        foreach ($network in $wifiNetworks) {
            $datapathName = "dp-$([string]$network.name)"
            $clientIsolation = if ([bool](Get-PropertyValue -Object $network -Name "clientIsolation" -Default $false)) { "yes" } else { "no" }
            Add-Line $lines "add name=$(ConvertTo-RosString $datapathName) client-isolation=$clientIsolation"
        }
        Add-Line $lines "/interface wifi configuration"
        foreach ($network in $wifiNetworks) {
            $configurationName = "cfg-$([string]$network.name)"
            $profileName = "sec-$([string]$network.name)"
            $datapathName = "dp-$([string]$network.name)"
            Add-Line $lines "add name=$(ConvertTo-RosString $configurationName) mode=ap ssid=$(ConvertTo-RosString ([string]$network.ssid)) country=$(ConvertTo-RosString $wifiCountry) installation=$wifiInstallation security=$(ConvertTo-RosString $profileName) datapath=$(ConvertTo-RosString $datapathName)"
        }
        Add-Line $lines "/interface wifi"
        foreach ($network in $wifiNetworks) {
            $configurationName = "cfg-$([string]$network.name)"
            Add-Line $lines "set [find where default-name=$(ConvertTo-RosString ([string]$network.interface))] configuration=$(ConvertTo-RosString $configurationName) disabled=no"
        }
        Add-Line $lines ""
    }
    elseif ($wirelessDriver -eq "wireless") {
        Add-Line $lines "# Legacy wireless stack. VLAN assignment is done by bridge PVIDs."
        Add-Line $lines "/interface wireless security-profiles"
        foreach ($network in $wifiNetworks) {
            $profileName = "sec-$([string]$network.name)"
            Add-Line $lines "add name=$(ConvertTo-RosString $profileName) mode=dynamic-keys authentication-types=wpa2-psk unicast-ciphers=aes-ccm group-ciphers=aes-ccm wpa2-pre-shared-key=$(ConvertTo-RosString ([string]$network.passphrase)) supplicant-identity=$(ConvertTo-RosString $identity)"
        }
        Add-Line $lines "/interface wireless"
        foreach ($network in $wifiNetworks) {
            $profileName = "sec-$([string]$network.name)"
            $defaultForwarding = if ([bool](Get-PropertyValue -Object $network -Name "clientIsolation" -Default $false)) { "no" } else { "yes" }
            Add-Line $lines "set [find where default-name=$(ConvertTo-RosString ([string]$network.interface))] mode=ap-bridge ssid=$(ConvertTo-RosString ([string]$network.ssid)) country=$(ConvertTo-RosString $wifiCountry) installation=$wifiInstallation security-profile=$(ConvertTo-RosString $profileName) default-forwarding=$defaultForwarding disabled=no"
        }
        Add-Line $lines ""
    }
}

Add-Line $lines "# Bridge ports: trunks accept tagged frames; access ports accept untagged frames."
Add-Line $lines "/interface bridge port"
foreach ($trunkPort in $trunkPorts) {
    Add-Line $lines "add bridge=$(ConvertTo-RosString $bridge) interface=$(ConvertTo-RosString ([string]$trunkPort)) ingress-filtering=yes frame-types=admit-only-vlan-tagged comment=$(ConvertTo-RosString "TRUNK")"
}
foreach ($vlan in $vlans) {
    $id = [int]$vlan.id
    foreach ($accessPort in @($vlan.accessPorts)) {
        Add-Line $lines "add bridge=$(ConvertTo-RosString $bridge) interface=$(ConvertTo-RosString ([string]$accessPort)) pvid=$id ingress-filtering=yes frame-types=admit-only-untagged-and-priority-tagged comment=$(ConvertTo-RosString "ACCESS VLAN $id $($vlan.name)")"
    }
}
foreach ($network in $wifiNetworks) {
    $id = [int]$network.vlan
    Add-Line $lines "add bridge=$(ConvertTo-RosString $bridge) interface=$(ConvertTo-RosString ([string]$network.interface)) pvid=$id ingress-filtering=yes frame-types=admit-only-untagged-and-priority-tagged comment=$(ConvertTo-RosString "WIFI ACCESS VLAN $id $($network.name)")"
}
Add-Line $lines ""

Add-Line $lines "# One bridge VLAN entry per VLAN prevents accidental leakage between access ports."
Add-Line $lines "/interface bridge vlan"
foreach ($vlan in $vlans) {
    $id = [int]$vlan.id
    $taggedPorts = New-Object System.Collections.Generic.List[string]
    if ($role -eq "gateway" -or $id -eq $managementVlanId) {
        $taggedPorts.Add($bridge)
    }
    foreach ($trunkPort in $trunkPorts) {
        $taggedPorts.Add([string]$trunkPort)
    }

    $untaggedPorts = New-Object System.Collections.Generic.List[string]
    foreach ($accessPort in @($vlan.accessPorts)) {
        $untaggedPorts.Add([string]$accessPort)
    }
    foreach ($network in $wifiNetworks) {
        if ([int]$network.vlan -eq $id) {
            $untaggedPorts.Add([string]$network.interface)
        }
    }

    $entry = "add bridge=$(ConvertTo-RosString $bridge) vlan-ids=$id tagged=$($taggedPorts -join ',')"
    if ($untaggedPorts.Count -gt 0) {
        $entry += " untagged=$($untaggedPorts -join ',')"
    }
    $entry += " comment=$(ConvertTo-RosString ([string](Get-PropertyValue -Object $vlan -Name "comment" -Default $vlan.name)))"
    Add-Line $lines $entry
}
Add-Line $lines ""

if ($role -eq "gateway") {
    $dnsServers = @((Get-PropertyValue -Object $config -Name "dnsServers" -Default @("1.1.1.1", "8.8.8.8")))
    $dnsText = $dnsServers -join ","

    Add-Line $lines "/interface list member"
    foreach ($vlan in $vlans) {
        $id = [int]$vlan.id
        $vlanInterface = "vlan$id-$($vlan.name)"
        Add-Line $lines "add interface=$(ConvertTo-RosString $vlanInterface) list=LAN"
        if ($id -eq $managementVlanId) {
            Add-Line $lines "add interface=$(ConvertTo-RosString $vlanInterface) list=MGMT"
        }
    }
    Add-Line $lines ""

    Add-Line $lines "/ip address"
    foreach ($vlan in $vlans) {
        $id = [int]$vlan.id
        $vlanInterface = "vlan$id-$($vlan.name)"
        Add-Line $lines "add address=$(ConvertTo-RosString ([string]$vlan.routerAddress)) interface=$(ConvertTo-RosString $vlanInterface) comment=$(ConvertTo-RosString ([string](Get-PropertyValue -Object $vlan -Name "comment" -Default $vlan.name)))"
    }
    Add-Line $lines ""

    Add-Line $lines "/ip pool"
    foreach ($vlan in $vlans) {
        $dhcp = $vlan.dhcp
        if ([bool](Get-PropertyValue -Object $dhcp -Name "enabled" -Default $true)) {
            $id = [int]$vlan.id
            Add-Line $lines "add name=$(ConvertTo-RosString "pool-vlan$id") ranges=$(ConvertTo-RosString ([string]$dhcp.pool)) comment=$(ConvertTo-RosString ([string](Get-PropertyValue -Object $vlan -Name "comment" -Default $vlan.name)))"
        }
    }
    Add-Line $lines "/ip dhcp-server"
    foreach ($vlan in $vlans) {
        $dhcp = $vlan.dhcp
        if ([bool](Get-PropertyValue -Object $dhcp -Name "enabled" -Default $true)) {
            $id = [int]$vlan.id
            $leaseTime = [string](Get-PropertyValue -Object $dhcp -Name "leaseTime" -Default "1h")
            $vlanInterface = "vlan$id-$($vlan.name)"
            Add-Line $lines "add name=$(ConvertTo-RosString "dhcp-vlan$id") interface=$(ConvertTo-RosString $vlanInterface) address-pool=$(ConvertTo-RosString "pool-vlan$id") lease-time=$leaseTime disabled=no comment=$(ConvertTo-RosString ([string](Get-PropertyValue -Object $vlan -Name "comment" -Default $vlan.name)))"
        }
    }
    Add-Line $lines "/ip dhcp-server network"
    foreach ($vlan in $vlans) {
        $dhcp = $vlan.dhcp
        if ([bool](Get-PropertyValue -Object $dhcp -Name "enabled" -Default $true)) {
            $gateway = Get-IpWithoutPrefix -Address ([string]$vlan.routerAddress)
            $vlanDns = @((Get-PropertyValue -Object $dhcp -Name "dnsServers" -Default $dnsServers)) -join ","
            Add-Line $lines "add address=$(ConvertTo-RosString ([string]$vlan.subnet)) gateway=$(ConvertTo-RosString $gateway) dns-server=$vlanDns comment=$(ConvertTo-RosString ([string](Get-PropertyValue -Object $vlan -Name "comment" -Default $vlan.name)))"
        }
    }
    Add-Line $lines ""

    Add-Line $lines "/ip dhcp-client"
    Add-Line $lines "add interface=$(ConvertTo-RosString $wanInterface) add-default-route=yes use-peer-dns=no disabled=no comment=$(ConvertTo-RosString "WAN DHCP")"
    Add-Line $lines "/ip dns"
    Add-Line $lines "set servers=$dnsText allow-remote-requests=no"
    Add-Line $lines ""

    Add-Line $lines "/ip firewall address-list"
    foreach ($vlan in $vlans) {
        $listName = if ([int]$vlan.id -eq $managementVlanId) { "MGMT_SUBNETS" } else { "LOCAL_SUBNETS" }
        Add-Line $lines "add list=LOCAL_SUBNETS address=$(ConvertTo-RosString ([string]$vlan.subnet)) comment=$(ConvertTo-RosString ([string]$vlan.name))"
        if ($listName -eq "MGMT_SUBNETS") {
            Add-Line $lines "add list=MGMT_SUBNETS address=$(ConvertTo-RosString ([string]$vlan.subnet)) comment=$(ConvertTo-RosString ([string]$vlan.name))"
        }
    }
    Add-Line $lines ""

    Add-Line $lines "# Router protection. DHCP is allowed on LAN; management is limited to the management subnet."
    Add-Line $lines "/ip firewall filter"
    Add-Line $lines "add chain=input action=accept connection-state=established,related,untracked comment=$(ConvertTo-RosString "INPUT established")"
    Add-Line $lines "add chain=input action=drop connection-state=invalid comment=$(ConvertTo-RosString "INPUT invalid")"
    Add-Line $lines "add chain=input action=accept protocol=icmp comment=$(ConvertTo-RosString "INPUT ICMP")"
    Add-Line $lines "add chain=input action=accept protocol=udp src-port=68 dst-port=67 in-interface-list=LAN comment=$(ConvertTo-RosString "INPUT DHCP")"
    Add-Line $lines "add chain=input action=accept src-address-list=MGMT_SUBNETS comment=$(ConvertTo-RosString "INPUT management")"
    Add-Line $lines "add chain=input action=drop comment=$(ConvertTo-RosString "INPUT drop all")"
    Add-Line $lines ""
    Add-Line $lines "# Client protection. VLANs can reach WAN, but cannot route to each other."
    Add-Line $lines "add chain=forward action=fasttrack-connection connection-state=established,related hw-offload=yes comment=$(ConvertTo-RosString "FORWARD fasttrack")"
    Add-Line $lines "add chain=forward action=accept connection-state=established,related,untracked comment=$(ConvertTo-RosString "FORWARD established")"
    Add-Line $lines "add chain=forward action=drop connection-state=invalid comment=$(ConvertTo-RosString "FORWARD invalid")"
    Add-Line $lines "add chain=forward action=accept src-address-list=LOCAL_SUBNETS out-interface-list=WAN comment=$(ConvertTo-RosString "FORWARD local to internet")"
    Add-Line $lines "add chain=forward action=drop src-address-list=LOCAL_SUBNETS dst-address-list=LOCAL_SUBNETS comment=$(ConvertTo-RosString "FORWARD isolate VLANs")"
    Add-Line $lines "add chain=forward action=drop connection-state=new in-interface-list=WAN connection-nat-state=!dstnat comment=$(ConvertTo-RosString "FORWARD drop unsolicited WAN")"
    Add-Line $lines "add chain=forward action=drop comment=$(ConvertTo-RosString "FORWARD drop all")"
    Add-Line $lines ""

    Add-Line $lines "/ip firewall nat"
    Add-Line $lines "add chain=srcnat action=masquerade out-interface-list=WAN comment=$(ConvertTo-RosString "NAT dynamic WAN")"
    Add-Line $lines ""
}
else {
    $managementVlan = $vlanById[$managementVlanId]
    $managementInterface = "vlan$managementVlanId-$($managementVlan.name)"
    $managementAddress = [string]$management.address
    $managementGateway = [string]$management.gateway
    $dnsServers = @((Get-PropertyValue -Object $config -Name "dnsServers" -Default @("1.1.1.1", "8.8.8.8")))
    $dnsText = $dnsServers -join ","

    Add-Line $lines "/interface list member"
    Add-Line $lines "add interface=$(ConvertTo-RosString $managementInterface) list=MGMT"
    Add-Line $lines "/ip address"
    Add-Line $lines "add address=$(ConvertTo-RosString $managementAddress) interface=$(ConvertTo-RosString $managementInterface) comment=$(ConvertTo-RosString "AP management")"
    Add-Line $lines "/ip route"
    Add-Line $lines "add dst-address=0.0.0.0/0 gateway=$(ConvertTo-RosString $managementGateway) comment=$(ConvertTo-RosString "AP default route")"
    Add-Line $lines "/ip dns"
    Add-Line $lines "set servers=$dnsText allow-remote-requests=no"
    Add-Line $lines ""

    Add-Line $lines "/ip firewall filter"
    Add-Line $lines "add chain=input action=accept connection-state=established,related,untracked comment=$(ConvertTo-RosString "INPUT established")"
    Add-Line $lines "add chain=input action=drop connection-state=invalid comment=$(ConvertTo-RosString "INPUT invalid")"
    Add-Line $lines "add chain=input action=accept protocol=icmp src-address=$(ConvertTo-RosString ([string]$managementVlan.subnet)) comment=$(ConvertTo-RosString "INPUT management ICMP")"
    Add-Line $lines "add chain=input action=accept src-address=$(ConvertTo-RosString ([string]$managementVlan.subnet)) comment=$(ConvertTo-RosString "INPUT management")"
    Add-Line $lines "add chain=input action=drop comment=$(ConvertTo-RosString "INPUT drop all")"
    Add-Line $lines ""
}

$managementSubnet = [string]$vlanById[$managementVlanId].subnet
Add-Line $lines "# Restrict management services to the management subnet."
Add-Line $lines "/ip service"
Add-Line $lines "set [find where name=telnet] disabled=yes"
Add-Line $lines "set [find where name=ftp] disabled=yes"
Add-Line $lines "set [find where name=www] disabled=yes"
Add-Line $lines "set [find where name=api] disabled=yes"
Add-Line $lines "set [find where name=api-ssl] disabled=yes"
Add-Line $lines "set [find where name=ssh] disabled=no address=$(ConvertTo-RosString $managementSubnet)"
Add-Line $lines "set [find where name=winbox] disabled=no address=$(ConvertTo-RosString $managementSubnet)"
Add-Line $lines ""

Add-Line $lines "# VLAN filtering is deliberately enabled only after management and VLAN tables exist."
Add-Line $lines "/interface bridge"
Add-Line $lines "set [find where name=$(ConvertTo-RosString $bridge)] vlan-filtering=yes"
Add-Line $lines ""
Add-Line $lines ":log info (`"Completed `$cfgTag for $identity`")"

if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
}
else {
    $resolvedOutputPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputPath))
}
$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
if (-not [string]::IsNullOrEmpty($outputDirectory)) {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedOutputPath, $lines.ToString(), $utf8NoBom)

Write-Host "Generated: $resolvedOutputPath"
if ($hasPlaceholderSecrets) {
    Write-Warning "The generated file still contains CHANGE-ME WiFi passphrases."
}

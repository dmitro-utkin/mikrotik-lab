# =============================================================================
# MIKROTIK LOCAL EDITABLE GATEWAY TEMPLATE
# =============================================================================
# Target: RouterOS 7, clean configuration, new /interface wifi stack.
# Delivery: local file upload only. No SSH, API, HTTP or HTTPS management.
#
# IMPORTANT:
# 1. Make a backup/export before changing the router.
# 2. This file expects:
#       /system reset-configuration no-defaults=yes skip-backup=yes
#    Reset is NOT executed by this file.
# 3. Search for "EDIT:" and review every marked value.
# 4. Do not store real WiFi passwords in GitHub.
# 5. Test locally before import:
#       /import file-name=MikroTik-local-editable-gateway.rsc \
#           verbose=yes dry-run=yes
# 6. Import only while local recovery is available: MAC Winbox or console.
#
# CURRENT EXAMPLE TOPOLOGY:
#   ether1 = WAN, DHCP client
#   ether2 = trunk, tagged VLAN 888/100/200
#   ether3 = access VLAN 100 (WORK)
#   ether5 = access VLAN 888 (MGMT)
#   wifi1  = access VLAN 100 (WORK)
#   wifi2  = access VLAN 200 (GUEST)
#
# VLAN 888 = MGMT  = 10.11.88.0/24
# VLAN 100 = WORK  = 10.11.100.0/24
# VLAN 200 = GUEST = 10.11.200.0/24
# =============================================================================

:local cfgTag "local-editable-gateway-v1"

# -----------------------------------------------------------------------------
# EDIT BLOCK: device-specific text values
# Keep real passwords only in a local copy under manual/local/.
# -----------------------------------------------------------------------------
:local routerName "EDIT-MikroTik-Gateway"
:local workSsid "EDIT-WORK-SSID"
:local guestSsid "EDIT-GUEST-SSID"
:local workWifiPassword "EDIT-WORK-WIFI-PASSWORD"
:local guestWifiPassword "EDIT-GUEST-WIFI-PASSWORD"

# Refuse import while obvious placeholders are still present.
:if ($routerName~"^EDIT-") do={
    :error "Replace all EDIT placeholders before import."
}
:if ($workSsid~"^EDIT-") do={
    :error "Replace all EDIT placeholders before import."
}
:if ($guestSsid~"^EDIT-") do={
    :error "Replace all EDIT placeholders before import."
}
:if ($workWifiPassword~"^EDIT-") do={
    :error "Replace all EDIT placeholders before import."
}
:if ($guestWifiPassword~"^EDIT-") do={
    :error "Replace all EDIT placeholders before import."
}

:log info ("Starting $cfgTag")

# -----------------------------------------------------------------------------
# SAFETY GUARD
# Remove these checks only when intentionally converting this file into a
# migration script for an existing configuration.
# -----------------------------------------------------------------------------
:if ([:len [/interface bridge find]] > 0) do={
    :error "Existing bridge found. This template requires a clean config."
}
:if ([:len [/ip address find]] > 0) do={
    :error "Existing IP addresses found. This template requires a clean config."
}
:if ([:len [/ip firewall filter find]] > 0) do={
    :error "Existing firewall found. This template requires a clean config."
}

# -----------------------------------------------------------------------------
# INTERFACE PREFLIGHT
# EDIT: change interface names here and everywhere below when hardware differs.
# Delete WiFi checks if the device has no local WiFi.
# -----------------------------------------------------------------------------
:if ([:len [/interface find where name="ether1"]] = 0) do={
    :error "Missing interface ether1 (WAN)"
}
:if ([:len [/interface find where name="ether2"]] = 0) do={
    :error "Missing interface ether2 (TRUNK)"
}
:if ([:len [/interface find where name="ether3"]] = 0) do={
    :error "Missing interface ether3 (WORK ACCESS)"
}
:if ([:len [/interface find where name="ether5"]] = 0) do={
    :error "Missing interface ether5 (MGMT ACCESS)"
}
:if ([:len [/interface find where name="wifi1"]] = 0) do={
    :error "Missing interface wifi1 (WORK)"
}
:if ([:len [/interface find where name="wifi2"]] = 0) do={
    :error "Missing interface wifi2 (GUEST)"
}

# -----------------------------------------------------------------------------
# DEVICE IDENTITY
# EDIT: router name and time zone.
# -----------------------------------------------------------------------------
/system identity
set name=$routerName

/system clock
set time-zone-name="Europe/Kyiv"

# -----------------------------------------------------------------------------
# BRIDGE
# VLAN filtering stays disabled until the final section to reduce lockout risk.
# The bridge itself is the CPU port and accepts only tagged VLAN traffic.
# EDIT: rename bridge-vlan only if all references below are changed too.
# -----------------------------------------------------------------------------
/interface bridge
add name="bridge-vlan" \
    protocol-mode=rstp \
    vlan-filtering=no \
    ingress-filtering=yes \
    frame-types=admit-only-vlan-tagged \
    comment="MAIN VLAN BRIDGE"

# -----------------------------------------------------------------------------
# INTERFACE LISTS
# WAN is used by firewall/NAT. LAN contains routed VLAN interfaces.
# MGMT contains only the management VLAN interface.
# -----------------------------------------------------------------------------
/interface list
add name=WAN comment="Internet uplinks"
add name=LAN comment="Local routed VLANs"
add name=MGMT comment="Local management only"

/interface list member
add interface=ether1 list=WAN comment="EDIT: WAN"

# -----------------------------------------------------------------------------
# L3 VLAN INTERFACES
# These interfaces terminate VLANs on the router CPU.
# EDIT: VLAN IDs and names when the task requires different networks.
# -----------------------------------------------------------------------------
/interface vlan
add interface=bridge-vlan name=vlan888-mgmt vlan-id=888 \
    comment="MGMT VLAN"
add interface=bridge-vlan name=vlan100-work vlan-id=100 \
    comment="WORK VLAN"
add interface=bridge-vlan name=vlan200-guest vlan-id=200 \
    comment="GUEST VLAN"

/interface list member
add interface=vlan888-mgmt list=LAN
add interface=vlan888-mgmt list=MGMT
add interface=ether5 list=MGMT comment="Local MAC Winbox recovery"
add interface=vlan100-work list=LAN
add interface=vlan200-guest list=LAN

# -----------------------------------------------------------------------------
# WIFI SECURITY AND SSIDS
# EDIT: country, SSIDs and both passphrases.
# Never commit a copy containing real passphrases.
# If the router uses legacy /interface wireless, replace this whole section.
# -----------------------------------------------------------------------------
/interface wifi security
add name=sec-work \
    authentication-types=wpa2-psk,wpa3-psk \
    passphrase=$workWifiPassword
add name=sec-guest \
    authentication-types=wpa2-psk,wpa3-psk \
    passphrase=$guestWifiPassword

/interface wifi datapath
add name=dp-work client-isolation=no
add name=dp-guest client-isolation=yes

/interface wifi configuration
add name=cfg-work \
    mode=ap \
    ssid=$workSsid \
    country="Ukraine" \
    installation=indoor \
    security=sec-work \
    datapath=dp-work
add name=cfg-guest \
    mode=ap \
    ssid=$guestSsid \
    country="Ukraine" \
    installation=indoor \
    security=sec-guest \
    datapath=dp-guest

/interface wifi
set [find where default-name=wifi1] configuration=cfg-work disabled=no
set [find where default-name=wifi2] configuration=cfg-guest disabled=no

# -----------------------------------------------------------------------------
# BRIDGE PORTS
# Trunk: accepts tagged frames only.
# Access: accepts untagged frames and assigns the configured PVID.
# EDIT: add/remove access ports according to the device task.
# -----------------------------------------------------------------------------
/interface bridge port
add bridge=bridge-vlan interface=ether2 \
    ingress-filtering=yes \
    frame-types=admit-only-vlan-tagged \
    comment="TRUNK VLAN 888,100,200"

add bridge=bridge-vlan interface=ether5 pvid=888 \
    ingress-filtering=yes \
    frame-types=admit-only-untagged-and-priority-tagged \
    comment="MGMT ACCESS VLAN 888"

add bridge=bridge-vlan interface=ether3 pvid=100 \
    ingress-filtering=yes \
    frame-types=admit-only-untagged-and-priority-tagged \
    comment="WORK ACCESS VLAN 100"

add bridge=bridge-vlan interface=wifi1 pvid=100 \
    ingress-filtering=yes \
    frame-types=admit-only-untagged-and-priority-tagged \
    comment="WORK WIFI VLAN 100"

add bridge=bridge-vlan interface=wifi2 pvid=200 \
    ingress-filtering=yes \
    frame-types=admit-only-untagged-and-priority-tagged \
    comment="GUEST WIFI VLAN 200"

# -----------------------------------------------------------------------------
# BRIDGE VLAN TABLE
# Keep one entry per VLAN when access ports are present.
# bridge-vlan is tagged because the router CPU terminates all three VLANs.
# ether2 is tagged because it is the trunk.
# EDIT: keep this table synchronized with bridge port PVID values.
# -----------------------------------------------------------------------------
/interface bridge vlan
add bridge=bridge-vlan vlan-ids=888 \
    tagged=bridge-vlan,ether2 \
    untagged=ether5 \
    comment="MGMT VLAN"

add bridge=bridge-vlan vlan-ids=100 \
    tagged=bridge-vlan,ether2 \
    untagged=ether3,wifi1 \
    comment="WORK VLAN"

add bridge=bridge-vlan vlan-ids=200 \
    tagged=bridge-vlan,ether2 \
    untagged=wifi2 \
    comment="GUEST VLAN"

# -----------------------------------------------------------------------------
# ROUTER ADDRESSES
# EDIT: gateway addresses when subnets change.
# -----------------------------------------------------------------------------
/ip address
add address=10.11.88.1/24 interface=vlan888-mgmt comment="MGMT gateway"
add address=10.11.100.1/24 interface=vlan100-work comment="WORK gateway"
add address=10.11.200.1/24 interface=vlan200-guest comment="GUEST gateway"

# -----------------------------------------------------------------------------
# DHCP
# EDIT: pools, lease times, gateways and DNS servers.
# Do not overlap pools with gateways or statically assigned addresses.
# -----------------------------------------------------------------------------
/ip pool
add name=pool-vlan888 ranges=10.11.88.10-10.11.88.50 \
    comment="MGMT pool"
add name=pool-vlan100 ranges=10.11.100.10-10.11.100.100 \
    comment="WORK pool"
add name=pool-vlan200 ranges=10.11.200.10-10.11.200.100 \
    comment="GUEST pool"

/ip dhcp-server
add name=dhcp-vlan888 interface=vlan888-mgmt \
    address-pool=pool-vlan888 lease-time=1h disabled=no
add name=dhcp-vlan100 interface=vlan100-work \
    address-pool=pool-vlan100 lease-time=1h disabled=no
add name=dhcp-vlan200 interface=vlan200-guest \
    address-pool=pool-vlan200 lease-time=1h disabled=no

/ip dhcp-server network
add address=10.11.88.0/24 gateway=10.11.88.1 \
    dns-server=1.1.1.1,8.8.8.8 comment="MGMT network"
add address=10.11.100.0/24 gateway=10.11.100.1 \
    dns-server=1.1.1.1,8.8.8.8 comment="WORK network"
add address=10.11.200.0/24 gateway=10.11.200.1 \
    dns-server=1.1.1.1,8.8.8.8 comment="GUEST network"

# -----------------------------------------------------------------------------
# WAN
# Current example expects DHCP from the ISP on ether1.
# EDIT: replace this section for static IP, PPPoE or another WAN method.
# -----------------------------------------------------------------------------
/ip dhcp-client
add interface=ether1 \
    add-default-route=yes \
    use-peer-dns=no \
    disabled=no \
    comment="WAN DHCP"

/ip dns
set servers=1.1.1.1,8.8.8.8 allow-remote-requests=no

# -----------------------------------------------------------------------------
# FIREWALL ADDRESS LISTS
# LOCAL_SUBNETS is used for NAT policy and inter-VLAN isolation.
# MGMT_SUBNETS is allowed to manage the router through local Winbox.
# -----------------------------------------------------------------------------
/ip firewall address-list
add list=LOCAL_SUBNETS address=10.11.88.0/24 comment="MGMT"
add list=LOCAL_SUBNETS address=10.11.100.0/24 comment="WORK"
add list=LOCAL_SUBNETS address=10.11.200.0/24 comment="GUEST"
add list=MGMT_SUBNETS address=10.11.88.0/24 comment="MGMT only"

# -----------------------------------------------------------------------------
# INPUT FIREWALL: traffic to the router itself.
# SSH/API/Web are disabled later. Local Winbox is allowed only from MGMT.
# -----------------------------------------------------------------------------
/ip firewall filter
add chain=input action=accept \
    connection-state=established,related,untracked \
    comment="INPUT established"
add chain=input action=drop connection-state=invalid \
    comment="INPUT invalid"
add chain=input action=accept protocol=icmp \
    comment="INPUT ICMP"
add chain=input action=accept protocol=udp src-port=68 dst-port=67 \
    in-interface-list=LAN \
    comment="INPUT DHCP"
add chain=input action=accept src-address-list=MGMT_SUBNETS \
    comment="INPUT local management"
add chain=input action=drop \
    comment="INPUT drop all"

# -----------------------------------------------------------------------------
# FORWARD FIREWALL: traffic through the router.
# All local VLANs can reach WAN. Routing between local VLANs is blocked.
# EDIT: add explicit allow rules BEFORE "FORWARD isolate VLANs" when needed.
# -----------------------------------------------------------------------------
add chain=forward action=fasttrack-connection \
    connection-state=established,related hw-offload=yes \
    comment="FORWARD fasttrack"
add chain=forward action=accept \
    connection-state=established,related,untracked \
    comment="FORWARD established"
add chain=forward action=drop connection-state=invalid \
    comment="FORWARD invalid"
add chain=forward action=accept \
    src-address-list=LOCAL_SUBNETS out-interface-list=WAN \
    comment="FORWARD local to internet"
add chain=forward action=drop \
    src-address-list=LOCAL_SUBNETS dst-address-list=LOCAL_SUBNETS \
    comment="FORWARD isolate VLANs"
add chain=forward action=drop \
    connection-state=new in-interface-list=WAN connection-nat-state=!dstnat \
    comment="FORWARD drop unsolicited WAN"
add chain=forward action=drop \
    comment="FORWARD drop all"

# -----------------------------------------------------------------------------
# NAT
# Masquerade is appropriate here because the WAN address is received by DHCP.
# -----------------------------------------------------------------------------
/ip firewall nat
add chain=srcnat action=masquerade out-interface-list=WAN \
    comment="NAT dynamic WAN"

# -----------------------------------------------------------------------------
# MANAGEMENT SERVICES
# Policy: no SSH, API, HTTP or HTTPS management.
# Winbox remains available only from the local MGMT subnet.
# If network Winbox is also prohibited, set winbox disabled=yes and use console.
# -----------------------------------------------------------------------------
/ip service
set [find where name=telnet] disabled=yes
set [find where name=ftp] disabled=yes
set [find where name=www] disabled=yes
set [find where name=www-ssl] disabled=yes
set [find where name=ssh] disabled=yes
set [find where name=api] disabled=yes
set [find where name=api-ssl] disabled=yes
set [find where name=winbox] disabled=no address=10.11.88.0/24

# Limit local discovery and MAC Winbox to the management interface list.
/ip neighbor discovery-settings
set discover-interface-list=MGMT

/tool mac-server
set allowed-interface-list=none

/tool mac-server mac-winbox
set allowed-interface-list=MGMT

/tool bandwidth-server
set enabled=no

/tool romon
set enabled=no

# -----------------------------------------------------------------------------
# ENABLE VLAN FILTERING LAST
# This command can disconnect the current session. Local recovery must be ready.
# -----------------------------------------------------------------------------
/interface bridge
set [find where name=bridge-vlan] vlan-filtering=yes

:log info ("Completed $cfgTag")

# =============================================================================
# POST-IMPORT CHECKLIST (run manually; these lines are comments)
# =============================================================================
# /interface bridge vlan print
# /interface bridge port print
# /interface vlan print
# /ip address print
# /ip dhcp-server print
# /ip firewall filter print stats
# /ip service print
# /ping 1.1.1.1
#
# Expected client networks:
#   ether5      -> 10.11.88.0/24
#   ether3      -> 10.11.100.0/24
#   WORK WiFi   -> 10.11.100.0/24
#   GUEST WiFi  -> 10.11.200.0/24
# =============================================================================

#!/bin/sh
#
# Script for automatic setup of an IPsec VPN server on Ubuntu LTS and Debian 8.
# Works on any dedicated server or Virtual Private Server (VPS) except OpenVZ.
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC!
#
# The latest version of this script is available at:
# https://github.com/aha-lin/setup-ipsec-vpn
#
# This script is developed base on hwdsl2's work at:
# https://github.com/hwdsl2/setup-ipsec-vpn
#
# Copyright (C) 2014-2016 Lin Song <linsongui@gmail.com>
# Based on the work of Thomas Sarlandie (Copyright 2012)
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

# =====================================================

# Define your own values for these variables
# - IPsec pre-shared key, VPN username and password
# - All values MUST be placed inside 'single quotes'
# - DO NOT use these characters within values:  \ " '

YOUR_IPSEC_PSK=''
YOUR_USERNAME=''
YOUR_PASSWORD=''

# Important notes:   https://git.io/vpnnotes
# Setup VPN clients: https://git.io/vpnclients

# =====================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SYS_DT="$(date +%Y-%m-%d-%H:%M:%S)"; export SYS_DT

exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { echo "Error: 'apt-get install' failed." >&2; exit 1; }
conf_bk() { /bin/cp -f "$1" "$1.old-$SYS_DT" 2>/dev/null; }
print_status() { echo; echo "## $1"; echo; }

check_ip() {
  IP_REGEX="^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
  printf %s "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

os_type="$(lsb_release -si 2>/dev/null)"
if [ -z "$os_type" ] && [ -f "/etc/lsb-release" ]; then
  os_type="$(. /etc/lsb-release && echo "$DISTRIB_ID")"
fi
if [ "$os_type" != "Ubuntu" ] && [ "$os_type" != "Debian" ] && [ "$os_type" != "Raspbian" ]; then
  exiterr "This script only supports Ubuntu/Debian."
fi

if [ -f /proc/user_beancounters ]; then
  echo "Error: This script does not support OpenVZ VPS." >&2
  echo "Try OpenVPN: https://github.com/Nyr/openvpn-install" >&2
  exit 1
fi

if [ "$(id -u)" != 0 ]; then
  exiterr "Script must be run as root. Try 'sudo sh $0'"
fi

VPN_IFACE="$(route | grep '^default' | grep -o '[^ ]*$')"

NET_IF0=${VPN_IFACE:-'eth0'}
NET_IFS=${VPN_IFACE:-'eth+'}

if_state=$(cat "/sys/class/net/$NET_IF0/operstate" 2>/dev/null)
if [ -z "$if_state" ] || [ "$if_state" = "down" ] || [ "$NET_IF0" = "lo" ]; then
  echo "Error: Network interface '$NET_IF0' is not available." >&2
cat 1>&2 <<'EOF'

DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC!

If running on a server, try this workaround:

VPN_IFACE="$(route | grep '^default' | grep -o '[^ ]*$')"
EOF
cat 1>&2 <<EOF
sudo VPN_IFACE="\$VPN_IFACE" sh "$0"
EOF
  exit 1
fi

[ -n "$YOUR_IPSEC_PSK" ] && VPN_IPSEC_PSK="$YOUR_IPSEC_PSK"
[ -n "$YOUR_USERNAME" ] && VPN_USER="$YOUR_USERNAME"
[ -n "$YOUR_PASSWORD" ] && VPN_PASSWORD="$YOUR_PASSWORD"

if [ -z "$VPN_IPSEC_PSK" ] && [ -z "$VPN_USER" ] && [ -z "$VPN_PASSWORD" ]; then
  print_status "VPN credentials not set by user. Generating random PSK and password..."
  VPN_IPSEC_PSK="$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)"
  VPN_USER=vpnuser
  VPN_PASSWORD="$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)"
fi

if [ -z "$VPN_IPSEC_PSK" ] || [ -z "$VPN_USER" ] || [ -z "$VPN_PASSWORD" ]; then
  exiterr "All VPN credentials must be specified. Edit the script and re-enter them."
fi

case "$VPN_IPSEC_PSK $VPN_USER $VPN_PASSWORD" in
  *[\\\"\']*)
    exiterr "VPN credentials must not contain any of these characters: \\ \" '"
    ;;
esac

if [ "$(sed 's/\..*//' /etc/debian_version)" = "7" ]; then
cat <<'EOF'
IMPORTANT: Workaround required for Debian 7 (Wheezy).
You must first run the script at: https://git.io/vpndeb7
If not already done so, press Ctrl-C to interrupt now.

Continuing in 30 seconds ...

EOF
  sleep 30
fi

print_status "VPN setup in progress... Please be patient."

# Create and change to working dir
mkdir -p /opt/src
cd /opt/src || exiterr "Cannot enter /opt/src."

print_status "Populating apt-get cache..."

export DEBIAN_FRONTEND=noninteractive
apt-get -yq update || exiterr "'apt-get update' failed."

print_status "Installing packages required for setup..."

apt-get -yq install wget dnsutils openssl || exiterr2
apt-get -yq install iproute2 gawk grep sed net-tools || exiterr2
apt-get -yq install bc || exiterr2

print_status "Trying to auto discover IPs of this server..."

cat <<'EOF'
In case the script hangs here for more than a few minutes,
use Ctrl-C to interrupt. Then edit it and manually enter IPs.
EOF

# In case auto IP discovery fails, you may manually enter server IPs here.
# If your server only has a public IP, put that public IP on both lines.
PUBLIC_IP=${VPN_PUBLIC_IP:-''}
PRIVATE_IP=${VPN_PRIVATE_IP:-''}

# Try to auto discover IPs of this server
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(dig @resolver1.opendns.com -t A -4 myip.opendns.com +short)
[ -z "$PRIVATE_IP" ] && PRIVATE_IP=$(ip -4 route get 1 | awk '{print $NF;exit}')

# Check IPs for correct format
check_ip "$PUBLIC_IP" || PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
check_ip "$PUBLIC_IP" || exiterr "Cannot find valid public IP. Edit the script and manually enter IPs."
check_ip "$PRIVATE_IP" || PRIVATE_IP=$(ifconfig "$NET_IF0" | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
check_ip "$PRIVATE_IP" || exiterr "Cannot find valid private IP. Edit the script and manually enter IPs."

print_status "Installing packages required for the VPN..."

apt-get -yq install libnss3-dev libnspr4-dev pkg-config libpam0g-dev \
  libcap-ng-dev libcap-ng-utils libselinux1-dev \
  libcurl4-nss-dev flex bison gcc make \
  libunbound-dev libnss3-tools libevent-dev || exiterr2
apt-get -yq --no-install-recommends install xmlto || exiterr2
apt-get -yq install ppp xl2tpd || exiterr2

print_status "Installing Fail2Ban to protect SSH..."

apt-get -yq install fail2ban || exiterr2

print_status "Compiling and installing Libreswan..."

swan_ver=3.29
swan_file="libreswan-$swan_ver.tar.gz"
swan_url1="https://download.libreswan.org/$swan_file"
swan_url2="https://github.com/libreswan/libreswan/archive/v$swan_ver.tar.gz"
if ! { wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url1" || wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url2"; }; then
  exiterr "Cannot download Libreswan source."
fi
/bin/rm -rf "/opt/src/libreswan-$swan_ver"
tar xzf "$swan_file" && /bin/rm -f "$swan_file"
cd "libreswan-$swan_ver" || exiterr "Cannot enter Libreswan source dir."
echo "WERROR_CFLAGS =" > Makefile.inc.local
if [ "$(packaging/utils/lswan_detect.sh init)" = "systemd" ]; then
  apt-get -yq install libsystemd-dev || exiterr2
fi
make -s programs && make -s install

# Verify the install and clean up
cd /opt/src || exiterr "Cannot enter /opt/src."
/bin/rm -rf "/opt/src/libreswan-$swan_ver"
if ! /usr/local/sbin/ipsec --version 2>/dev/null | grep -qs "$swan_ver"; then
  exiterr "Libreswan $swan_ver failed to build."
fi

print_status "Creating VPN configuration..."

# Create IPsec (Libreswan) config
conf_bk "/etc/ipsec.conf"
cat > /etc/ipsec.conf <<EOF
version 2.0

config setup
  nat_traversal=yes
  virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:!192.168.42.0/23
  protostack=netkey
  nhelpers=0
  interfaces=%defaultroute
  uniqueids=no

conn shared
  left=$PRIVATE_IP
  leftid=$PUBLIC_IP
  right=%any
  forceencaps=yes
  authby=secret
  pfs=no
  rekey=no
  keyingtries=5
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  ike=3des-sha1,aes-sha1,aes256-sha2_512,aes256-sha2_256
  phase2alg=3des-sha1,aes-sha1,aes256-sha2_512,aes256-sha2_256
  sha2-truncbug=yes

conn l2tp-psk
  auto=add
  leftsubnet=$PRIVATE_IP/32
  leftnexthop=%defaultroute
  leftprotoport=17/1701
  rightprotoport=17/%any
  type=transport
  auth=esp
  also=shared

conn xauth-psk
  auto=add
  leftsubnet=0.0.0.0/0
  rightaddresspool=192.168.43.10-192.168.43.250
  modecfgdns1=8.8.8.8
  modecfgdns2=8.8.4.4
  leftxauthserver=yes
  rightxauthclient=yes
  leftmodecfgserver=yes
  rightmodecfgclient=yes
  modecfgpull=yes
  xauthby=file
  ike-frag=yes
  ikev2=never
  cisco-unity=yes
  also=shared
EOF

# Specify IPsec PSK
conf_bk "/etc/ipsec.secrets"
cat > /etc/ipsec.secrets <<EOF
$PUBLIC_IP  %any  : PSK "$VPN_IPSEC_PSK"
EOF

# Create xl2tpd config
conf_bk "/etc/xl2tpd/xl2tpd.conf"
cat > /etc/xl2tpd/xl2tpd.conf <<'EOF'
[global]
port = 1701

[lns default]
ip range = 192.168.42.10-192.168.42.250
local ip = 192.168.42.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# Set xl2tpd options
conf_bk "/etc/ppp/options.xl2tpd"
cat > /etc/ppp/options.xl2tpd <<'EOF'
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
mtu 1280
mru 1280
proxyarp
lcp-echo-failure 4
lcp-echo-interval 30
connect-delay 5000
EOF

# Create VPN credentials
conf_bk "/etc/ppp/chap-secrets"
cat > /etc/ppp/chap-secrets <<EOF
# Secrets for authentication using CHAP
# client  server  secret  IP addresses
"$VPN_USER" l2tpd "$VPN_PASSWORD" *
EOF

conf_bk "/etc/ipsec.d/passwd"
VPN_PASSWORD_ENC=$(openssl passwd -1 "$VPN_PASSWORD")
cat > /etc/ipsec.d/passwd <<EOF
$VPN_USER:$VPN_PASSWORD_ENC:xauth-psk
EOF

print_status "Updating sysctl settings..."

if ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf; then
  conf_bk "/etc/sysctl.conf"
cat >> /etc/sysctl.conf <<EOF

# Added by hwdsl2 VPN script
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.shmmax = 68719476736
kernel.shmall = 4294967296

net.ipv4.ip_forward = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.lo.send_redirects = 0
net.ipv4.conf.$NET_IF0.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.lo.rp_filter = 0
net.ipv4.conf.$NET_IF0.rp_filter = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

net.core.wmem_max = 12582912
net.core.rmem_max = 12582912
net.ipv4.tcp_rmem = 10240 87380 12582912
net.ipv4.tcp_wmem = 10240 87380 12582912
EOF
fi

print_status "Creating quota/ip-up.local/ip-down.local..."

cat > /etc/ppp/quota <<EOF
#
# This is the quota file
# The 1st field is ther username
# The 2nd field is the quota (in MB). "*" means unlimited.
# Sample:
# username  1000
#
$VPN_USER   *

EOF

conf_bk "/etc/ppp/ip-up.local"
cat > /etc/ppp/ip-up.local <<'EOF'
#!/bin/sh
VPNUSAGE_FILE=/var/log/vpnusage.log
VPNQUOTA_FILE=/etc/ppp/quota
LOG_FILE=/var/log/vpn.log
# Check quota
QUOTA=`awk '$1=="'${PEERNAME}'" {print $2}' $VPNQUOTA_FILE`
CURR_MONTH=`date -d today +%Y-%m`
CURRENT_USAGE=`awk -F, '$2~/'${PEERNAME}'/ && $1~/'${CURR_MONTH}'/ { sum = sum + $3 } END { printf ("%.2f", sum/1024/1024)}' $VPNUSAGE_FILE`

if [ "$QUOTA"x = "*x" ]
then
    echo "[CONN] `date -d today +%F_%T` ${PEERNAME}: Current usage $CURRENT_USAGE M is within the quota unlimited. Connected" >> $LOG_FILE
    exit 0
fi
if [ `echo "$CURRENT_USAGE < $QUOTA" | bc` -eq 1 ]
then
    echo "[CONN] `date -d today +%F_%T` ${PEERNAME}: Current Usage $CURRENT_USAGE M is within the quota $QUOTA M. Connected" >> $LOG_FILE
else
    echo "[TERM] `date -d today +%F_%T` ${PEERNAME}: Current Usage $CURRENT_USAGE M is over the quota $QUOTA M. Force terminate" >> $LOG_FILE
    kill $PPPD_PID
fi
EOF

conf_bk "/etc/ppp/ip-down.local"
cat > /etc/ppp/ip-down.local <<'EOF'
#!/bin/sh
VPNUSAGE_FILE=/var/log/vpnusage.log
LOG_FILE=/var/log/vpn.log
sum_bytes=$(($BYTES_SENT+$BYTES_RCVD))
sum=$(printf "%.2f" `echo "scale=2;$sum_bytes/1024/1024"|bc`)
ave=`echo "scale=2;$sum_bytes/1024/$CONNECT_TIME"|bc`

echo "[CLOS] `date -d today +%F_%T` ${PEERNAME}: Total online $CONNECT_TIME seconds, transferred $sum MB ($ave KB/s)." >> $LOG_FILE
echo "`date -d today +%F_%T` , $PEERNAME , $sum_bytes , $CONNECT_TIME" >> $VPNUSAGE_FILE
EOF

chmod +x /etc/ppp/ip-up.local
chmod +x /etc/ppp/ip-down.local


print_status "Updating IPTables rules..."

# Check if IPTables rules need updating
ipt_flag=0
IPT_FILE="/etc/iptables.rules"
if ! grep -qs "hwdsl2 VPN script" "$IPT_FILE" \
   || ! iptables -t nat -C POSTROUTING -s 192.168.42.0/24 -o "$NET_IFS" -j SNAT --to-source "$PRIVATE_IP" 2>/dev/null \
   || ! iptables -t nat -C POSTROUTING -s 192.168.43.0/24 -o "$NET_IFS" -m policy --dir out --pol none -j SNAT --to-source "$PRIVATE_IP" 2>/dev/null; then
  ipt_flag=1
fi

# Add IPTables rules for VPN
if [ "$ipt_flag" = "1" ]; then
  service fail2ban stop >/dev/null 2>&1
  iptables-save > "$IPT_FILE.old-$SYS_DT"
  iptables -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
  iptables -I INPUT 2 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I INPUT 3 -p udp -m multiport --dports 500,4500 -j ACCEPT
  iptables -I INPUT 4 -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
  iptables -I INPUT 5 -p udp --dport 1701 -j DROP
  iptables -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
  iptables -I FORWARD 2 -i "$NET_IFS" -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I FORWARD 3 -i ppp+ -o "$NET_IFS" -j ACCEPT
  iptables -I FORWARD 4 -i ppp+ -o ppp+ -s 192.168.42.0/24 -d 192.168.42.0/24 -j ACCEPT
  iptables -I FORWARD 5 -i "$NET_IFS" -d 192.168.43.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I FORWARD 6 -s 192.168.43.0/24 -o "$NET_IFS" -j ACCEPT
  # Uncomment if you wish to disallow traffic between VPN clients themselves
  # iptables -I FORWARD 2 -i ppp+ -o ppp+ -s 192.168.42.0/24 -d 192.168.42.0/24 -j DROP
  # iptables -I FORWARD 3 -s 192.168.43.0/24 -d 192.168.43.0/24 -j DROP
  iptables -A FORWARD -j DROP
  iptables -t nat -I POSTROUTING -s 192.168.43.0/24 -o "$NET_IFS" -m policy --dir out --pol none -j SNAT --to-source "$PRIVATE_IP"
  iptables -t nat -I POSTROUTING -s 192.168.42.0/24 -o "$NET_IFS" -j SNAT --to-source "$PRIVATE_IP"
  echo "# Modified by hwdsl2 VPN script" > "$IPT_FILE"
  iptables-save >> "$IPT_FILE"

  # Update rules for iptables-persistent
  IPT_FILE2="/etc/iptables/rules.v4"
  if [ -f "$IPT_FILE2" ]; then
    conf_bk "$IPT_FILE2"
    /bin/cp -f "$IPT_FILE" "$IPT_FILE2"
  fi
fi

print_status "Enabling services on boot..."

mkdir -p /etc/network/if-pre-up.d
cat > /etc/network/if-pre-up.d/iptablesload <<'EOF'
#!/bin/sh
iptables-restore < /etc/iptables.rules
exit 0
EOF

for svc in fail2ban ipsec xl2tpd; do
  update-rc.d "$svc" enable >/dev/null 2>&1
  systemctl enable "$svc" 2>/dev/null
done
if ! grep -qs "hwdsl2 VPN script" /etc/rc.local; then
  if [ -f /etc/rc.local ]; then
    conf_bk "/etc/rc.local"
    sed --follow-symlinks -i '/^exit 0/d' /etc/rc.local
  else
    echo '#!/bin/sh' > /etc/rc.local
  fi
cat >> /etc/rc.local <<'EOF'

# Added by hwdsl2 VPN script
service ipsec start
service xl2tpd start
echo 1 > /proc/sys/net/ipv4/ip_forward
exit 0
EOF
  if grep -qs raspbian /etc/os-release; then
    sed --follow-symlinks -i '/hwdsl2 VPN script/a sleep 15' /etc/rc.local
  fi
fi

print_status "Starting services..."

# Reload sysctl.conf
sysctl -e -q -p

# Update file attributes
chmod +x /etc/rc.local /etc/network/if-pre-up.d/iptablesload
chmod 600 /etc/ipsec.secrets* /etc/ppp/chap-secrets* /etc/ipsec.d/passwd*

# Apply new IPTables rules
iptables-restore < "$IPT_FILE"

# Restart services
service fail2ban restart 2>/dev/null
service ipsec restart 2>/dev/null
service xl2tpd restart 2>/dev/null


print_status "Adding lsquota tool..."

mkdir -p ~/bin
cat > ~/bin/lsquota <<'EOF'
#!/bin/sh
VPNUSAGE_FILE=/var/log/vpnusage.log
VPNQUOTA_FILE=/etc/ppp/quota
LOG_FILE=/var/log/vpn.log
# Check quota
#QUOTA=`awk '$1=="'${PEERNAME}'" {print $2}' $VPNQUOTA_FILE`
if [ -z $1 ]
then
	SEARCH_MONTH=`date -d today +%Y-%m`
else
	SEARCH_MONTH=$1
fi
sudo awk -F, '$1~/'${SEARCH_MONTH}'/ { quota_list[$2] = quota_list[$2] + $3 } END { for (quota in quota_list) printf ("%10s%10.2f M\n", quota, quota_list[quota]/1024/1024)}' $VPNUSAGE_FILE
EOF
chmod +x ~/bin/lsquota

cat <<EOF

================================================

IPsec VPN server is now ready for use!

Connect to your new VPN with these details:

Server IP: $PUBLIC_IP
IPsec PSK: $VPN_IPSEC_PSK
Username: $VPN_USER
Password: $VPN_PASSWORD

Write these down. You'll need them to connect!

Important notes:   https://git.io/vpnnotes
Setup VPN clients: https://git.io/vpnclients

================================================

EOF

exit 0

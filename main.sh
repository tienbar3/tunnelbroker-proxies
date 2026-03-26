#!/bin/bash

if ping6 -c3 google.com &>/dev/null; then
  echo "Your server is ready to set up IPv6 proxies!"
else
  echo "Your server can't connect to IPv6 addresses."
  echo "Please, connect ipv6 interface to your server to continue."
  exit 1
fi

####
echo "↓ Routed IPv6 prefix (example: xxxx:xxxx::/48 | /64 | /80):"
read PROXY_NETWORK

if [[ $PROXY_NETWORK == *"::/48"* ]]; then
  PROXY_NET_MASK=48
elif [[ $PROXY_NETWORK == *"::/64"* ]]; then
  PROXY_NET_MASK=64
elif [[ $PROXY_NETWORK == *"::/80"* ]]; then
  PROXY_NET_MASK=80
else
  echo "● Unsupported IPv6 prefix format: $PROXY_NETWORK"
  exit 1
fi

####
echo "↓ Server IPv4 address from tunnelbroker:"
read TUNNEL_IPV4_ADDR
if [[ ! "$TUNNEL_IPV4_ADDR" ]]; then
  echo "● IPv4 address can't be empty"
  exit 1
fi

####
echo "↓ Proxies login (can be blank):"
read PROXY_LOGIN

if [[ "$PROXY_LOGIN" ]]; then
  echo "↓ Proxies password:"
  read PROXY_PASS
  if [[ ! "$PROXY_PASS" ]]; then
    echo "● Proxies pass can't be empty"
    exit 1
  fi
fi

####
echo "↓ Port numbering start (default 1500):"
read PROXY_START_PORT
if [[ ! "$PROXY_START_PORT" ]]; then
  PROXY_START_PORT=1500
fi

####
echo "↓ Proxies count (default 1):"
read PROXY_COUNT
if [[ ! "$PROXY_COUNT" ]]; then
  PROXY_COUNT=1
fi

####
echo "↓ Proxies protocol (http, socks5; default http):"
read PROXY_PROTOCOL
if [[ "$PROXY_PROTOCOL" != "socks5" ]]; then
  PROXY_PROTOCOL="http"
fi

####
clear
sleep 1
PROXY_NETWORK=$(echo $PROXY_NETWORK | awk -F:: '{print $1}')
HOST_IPV4_ADDR=$(hostname -I | awk '{print $1}')

echo "● Network: $PROXY_NETWORK"
echo "● Network Mask: $PROXY_NET_MASK"
echo "● Host IPv4 address: $HOST_IPV4_ADDR"
echo "● Tunnel IPv4 address: $TUNNEL_IPV4_ADDR"
echo "● Proxies count: $PROXY_COUNT, starting from port: $PROXY_START_PORT"
echo "● Proxies protocol: $PROXY_PROTOCOL"

if [[ "$PROXY_LOGIN" ]]; then
  echo "● Proxies login: $PROXY_LOGIN"
  echo "● Proxies password: $PROXY_PASS"
fi

echo "-------------------------------------------------"
echo ">-- Installing dependencies"
apt-get update -y >/dev/null 2>&1
apt-get install -y gcc g++ make bc pwgen git wget >/dev/null 2>&1

####
echo ">-- System tuning"
cat >>/etc/sysctl.conf <<END
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.ip_nonlocal_bind=1
END
sysctl -p >/dev/null 2>&1

####
echo ">-- Installing ndppd"
cd ~
git clone https://github.com/DanielAdolfsson/ndppd.git >/dev/null 2>&1
cd ndppd
make >/dev/null 2>&1 && make install >/dev/null 2>&1

cat >~/ndppd.conf <<END
route-ttl 30000
proxy he-ipv6 {
   router no
   timeout 500
   ttl 30000
   rule ${PROXY_NETWORK}::/${PROXY_NET_MASK} {
      static
   }
}
END

####
echo ">-- Installing 3proxy"
cd ~
wget -q https://github.com/z3APA3A/3proxy/archive/0.8.13.tar.gz
tar xzf 0.8.13.tar.gz
mv 3proxy-0.8.13 3proxy
cd 3proxy
make -f Makefile.Linux >/dev/null 2>&1

cat >~/3proxy/3proxy.cfg <<END
daemon
maxconn 1000
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
flush
END

if [[ "$PROXY_LOGIN" ]]; then
cat >>~/3proxy/3proxy.cfg <<END
auth strong
users ${PROXY_LOGIN}:CL:${PROXY_PASS}
allow ${PROXY_LOGIN}
END
else
echo "auth none" >>~/3proxy/3proxy.cfg
fi

####
echo ">-- Generating IPv6 list"
> ~/ip.list
> ~/proxy.txt

HEX=(0 1 2 3 4 5 6 7 8 9 a b c d e f)

gen_ip() {
  for i in {1..8}; do
    printf "%x" $((RANDOM%16))
  done
}

for ((i=0;i<$PROXY_COUNT;i++)); do

  if [[ $PROXY_NET_MASK == 48 ]]; then
    IP="$PROXY_NETWORK:$(gen_ip):$(gen_ip):$(gen_ip):$(gen_ip)"
  elif [[ $PROXY_NET_MASK == 64 ]]; then
    IP="$PROXY_NETWORK:$(gen_ip):$(gen_ip):$(gen_ip)"
  elif [[ $PROXY_NET_MASK == 80 ]]; then
    IP="$PROXY_NETWORK:$(gen_ip):$(gen_ip)"
  fi

  echo $IP >> ~/ip.list
done

####
echo ">-- Creating proxy config"

PORT=$PROXY_START_PORT

while read ip; do
  echo "$([ $PROXY_PROTOCOL == "socks5" ] && echo "socks" || echo "proxy") -6 -n -a -p$PORT -i$HOST_IPV4_ADDR -e$ip" >>~/3proxy/3proxy.cfg

  if [[ "$PROXY_LOGIN" ]]; then
    echo "$PROXY_PROTOCOL://$PROXY_LOGIN:$PROXY_PASS@$HOST_IPV4_ADDR:$PORT" >> ~/proxy.txt
  else
    echo "$PROXY_PROTOCOL://$HOST_IPV4_ADDR:$PORT" >> ~/proxy.txt
  fi

  ((PORT++))
done < ~/ip.list

####
echo ">-- Creating startup script"

cat >/etc/rc.local <<END
#!/bin/bash
ip tunnel add he-ipv6 mode sit remote $TUNNEL_IPV4_ADDR local $HOST_IPV4_ADDR ttl 255
ip link set he-ipv6 up
ip addr add ${PROXY_NETWORK}::1/${PROXY_NET_MASK} dev he-ipv6
ip -6 route add default dev he-ipv6

~/ndppd/ndppd -d -c ~/ndppd.conf
~/3proxy/src/3proxy ~/3proxy/3proxy.cfg
exit 0
END

chmod +x /etc/rc.local

####
echo "DONE!"
echo "Proxy list saved in ~/proxy.txt"
echo "Rebooting..."

reboot

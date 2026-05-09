sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -X

# Set default policies to ACCEPT (clean state):

sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT

sudo iptables -t nat -A POSTROUTING -o wlp3s0 -j MASQUERADE
# Allow 
sudo iptables -A FORWARD -i wlp3s0 -o wlx984827c3f4db -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wlx984827c3f4db -o wlp3s0 -j ACCEPT

netfilter-persistent save


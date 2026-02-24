cat << EOF | fdisk /dev/sda
n
3


w
EOF
btrfs device add -f /dev/sda3 /
pacman -Syu --noconfirm
pacman -S --noconfirm git
git clone https://github.com/fuck-bitcoin/CLOAK_WALLET.git
(cd CLOAK_WALLET; git checkout $1; git submodule update --init; ./install-dev.sh)

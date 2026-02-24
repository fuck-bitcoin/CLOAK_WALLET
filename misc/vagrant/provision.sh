git clone https://github.com/fuck-bitcoin/CLOAK_WALLET.git $HOME/cloak-wallet
cd $HOME/cloak-wallet
git checkout $1
git submodule update --init --recursive
source misc/vagrant/build-ubuntu.sh $PWD

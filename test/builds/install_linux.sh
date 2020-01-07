#!/bin/bash

set -e

echo ----- add gcc7 repo -----
sudo add-apt-repository ppa:jonathonf/gcc-7.1
echo ----- add ghc repo -----
sudo add-apt-repository ppa:hvr/ghc -y
echo ----- apt-get update -----
sudo apt-get update
echo ----- apt-get install gcc ghc -----
sudo apt-get install gcc-7 g++-7 ghc-8.6.5 cabal-install-3.0
echo ----- perftools -----
sudo apt-get install libgoogle-perftools-dev google-perftools
echo ----- cabal update -----
/opt/cabal/3.0/bin/cabal update
echo ----- cabal install -----
/opt/cabal/3.0/bin/cabal v1-install --with-compiler /opt/ghc/8.6.5/bin/ghc-8.6.5 hspec parsec mtl hashable
echo ------ futhark -----
wget https://futhark-lang.org/releases/futhark-0.11.2-linux-x86_64.tar.xz
tar -xvaf futhark-0.11.2-linux-x86_64.tar.xz

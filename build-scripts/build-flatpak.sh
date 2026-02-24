#!/bin/sh

flatpak-builder --user --install --force-clean build-dir app.cloak.wallet.yml
flatpak build-export /root/repo build-dir
flatpak build-bundle /root/repo cloak-wallet.flatpak app.cloak.wallet

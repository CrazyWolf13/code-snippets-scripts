# @name: Ubuntu release upgrade
# @description: Updates packages, then upgrades to the next Ubuntu release (interactive)
# @os: Ubuntu
sudo apt update && sudo apt upgrade -y && sudo apt install -y update-manager-core && sudo do-release-upgrade

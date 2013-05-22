maintainer       "KT Cloudware"
description      "Installs Galera Cluster for MySQL"
long_description IO.read(File.join(File.dirname(__FILE__), 'README.md'))
version          "0.4.1"
recipe "server", "Installs Galera Cluster for MySQL"

%w{ debian ubuntu centos fedora redhat }.each do |os|
  supports os
end

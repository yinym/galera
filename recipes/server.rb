#
# Cookbook Name:: galera
# Recipe:: server
#

install_flag = "/root/.galera_installed"

group "mysql" do
end

user "mysql" do
  gid "mysql"
  comment "MySQL server"
  system true
  shell "/bin/false"
end

galera_config = node['galera']
mysql_tarball = galera_config['mysql_wsrep_tarball_' + node['kernel']['machine']]
# strip .tar.gz
mysql_package = mysql_tarball[0..-8]

mysql_wsrep_source = galera_config['mysql_wsrep_source']
galera_source = galera_config['galera_source']

Chef::Log.info "Downloading #{mysql_tarball}"
remote_file "#{Chef::Config[:file_cache_path]}/#{mysql_tarball}" do
  source "#{mysql_wsrep_source}/" + mysql_tarball
  action :create_if_missing
end

case node['platform']
when 'centos', 'redhat', 'fedora', 'suse', 'scientific', 'amazon'
  galera_package = galera_config['galera_package_' + node['kernel']['machine']]['rpm']
else
  galera_package = galera_config['galera_package_' + node['kernel']['machine']]['deb']
end

Chef::Log.info "Downloading #{galera_package}"
remote_file "#{Chef::Config[:file_cache_path]}/#{galera_package}" do
  source "#{galera_source}/" + galera_package
  action :create_if_missing
end

bash "install-mysql-package" do
  user "root"
  code <<-EOH
    zcat #{Chef::Config[:file_cache_path]}/#{mysql_tarball} | tar xf - -C #{node['mysql']['install_dir']}
    ln -sf #{node['mysql']['install_dir']}/#{mysql_package} #{node['mysql']['base_dir']}
  EOH
  not_if { File.directory?("#{node['mysql']['install_dir']}/#{mysql_package}") }
end

case node['platform']
  when 'centos', 'redhat', 'fedora', 'suse', 'scientific', 'amazon'
    bash "purge-mysql-galera" do
      user "root"
      code <<-EOH
        killall -9 mysqld_safe mysqld &> /dev/null
        yum remove mysql mysql-libs mysql-devel mysql-server mysql-bench
        cd #{node['mysql']['data_dir']}
        [ $? -eq 0 ] && rm -rf #{node['mysql']['data_dir']}/*
        rm -rf /etc/my.cnf /etc/mysql
        rm -f /root/#{install_flag}
      EOH
      only_if { !FileTest.exists?("#{install_flag}") }
    end
  else
    bash "purge-mysql-galera" do
      user "root"
      code <<-EOH
        killall -9 mysqld_safe mysqld &> /dev/null
        apt-get -y remove --purge mysql-server mysql-client mysql-common
        apt-get -y autoremove
        apt-get -y autoclean
        cd #{node['mysql']['data_dir']}
        [ $? -eq 0 ] && rm -rf #{node['mysql']['data_dir']}/*
        cd #{node['mysql']['conf_dir']}
        [ $? -eq 0 ] && rm -rf #{node['mysql']['conf_dir']}/*
        rm -f /root/#{install_flag}
      EOH
      only_if { !FileTest.exists?("#{install_flag}") }
    end
end

case node['platform']
when 'centos', 'redhat', 'fedora', 'suse', 'scientific', 'amazon'
  bash "install-galera" do
    user "root"
    code <<-EOH
      yum -y localinstall #{node['xtra']['packages']}
      yum -y localinstall #{Chef::Config[:file_cache_path]}/#{galera_package}
    EOH
    not_if { FileTest.exists?("#{node['wsrep']['provider']}") }
  end
else
  bash "install-galera" do
    user "root"
    code <<-EOH
      apt-get -y --force-yes install #{node['xtra']['packages']}
      dpkg -i #{Chef::Config[:file_cache_path]}/#{galera_package}
      apt-get -f install
    EOH
    not_if { FileTest.exists?("#{node['wsrep']['provider']}") }
  end
end

directory node['mysql']['conf_dir'] do
  owner "mysql"
  group "mysql"
  mode "0755"
  action :create
  recursive true
end

directory node['mysql']['data_dir'] do
  owner "mysql"
  group "mysql"
  mode "0755"
  action :create
  recursive true
end

directory node['mysql']['run_dir'] do
  owner "mysql"
  group "mysql"
  mode "0755"
  action :create
  recursive true
end

# install db to the data directory
execute "setup-mysql-datadir" do
  command "#{node['mysql']['base_dir']}/scripts/mysql_install_db --force --user=mysql --basedir=#{node['mysql']['base_dir']} --datadir=#{node['mysql']['data_dir']}"
  not_if { FileTest.exists?("#{node['mysql']['data_dir']}/mysql/user.frm") }
end


execute "setup-init.d-mysql-service" do
  command "cp #{node['mysql']['base_dir']}/support-files/mysql.server /etc/init.d/#{node['mysql']['servicename']}"
  not_if { FileTest.exists?("#{install_flag}") }
end

init_host = false
hosts = Array.new
members = Services.get('/services/mysql/members/').each do |member|
  hosts << File.basename(member.key)
end

wsrep_cluster_address = ''

# Assume that this mysql host has already been registered by ktc-database cook.
if hosts.length == 1 && hosts.first == node["fqdn"]
  Chef::Log.info("I've got the galera init position.")
  init_host = true
  wsrep_cluster_address = "gcomm://"
else
  hosts.each do |h|
    if h != node["fqdn"]
      wsrep_cluster_address += "gcomm://#{h}:#{node['wsrep']['port']},"
    end
  end
  wsrep_cluster_address = wsrep_cluster_address[0..-2]
end


template "my.cnf" do
  path "#{node['mysql']['conf_dir']}/my.cnf"
  source "my.cnf.erb"
  owner "mysql"
  group "mysql"
  mode "0644"
  variables :wsrep_urls => wsrep_cluster_address
  notifies :restart, "service[mysql]", :immediately
end

bash "wait-until-synced" do
  user "root"
  code <<-EOH
    state=0
    cnt=0
    until [[ "$state" == "4" || "$cnt" > 5 ]]
    do
      state=$(#{node['mysql']['mysql_bin']} -uroot -h127.0.0.1 -e "SET wsrep_on=0; SHOW GLOBAL STATUS LIKE 'wsrep_local_state'")
      state=$(echo "$state"  | tr '\n' ' ' | awk '{print $4}')
      cnt=$(($cnt + 1))
      sleep 1
    done
  EOH
  only_if { init_host && !FileTest.exists?("#{install_flag}") }
end

bash "set-wsrep-grants-mysqldump" do
  user "root"
  code <<-EOH
    #{node['mysql']['mysql_bin']} -uroot -h127.0.0.1 -e "GRANT ALL ON *.* TO '#{node['wsrep']['user']}'@'%' IDENTIFIED BY '#{node['wsrep']['password']}'"
    #{node['mysql']['mysql_bin']} -uroot -h127.0.0.1 -e "SET wsrep_on=0; GRANT ALL ON *.* TO '#{node['wsrep']['user']}'@'127.0.0.1' IDENTIFIED BY '#{node['wsrep']['password']}'"
  EOH
  only_if { init_host && (galera_config['sst_method'] == 'mysqldump') && !FileTest.exists?("#{install_flag}") }
end

bash "secure-mysql" do
  user "root"
  code <<-EOH
    #{node['mysql']['mysql_bin']} -uroot -h127.0.0.1 -e "DROP DATABASE IF EXISTS test; DELETE FROM mysql.db WHERE DB='test' OR DB='test\\_%'"
    #{node['mysql']['mysql_bin']} -uroot -h127.0.0.1 -e "UPDATE mysql.user SET Password=PASSWORD('#{node['mysql']['root_password']}') WHERE User='root'; DELETE FROM mysql.user WHERE User=''; DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1'); GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY '#{node['mysql']['root_password']}' WITH GRANT OPTION; FLUSH PRIVILEGES;"
  EOH
  only_if { init_host && (galera_config['secure'] == 'yes') && !FileTest.exists?("#{install_flag}") }
end

service "mysql" do
  supports :restart => true, :start => true, :stop => true
  service_name node['mysql']['servicename']
  action :nothing
end

execute "galera-installed" do
  command "touch #{install_flag}"
  action :run
  not_if { FileTest.exists?("#{install_flag}") }
end

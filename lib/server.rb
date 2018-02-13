class Server
  attr_reader :hostname, :password, :user

  def initialize(hostname, user=nil, password=nil)
    @hostname = hostname
    @user     = user ? user : $conf.user
    @password = password ? password : $conf.pass

    @ssh_connection = Net::SSH.start(@hostname, @user, password: @password)
  end

  def self.all
    $conf.hostnames.map{ |hostname| Server.new(hostname) }
  end

  def self.all_with_role(role)
    raise "Not implemented yet."
  end

  def self.find(identifier)
    if identifier == 'cm'
      Server.new($conf.cm.host)
    else
      nil
    end
  end

  def run(cmd, verbose=$conf.debug_mode)
    start_time = Time.now
    puts "BEGIN: #{cmd}"

    if verbose
      result = @ssh_connection.exec!(cmd)
      puts result
    else
      result = @ssh_connection.exec!(cmd)
    end

    end_time = Time.now
    duration = end_time - start_time
    puts "END (#{duration}s) \n\n"

    result
  end

  def scp(file_to_copy_path, destination_path)
    Net::SCP.upload!(@hostname,
                    $conf.user,
                    file_to_copy_path,
                    destination_path,
                    :ssh => { :password => $conf.password })
  end

  def mysql(cmd)
    run "mysql -e \"#{cmd}\""
  end

  def install(package_name, service_name=nil)
    # TODO - Check for errors, store in var, report at end of run
    puts "Checking if #{package_name} is installed"

    if (run "rpm -q #{package_name}") =~ /is not installed/
      puts "Installing #{package_name}"

      run "yum install -y #{package_name}"

      puts "#{package_name} installation complete"

      if service_name
        service(service_name).start_and_enable

        status = service(service_name).status
        raise "ERROR: #{service_name} could not be started on #{@hostname}" unless status =~ /active \(running\)/
      end

      return true
    else
      puts "#{package_name} is already installed"
      return false
    end
  end

  def service(name)
    Service.new(name, self)
  end

  def set_swappiness(amount=1)
    puts "Setting 'swappiness' to #{amount}."
    run "sh -c 'echo #{amount} > /proc/sys/vm/swappiness'"
  end

  def disable_transparent_hugepage
    thp_defrag_res = run "cat /sys/kernel/mm/transparent_hugepage/defrag"
    thp_res        = run "cat /sys/kernel/mm/transparent_hugepage/enabled"

    if thp_res =~ /\[never\]/ && thp_defrag_res =~ /\[never\]/
      puts "transparent_hugepage already disabled"
    else
      puts "Disabling transparent_hugepage"
      run "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
      run "echo never > /sys/kernel/mm/transparent_hugepage/defrag"

      puts "Modifying /etc/rc.d/rc.local to disable transparent_hugepage on startup"
      rc_local_file = run "cat /etc/rc.d/rc.local"

      unless rc_local_file =~ /\/sys\/kernel\/mm\/transparent_hugepage\/defrag/
        puts "Adding 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'"
        run "echo 'echo never > /sys/kernel/mm/transparent_hugepage/defrag' >> /etc/rc.d/rc.local"
      end

      unless rc_local_file =~ /\/sys\/kernel\/mm\/transparent_hugepage\/enabled/
        puts "Adding 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'"
        run "echo 'echo never > /sys/kernel/mm/transparent_hugepage/enabled' >> /etc/rc.d/rc.local"
      end

      puts "Ensuring /etc/rc.d/rc.local is executable"
      run "chmod +x /etc/rc.d/rc.local"
    end
  end

  def deploy_mysql_my_cnf(master_or_slave)
    if run("cat /etc/my.cnf") =~ /MiddleManager/
      puts "/etc/my.cnf already deployed"
    else
      puts "Deploying /etc/my.cnf"
      scp("./files/mysql_#{master_or_slave}_config.my.cnf", "/etc/my.cnf")
      puts "Removing /var/lib/mysql/ib_logfile*"
      run "rm -f /var/lib/mysql/ib_logfile*"
      service('mariadb').restart
    end
  end

  def install_jdk
    if run("yum list installed | grep jdk") =~ /jdk1\.8/
      puts "JDK for Java 8 already installed"
      return
    end

    puts "Installing JDK for Java 8"

    # XXX - Oracle likes to change the link to their JDK downloads.  If needed, get the new one from this page:
    # http://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html
    run 'cd /tmp; curl -L -b "oraclelicense=a" http://download.oracle.com/otn-pub/java/jdk/8u161-b12/2f38c3b165be4555a1fa6e98c45e0808/jdk-8u161-linux-x64.rpm -O'

    puts "Deploying /etc/profile.d/java.sh"
    scp("./files/java.sh", "/etc/profile.d/java.sh")

    run "chmod 744 /etc/profile.d/java.sh"
    run "source /etc/profile.d/java.sh"

    puts "Installing JDK 8 RPM"
    run "yum localinstall -y /tmp/jdk-8u161-linux-x64.rpm"
  end

  def install_jdbc_driver
    if run("ls /usr/share/java") =~ /mysql-connector-java\.jar/
      puts "JDBC driver already installed"
      return
    end

    puts "Installing JDBC driver - mysql-connector-java-5.1.45-bin.jar - in /usr/share/java"
    
    puts "Downloading JDBC driver"
    run "wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.45.tar.gz"
    run "tar -xzf mysql-connector-java-5.1.45.tar.gz"

    puts "Moving and renaming JDBC driver"
    run "mkdir /usr/share/java"
    run "mv mysql-connector-java-5.1.45/mysql-connector-java-5.1.45-bin.jar /usr/share/java/mysql-connector-java.jar"
    run "rm -rf mysql-connector-java-5.1.45*"
  end

  def install_cloudera_manager
    install "yum-utils"

    run "yum-config-manager --add-repo https://archive.cloudera.com/cm5/redhat/7/x86_64/cm/cloudera-manager.repo"

    install "cloudera-manager-daemons"
    install "cloudera-manager-server"

    puts "Verifying Cloudera Manager databases are configured properly"
    run "/usr/share/cmf/schema/scm_prepare_database.sh mysql cmserver cmserver_user #{$conf.mysql_cm_dbs_password}"

    service('cloudera-scm-server').start_and_enable
  end

  def test_connection
    raise "Must connect as root." if $conf.user != 'root'
    raise "Could not connect to #{@hostname}" unless run "hostname"=~ /#{@hostname}/
    true
  end
end
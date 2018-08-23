# rubocop:disable LineLength
# Gem Definition
require 'optparse'

# Global variables for filesystem locations
MONGO_DIR = '/var/lib/mongodb/'.freeze
PGSQL_DIR = '/var/lib/pgsql'.freeze
LOG_DIR = '/var/log/'.freeze
VAR_DIR = '/var'.freeze
PULP_DIR = '/var/lib/pulp'.freeze
PULP_CACHE_DIR = '/var/cache/pulp/'.freeze

# Define colors we can use for stdout messages
class String
  def red
    "\033[31m#{self}\033[0m"
  end

  def green
    "\033[32m#{self}\033[0m"
  end

  def yellow
    "\033[33m#{self}\33[0m"
  end
end

# Setup our options so we can run indvidual steps
options = {}
OptionParser.new do |opts|
  opts.banner = 'satellite-reset [OPTIONS]'

  opts.on('-p', '--pulp-tasks', 'Cancel all running and pending Pulp tasks - Deletes all running and pending Pulp tasks.') do |pulp|
    options[:pulp] = pulp
  end

  opts.on('-t', '--tasks', 'Truncate all Foreman Task and Dynflow Tables - Deletes ALL current and historical task data.') do |tasks|
    options[:tasks] = tasks
  end

  opts.on('-q', '--hornetq', 'Reset HornetQ journals and QPID queues, See: https://access.redhat.com/solutions/3380351.') do |qpid|
    options[:qpid] = qpid
  end

  opts.on('-m', '--mongo', 'Starts a repair of MongoDB - Takes a while depending on the size of your database.') do |mongo|
    options[:mongo] = mongo
  end
end.parse!

# Have the user confirm before starting anything
def confirm
  puts '\n!!!!!!!!! WARNING: This utility should only be used as directed by Red Hat Support.
  There is a risk for dataloss during these cleanup routines and should only be
  used when directly instructed to do so !!!!!!!!!'.red
  puts 'Are you sure you want to run this (Y/N)? '.red
  response = gets.chomp
  unless /[Y]/i.match(response)
    puts '**** cancelled ****'.red
  end
end

# Stop service method
def stop_services
  puts 'Stopping Satellite services.'.yellow
  `katello-service stop`
end

# start service method
def start_services
  puts 'Starting Satellite services.'.yellow
  `katello-service start`
end

# Check diskspace in Filesystem variables
def disk_space
  puts "Checking available diskspace in #{MONGO_DIR} #{PGSQL_DIR} #{LOG_DIR} #{VAR_DIR} #{PULP_DIR} #{PULP_CACHE_DIR} for free space.".green
  total_space = `df -k --output=avail /var/tmp`.split("\n").last.to_i
  mongo_size = File.directory?(@MONGO_DIR) ? `du -s  #{@MONGO_DIR}`.split[0].to_i : 0
  pgsql_size = File.directory?(@PGSQL_DIR) ? `du -s  #{@PGSQL_DIR}`.split[0].to_i : 0
  log_size = File.directory?(@LOG_DIR) ? `du -s  #{@LOG_DIR}`.split[0].to_i : 0
  var_size = File.directory?(@VAR_DIR) ? `du -s  #{@VAR_DIR}`.split[0].to_i : 0
  pulp_size = File.directory?(@PULP_DIR) ? `du -s  #{@PULP_DIR}`.split[0].to_i : 0
  pulp_cache_size = File.directory?(@PULP_CACHE_DIR) ? `du -s  #{@PULP_CACHE_DIR}`.split[0].to_i : 0
  if [mongo_size, pgsql_size, log_size, var_size, pulp_size, pulp_cache_size].all? { |total| total_space < total }
    puts "There is not enough free space #{total_space}, please add additional space and try again, exiting.".red
    exit
  else
    puts "There is #{total_space} free space on disk, which is more than the size of the required directory requirments, continuing with repair".yellow
  end
end

# Mongo repair steps
def mongo_repair
  puts 'Starting repair on MongoDB, this may take a while depending on the size.'.yellow
  `sudo -u mongodb mongod --dbpath /var/lib/mongodb --repair`
  unless $?.success? # exit out if repair did not finish.
    puts 'MongoDB repair didnt finish successfully, exiting'.red
    exit
  end
  `chown -R mongodb:mongodb #{@MONGO_DIR}`
  `systemctl start mongodb`
  puts 'MongoDB repair finished successfully, starting up Postgresql'.green
end

# QPID repair steps
def qpid_repair
  cert = 'etc/pki/katello/certs/katello-apache.crt'
  key = '/etc/pki/katello/private/katello-apache.key'
  puts 'Starting to repair QPID and HornetQ journals'.yellow
  `rm -rf /var/lib/qpidd/.qpidd /var/lib/qpidd/*`
  `rm -rf /var/lib/candlepin/hornetq/*`
  `systemctl start qpidd.service`
  puts 'Sleeping for 60 seconds for qpid to start fully'.yellow
  sleep 60
  # delete exchange
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b "amqps://localhost:5671" del exchange event --durable`
  # create exchange
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b "amqps://localhost:5671" add exchange topic event --durable`
  # delete queue
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b 'amqps://localhost:5671' del queue katello_event_queue --force`
  # create queue
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b 'amqps://localhost:5671' add queue katello_event_queue --durable`
  # bind queue to exchange with filtering
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b "amqps://localhost:5671" bind event katello_event_queue entitlement.deleted`
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b "amqps://localhost:5671" bind event katello_event_queue entitlement.created`
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b "amqps://localhost:5671" bind event katello_event_queue pool.created`
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b "amqps://localhost:5671" bind event katello_event_queue pool.deleted`
  `qpid-config --ssl-certificate #{cert} --ssl-key #{key} -b "amqps://localhost:5671" bind event katello_event_queue compliance.created`
  puts 'HornetQ/QPID journal reset: Complete'.green
end

# Dynflow repair steps
def dynflow_cleanup
  puts 'Starting to remove paused tasks related to Pulp and syncing.'.yellow
  `foreman-rake foreman_tasks:cleanup TASK_SEARCH='label = "Actions::Katello::Repository::Sync"' STATES=paused VERBOSE=true`
  `foreman-rake foreman_tasks:cleanup TASK_SEARCH='label = "Actions::Katello::System::GenerateApplicability"' STATES=paused VERBOSE=true`
  puts 'Finished removing paused tasks.'.green
  puts 'Starting to truncate foreman_tasks_tasks table'.yellow
  tasks = 'TRUNCATE TABLE dynflow_envelopes,dynflow_delayed_plans,dynflow_steps,dynflow_actions,dynflow_execution_plans,foreman_tasks_locks,foreman_tasks_tasks;'
  `sudo -i -u postgres psql -d foreman -c "#{tasks}"`
  puts 'Foreman Task and Dynflow table truncate: Complete'.green
end

# Pulp cleanup steps
def pulp_cleanup
  puts 'Checking for pulp-admin and if not present then install'
  pulp_version = `rpm -q pulp-server --queryformat "%{VERSION}"`
  `yum install pulp-admin-client-"#{pulp_version}" pulp-rpm-admin-extensions.noarch pulp-rpm-handlers.noarch`
  puts 'Grabbing the pulp-cleanup sript'
  `wget http://people.redhat.com/~chrobert/pulp-cancel -O /root/pulp-cancel`
  puts 'Running Pulp cleanup script'
  `/bin/bash /root/pulp-cancel`
end

# Call repair methods based on options given
if @options[:pulp]
  confirm
  disk_space
  pulp
end

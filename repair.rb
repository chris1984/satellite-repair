#!/usr/bin/env ruby

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

  opts.on('-h', '--help', 'Displays Help') do
		puts opts
		exit
  end
end.parse!

# Have the user confirm before starting anything
def confirm
  puts "\n!!!!!!!!! !!!!!!!!!
  WARNING: This utility should only be used as directed by Red Hat Support.
  There is a risk for dataloss during these cleanup routines and should only be
  used when directly instructed to do so ".red
  puts "\nAre you sure you want to run this (Y/N)? ".red
  response = gets.chomp
  unless /[Y]/i.match(response)
    puts "\n**** cancelled ****".red
    exit
  end
end

# Stop service method
def stop_services
  puts 'Stopping Satellite services.'.yellow
  `katello-service stop`
  puts
end

# Start service method
def start_services
  puts 'Starting Satellite services.'.yellow
  `katello-service start`
  puts
end

# Check diskspace in Filesystem variables
def disk_space
  puts
  puts "Checking available diskspace in \n#{MONGO_DIR} \n#{PGSQL_DIR} \n#{LOG_DIR} \n#{VAR_DIR} \n#{PULP_DIR} \n#{PULP_CACHE_DIR} for free space.".green
  total_space = `df -k --output=avail /var/tmp`.split("\n").last.to_i
  mongo_size = `du -s  #{@MONGO_DIR}`.split[0].to_i
  pgsql_size = `du -s  #{@PGSQL_DIR}`.split[0].to_i
  log_size = `du -s  #{@LOG_DIR}`.split[0].to_i
  var_size = `du -s  #{@VAR_DIR}`.split[0].to_i
  pulp_size = `du -s  #{@PULP_DIR}`.split[0].to_i
  pulp_cache_size = `du -s  #{@PULP_CACHE_DIR}`.split[0].to_i
  if [mongo_size, pgsql_size, log_size, var_size, pulp_size, pulp_cache_size].any? { |dir| total_space < dir }
    puts "There is not enough free space #{total_space}, please add additional space and try again, exiting.".red
    exit
  else
    puts "There is #{total_space} free space on disk, which is more than the size of the required directory requirements, continuing with repair.\n".yellow
  end
end

# Mongo repair steps
def mongo_repair
  puts 'Starting repair on MongoDB, this may take a while (upwords of 30 minutes.).'.yellow
  `sudo -u mongodb mongod --dbpath /var/lib/mongodb --repair`
  `chown -R mongodb:mongodb /var/lib/mongodb`
  `systemctl start mongod`
  puts "MongoDB repair finished successfully.\n".green
end

# QPID repair steps
def qpid_repair
  cert = '/etc/pki/katello/certs/java-client.crt'
  key = '/etc/pki/katello/private/java-client.key'
  puts 'Starting to repair QPID and HornetQ journals.'.yellow
  `rm -rf /var/lib/qpidd/.qpidd /var/lib/qpidd/*`
  `rm -rf /var/lib/candlepin/hornetq/*`
  `systemctl start qpidd.service`
  puts 'Sleeping for 60 seconds, for QPID to start fully.'.yellow
  sleep 60
  # Delete exchange
  puts 'Deleting Exchange.'.yellow
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b "amqps://localhost:5671" del exchange event --durable`
  # Create exchange
  puts 'Creating Exchange.'.yellow
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b "amqps://localhost:5671" add exchange topic event --durable`
  # Delete queue
  puts 'Deleting Event Queue.'.yellow
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b 'amqps://localhost:5671' del queue katello_event_queue --force`
  # Create queue
  puts 'Creating Event Queue.'.yellow
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b 'amqps://localhost:5671' add queue katello_event_queue --durable`
  # Bind queue to exchange with filtering
  puts 'Binding Event Queue to Exchange with filtering.'.yellow
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b "amqps://localhost:5671" bind event katello_event_queue entitlement.deleted`
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b "amqps://localhost:5671" bind event katello_event_queue entitlement.created`
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b "amqps://localhost:5671" bind event katello_event_queue pool.created`
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b "amqps://localhost:5671" bind event katello_event_queue pool.deleted`
  `qpid-config --ssl-certificate "#{cert}" --ssl-key "#{key}" -b "amqps://localhost:5671" bind event katello_event_queue compliance.created`
  puts "HornetQ/QPID journal reset: Complete.\n".green
end

# Dynflow repair steps
def dynflow_cleanup
  puts 'Starting PostgreSQL.'.yellow
  `systemctl start postgresql`
  puts 'Starting to remove paused tasks related to Pulp and syncing.'.yellow
  `foreman-rake foreman_tasks:cleanup TASK_SEARCH='label = "Actions::Katello::Repository::Sync"' STATES=paused VERBOSE=true`
  `foreman-rake foreman_tasks:cleanup TASK_SEARCH='label = "Actions::Katello::System::GenerateApplicability"' STATES=paused VERBOSE=true`
  puts 'Finished removing paused tasks.'.green
  puts 'Starting to truncate foreman_tasks_tasks table.'.yellow
  tasks = 'TRUNCATE TABLE dynflow_envelopes,dynflow_delayed_plans,dynflow_steps,dynflow_actions,dynflow_execution_plans,foreman_tasks_locks,foreman_tasks_tasks;'
  `sudo -i -u postgres psql -d foreman -c "#{tasks}"`
  puts "Foreman Task and Dynflow table truncate: Complete.\n".green
end

# Pulp cleanup steps
def pulp_cleanup
  puts 'Checking for pulp-admin.'.yellow
  `rpm -qa | grep pulp-admin`
  if $?.success?
    puts 'Grabbing the Pulp cleanup sript.'.yellow
    `wget http://people.redhat.com/~chrobert/pulp-cancel -O /root/pulp-cancel`
    puts 'Running Pulp cleanup script'.yellow
    `chmod +x /root/pulp-cancel`
    `/bin/bash /root/pulp-cancel`
    puts "Pulp cleanup: Complete.\n".green
  else
    puts "pulp-admin is not installed, please visit https://access.redhat.com/solutions/1295653 to install/configure pulp-admin.\n".red
    puts "Starting Services.\n".yellow
    `katello-service start`
    exit
  end
end

if options[:pulp]
  confirm
  disk_space
  stop_services
  pulp_cleanup
  start_services
end

if options[:tasks]
  confirm
  disk_space
  stop_services
  dynflow_cleanup
  start_services
end

if options[:qpid]
  confirm
  disk_space
  stop_services
  qpid_repair
  start_services
end

if options[:mongo]
  confirm
  disk_space
  stop_services
  mongo_repair
  start_services
end

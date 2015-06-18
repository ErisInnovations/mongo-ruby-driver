# Copyright (C) 2014-2015 MongoDB, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'mongo/cluster/topology'

module Mongo

  # Represents a group of servers on the server side, either as a single server, a
  # replica set, or a single or multiple mongos.
  #
  # @since 2.0.0
  class Cluster
    extend Forwardable
    include Event::Subscriber
    include Loggable

    # @return [ Hash ] The options hash.
    attr_reader :options

    # @return [ Object ] The cluster topology.
    attr_reader :topology

    def_delegators :topology, :replica_set?, :replica_set_name, :sharded?, :single?, :unknown?

    # Determine if this cluster of servers is equal to another object. Checks the
    # servers currently in the cluster, not what was configured.
    #
    # @example Is the cluster equal to the object?
    #   cluster == other
    #
    # @param [ Object ] other The object to compare to.
    #
    # @return [ true, false ] If the objects are equal.
    #
    # @since 2.0.0
    def ==(other)
      return false unless other.is_a?(Cluster)
      addresses == other.addresses && options == other.options
    end

    # Add a server to the cluster with the provided address. Useful in
    # auto-discovery of new servers when an existing server executes an ismaster
    # and potentially non-configured servers were included.
    #
    # @example Add the server for the address to the cluster.
    #   cluster.add('127.0.0.1:27018')
    #
    # @param [ String ] host The address of the server to add.
    #
    # @return [ Server ] The newly added server, if not present already.
    #
    # @since 2.0.0
    def add(host)
      address = Address.new(host)
      if !addresses.include?(address)
        if addition_allowed?(address)
          log_debug([ "Adding #{address.to_s} to the cluster." ])
          @update_lock.synchronize { @addresses.push(address) }
          server = Server.new(address, self, event_listeners, options)
          @servers_update.synchronize { @servers.push(server) }
          server
        end
      end
    end

    # Instantiate the new cluster.
    #
    # @example Instantiate the cluster.
    #   Mongo::Cluster.new(["127.0.0.1:27017"])
    #
    # @param [ Array<String> ] seeds The addresses of the configured servers.
    # @param [ Hash ] options The options.
    #
    # @since 2.0.0
    def initialize(seeds, options = {})
      @addresses = []
      @servers = []
      @event_listeners = Event::Listeners.new
      @options = options.freeze
      @topology = Topology.initial(seeds, options)
      @update_lock = Mutex.new

      subscribe_to(Event::DESCRIPTION_CHANGED, Event::DescriptionChanged.new(self))
      subscribe_to(Event::PRIMARY_ELECTED, Event::PrimaryElected.new(self))

      seeds.each{ |seed| add(seed) }
    end

    # Get the nicer formatted string for use in inspection.
    #
    # @example Inspect the cluster.
    #   cluster.inspect
    #
    # @return [ String ] The cluster inspection.
    #
    # @since 2.0.0
    def inspect
      "#<Mongo::Cluster:0x#{object_id} servers=#{servers} topology=#{topology.display_name}>"
    end

    # Get the next primary server we can send an operation to.
    #
    # @example Get the next primary server.
    #   cluster.next_primary
    #
    # @return [ Mongo::Server ] A primary server.
    #
    # @since 2.0.0
    def next_primary
      ServerSelector.get({ mode: :primary }, options).select_server(self)
    end

    # Elect a primary server from the description that has just changed to a
    # primary.
    #
    # @example Elect a primary server.
    #   cluster.elect_primary!(description)
    #
    # @param [ Server::Description ] description The newly elected primary.
    #
    # @return [ Topology ] The cluster topology.
    #
    # @since 2.0.0
    def elect_primary!(description)
      @topology = topology.elect_primary(description, servers_list)
    end

    # Remove the server from the cluster for the provided address, if it
    # exists.
    #
    # @example Remove the server from the cluster.
    #   server.remove('127.0.0.1:27017')
    #
    # @param [ String ] host The host/port or socket address.
    #
    # @since 2.0.0
    def remove(host)
      log_debug([ "#{host} being removed from the cluster." ])
      address = Address.new(host)
      removed_servers = @servers.select { |s| s.address == address }
      @update_lock.synchronize { @servers = @servers - removed_servers }
      removed_servers.each{ |server| server.disconnect! } if removed_servers
      @update_lock.synchronize { @addresses.reject! { |addr| addr == address } }
    end

    # Force a scan of all known servers in the cluster.
    #
    # @example Force a full cluster scan.
    #   cluster.scan!
    #
    # @note This operation is done synchronously. If servers in the cluster are
    #   down or slow to respond this can potentially be a slow operation.
    #
    # @return [ true ] Always true.
    #
    # @since 2.0.0
    def scan!
      servers_list.each{ |server| server.scan! } and true
    end

    # Get a list of server candidates from the cluster that can have operations
    # executed on them.
    #
    # @example Get the server candidates for an operation.
    #   cluster.servers
    #
    # @return [ Array<Server> ] The candidate servers.
    #
    # @since 2.0.0
    def servers
      topology.servers(servers_list.compact).compact
    end

    # Disconnect all servers.
    #
    # @example Disconnect the cluster's servers.
    #   cluster.disconnect!
    #
    # @return [ true ] Always true.
    #
    # @since 2.1.0
    def disconnect!
      @servers.each { |server| server.disconnect! } and true
    end

    # Reconnect all servers.
    #
    # @example Reconnect the cluster's servers.
    #   cluster.reconnect!
    #
    # @return [ true ] Always true.
    #
    # @since 2.1.0
    def reconnect!
      scan!
      servers.each { |server| server.reconnect! } and true
    end

    # Add hosts in a description to the cluster.
    #
    # @example Add hosts in a description to the cluster.
    #   cluster.add_hosts(description)
    #
    # @param [ Mongo::Server::Description ] description The description.
    #
    # @since 2.0.6
    def add_hosts(description)
      if topology.add_hosts?(description, servers_list)
        description.servers.each { |s| add(s) }
      end
    end

    # Remove hosts in a description from the cluster.
    #
    # @example Remove hosts in a description from the cluster.
    #   cluster.remove_hosts(description)
    #
    # @param [ Mongo::Server::Description ] description The description.
    #
    # @since 2.0.6
    def remove_hosts(description)
      if topology.remove_hosts?(description)
        servers_list.each do |s|
          remove(s.address.to_s) if topology.remove_server?(description, s)
        end
      end
    end

    # Create a cluster for the provided client, for use when we don't want the
    # client's original cluster instance to be the same.
    #
    # @api private
    #
    # @example Create a cluster for the client.
    #   Cluster.create(client)
    #
    # @param [ Client ] client The client to create on.
    #
    # @return [ Cluster ] The cluster.
    #
    # @since 2.0.0
    def self.create(client)
      cluster = Cluster.new(client.cluster.addresses.map(&:to_s), client.options)
      client.instance_variable_set(:@cluster, cluster)
    end

    # The addresses in the cluster.
    #
    # @example Get the addresses in the cluster.
    #   cluster.addresses
    #
    # @return [ Array<Mongo::Address> ] The addresses.
    #
    # @since 2.0.6
    def addresses
      addresses_list
    end

    private

    def direct_connection?(address)
      address.seed == @topology.seed
    end

    def addition_allowed?(address)
      !@topology.single? || direct_connection?(address)
    end

    def servers_list
      @update_lock.synchronize do
        @servers.reduce([]) do |servers, server|
          servers << server
        end
      end
    end

    def addresses_list
      @update_lock.synchronize do
        @addresses.reduce([]) do |addresses, address|
          addresses << address
        end
      end
    end
  end
end

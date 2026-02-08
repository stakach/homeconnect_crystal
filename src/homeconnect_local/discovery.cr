require "dns"

module HomeconnectLocal
  SERVICE_DOMAIN = "_homeconnect._tcp.local"

  struct DiscoveredDevice
    getter service_name : String
    getter target_host : String?
    getter port : Int32?
    getter ip_addresses : Array(String)

    def initialize(
      @service_name : String,
      @target_host : String? = nil,
      @port : Int32? = nil,
      @ip_addresses : Array(String) = [] of String,
    )
    end
  end

  # Discover Home Connect devices on the local network using mDNS.
  #
  # The resolver flow is:
  # - PTR: _homeconnect._tcp.local -> instance service names
  # - SRV: instance -> target host + port
  # - A/AAAA: target host -> IP addresses
  def self.discover_devices(
    timeout : Time::Span = 2.seconds,
    service_domain : String = SERVICE_DOMAIN,
  ) : Array(DiscoveredDevice)
    previous_timeout = DNS.timeout
    DNS.timeout = timeout

    begin
      service_entries = DNS.query(service_domain, {DNS::RecordType::PTR}).compact_map do |record|
        next unless record.record_type.ptr?
        resource = record.resource
        next unless resource
        resource.as(DNS::Resource::PTR).domain_name
      end
      service_entries.uniq!
      puts "Found #{service_entries}"

      devices = [] of DiscoveredDevice
      service_entries.each do |service_name|
        srv_records = DNS.query(service_name, {DNS::RecordType::SRV})
        srv = srv_records.find(&.record_type.srv?)
        unless srv && (srv_resource = srv.resource)
          devices << DiscoveredDevice.new(service_name: service_name)
          next
        end

        srv_data = srv_resource.as(DNS::Resource::SRV)
        target = srv_data.target
        port = srv_data.port.to_i

        addresses = [] of String
        DNS.query(target, {DNS::RecordType::A, DNS::RecordType::AAAA}).each do |answer|
          if answer.record_type.a? || answer.record_type.aaaa?
            begin
              addresses << answer.ip_address.address
            rescue
            end
          end
        end

        devices << DiscoveredDevice.new(
          service_name: service_name,
          target_host: target,
          port: port,
          ip_addresses: addresses.uniq
        )
      end

      devices
    rescue
      [] of DiscoveredDevice
    ensure
      DNS.timeout = previous_timeout
    end
  end
end

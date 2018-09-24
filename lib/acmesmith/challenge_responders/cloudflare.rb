require 'acmesmith/challenge_responders/base'

require 'cloudflare'

module Acmesmith
  module ChallengeResponders
    class Cloudflare < Base
      def support?(type)
        type == 'dns-01'
      end

      def cap_respond_all?
        true
      end

      def initialize(config)
        @config = config
        key = config[:key] || ENV['CLOUDFLARE_KEY']
        email = config[:email] || ENV['CLOUDFLARE_EMAIL']
        connection = ::Cloudflare.connect(key: key, email: email)
        @zones = config[:zones].map { |z|
          connection.zones.find_by_name(z) or
          fail "#{z.to_s} is not configured in Cloudflare"
        }
      end

      def respond_all(*domain_challenges)
        domain_challenges.each do |domain, challenge|
          zone = find_zone(domain)
          name = [challenge.record_name, domain].join(?.)
          res = create_zone(zone, name, challenge)
          unless res.body[:success]
            still_fail = true
            if res.body[:errors][0][:code] == 81057 # already exists
              puts "found old challenge for #{domain}; remove and retry"
              delete_zone(domain, challenge)
              res = create_zone(zone, name, challenge)
              still_fail = !res.body[:success]
            end
            fail res.body[:errors].map(&:to_s).join(?\n) if still_fail
          end
        end
        domain_challenges.each do |domain, challenge|
          name = [challenge.record_name, domain].join(?.)
          wait(find_zone(domain), domain, name)
        end
      end

      def cleanup_all(*domain_and_challenges)
        domain_challenges.each do |domain, challenge|
          delete_zone(domain, challenge)
        end
      end
      
      private

      def find_zone(domain)
        @zones.find { |z| domain.end_with?(z.record[:name]) }
      end

      def delete_zone(domain, challenge)
        zone = find_zone(domain)
        name = [challenge.record_name, domain].join(?.)
        if record = zone.dns_records.find_by_name(name)
          record.delete
        end
      end

      def create_zone(zone, name, challenge)
        zone.dns_records.post(
          {
            type: challenge.record_type,
            name: name,
            content: challenge.record_content,
            ttl: @config[:ttl],
          }.to_json,
          content_type: 'application/json'
        )
      end

      def wait(zone, domain, name)
        puts "=> Waiting for change: #{domain}"

        until zone.dns_records.find_by_name(name)
          sleep 0.2
        end
      end
    end
  end
end

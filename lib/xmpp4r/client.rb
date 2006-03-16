# =XMPP4R - XMPP Library for Ruby
# License:: Ruby's license (see the LICENSE file) or GNU GPL, at your option.
# Website::http://home.gna.org/xmpp4r/

require 'resolv'

require 'xmpp4r/connection'
require 'xmpp4r/authenticationfailure'
require 'xmpp4r/sasl'

module Jabber

  # The client class provides everything needed to build a basic XMPP Client.
  class Client  < Connection

    # The client's JID
    attr_reader :jid

    ##
    # Create a new Client. If threaded mode is activated, callbacks are called
    # as soon as messages are received; If it isn't, you have to call
    # Stream#process from time to time.
    #
    # Remember to *always* put a resource in your JID unless the server can do SASL.
    def initialize(jid, threaded = true)
      unless threaded
        $stderr.puts "Non-threaded mode is currently broken, re-enabling threaded"
        threaded = true
      end

      super(threaded)
      @jid = (jid.kind_of?(JID) ? jid : JID.new(jid.to_s))
    end

    ##
    # connect to the server
    # (chaining-friendly)
    #
    # If you omit the optional host argument SRV records for your jid will
    # be resolved. If none works, fallback is connecting to the domain part
    # of the jid.
    # host:: [String] Optional c2s host, will be extracted from jid if nil
    # return:: self
    def connect(host = nil, port = 5222)
      if host.nil?
        begin
          srv = []
          Resolv::DNS.open { |dns|
            # If ruby version is too old and SRV is unknown, this will raise a NameError
            # which is catched below
            Jabber::debuglog("RESOLVING:\n_xmpp-client._tcp.#{@jid.domain} (SRV)")
            srv = dns.getresources("_xmpp-client._tcp.#{@jid.domain}", Resolv::DNS::Resource::IN::SRV)
          }
          # Sort SRV records: lowest priority first, highest weight first
          srv.sort! { |a,b| (a.priority != b.priority) ? (a.priority <=> b.priority) : (b.weight <=> a.weight) }

          srv.each { |record|
            begin
              connect(record.target.to_s, record.port)
              # Success
              return self
            rescue SocketError
              # Try next SRV record
            end
          }
        rescue NameError
          $stderr.puts "Resolv::DNS does not support SRV records. Please upgrade to ruby-1.8.3 or later!"
        end
        # Fallback to normal connect method
      end
      
      super(host.nil? ? jid.domain : host, port)
      self
    end

    ##
    # Close the connection,
    # sends <tt></stream:stream></tt> tag first
    def close
      send("</stream:stream>")
      super
    end

    ##
    # Start the stream-parser and send the client-specific stream opening element
    def start
      super
      send(generate_stream_start(@jid.domain)) { |e|
        if e.name == 'stream'
          true
        else
          false
        end
      }
    end

    ##
    # Authenticate with the server
    #
    # Throws AuthenticationFailure
    #
    # Authentication mechanisms are used in the following preference:
    # * SASL DIGEST-MD5
    # * SASL PLAIN
    # * Non-SASL digest
    # password:: [String]
    def auth(password)
      begin
        if @stream_mechanisms.include? 'DIGEST-MD5'
          auth_sasl SASL.new(self, 'DIGEST-MD5'), password
        elsif @stream_mechanisms.include? 'PLAIN'
          auth_sasl SASL.new(self, 'PLAIN'), password
        else
          auth_nonsasl(password)
        end
      rescue
        Jabber::debuglog("#{$!.class}: #{$!}\n#{$!.backtrace.join("\n")}")
        raise AuthenticationFailure.new, $!.to_s
      end
    end

    ##
    # Use a SASL authentication mechanism and bind to a resource
    #
    # If there was no resource given in the jid, the jid/resource
    # generated by the server will be accepted.
    #
    # This method should not be used directly. Instead, Client#auth
    # may look for the best mechanism suitable.
    # sasl:: Descendant of [Jabber::SASL::Base]
    # password:: [String]
    def auth_sasl(sasl, password)
      sasl.auth(password)

      # Restart stream after SASL auth
      stop
      start
      # And wait for features - again
      @features_lock.lock
      @features_lock.unlock

      # Resource binding (RFC3920 - 7)
      if @stream_features.has_key? 'bind'
        iq = Iq.new(:set)
        bind = iq.add REXML::Element.new('bind')
        bind.add_namespace @stream_features['bind']
        if jid.resource
          resource = bind.add REXML::Element.new('resource')
          resource.text = jid.resource
        end

        send_with_id(iq) { |reply|
          reported_jid = reply.first_element('jid')
          if reply.type == :result and reported_jid and reported_jid.text
            @jid = JID.new(reported_jid.text)
          end

          true
        }
      end

      # Session starting
      if @stream_features.has_key? 'session'
        iq = Iq.new(:set)
        session = iq.add REXML::Element.new('session')
        session.add_namespace @stream_features['session']

        send_with_id(iq) { true }
      end
    end

    ##
    # Send auth with given password and wait for result
    # (non-SASL)
    #
    # Throws ErrorException
    # password:: [String] the password
    # digest:: [Boolean] use Digest authentication
    def auth_nonsasl(password, digest=true)
      authset = nil
      if digest
        authset = Iq::new_authset_digest(@jid, @streamid.to_s, password)
      else
        authset = Iq::new_authset(@jid, password)
      end
      send_with_id(authset) do |r|
        true
      end
      $defout.flush

      true
    end

    ##
    # Register a new user account
    # (may be used instead of Client#auth)
    #
    # This method may raise ErrorException if the registration was
    # not successful.
    def register(password)
      reg = Iq.new_register(jid.node, password)
      reg.to = jid.domain
      send_with_id(reg) { |answer|
        true
      }
    end

    ##
    # Remove the registration of a user account
    #
    # *WARNING:* this deletes your roster and everything else
    # stored on the server!
    def remove_registration
      reg = Iq.new_register
      reg.to = jid.domain
      reg.query.add(REXML::Element.new('remove'))
      send_with_id(reg) { |answer|
        p answer.to_s
        true
      }
    end

    ##
    # Change the client's password
    #
    # Threading is suggested, as this code waits
    # for an answer.
    #
    # Raises an exception upon error response (ErrorException from
    # Stream#send_with_id).
    # new_password:: [String] New password
    def password=(new_password)
      iq = Iq::new_query(:set, @jid.domain)
      iq.query.add_namespace('jabber:iq:register')
      iq.query.add(REXML::Element.new('username')).text = @jid.node
      iq.query.add(REXML::Element.new('password')).text = new_password

      err = nil
      send_with_id(iq) { |answer|
        if answer.type == :result
          true
        else
          false
        end
      }
    end
  end  
end

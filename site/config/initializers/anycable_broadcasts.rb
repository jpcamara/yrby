# Rails sends each broadcast to the embedded anycable-go over HTTP (see
# config/anycable.yml), and every document update the site accepts is a
# broadcast. anycable-core's HTTP adapter opens a new TCP connection for each
# one and closes it after. Every closed connection holds a local port in
# TIME_WAIT for a while, and at a few hundred broadcasts a second the box runs
# out of ports. Connects then fail and the adapter retries with sleeps, so
# broadcasts back up and people stop seeing each other's edits. Each request
# also waits for a TCP handshake first, on the one thread that sends them all.
#
# This keeps one connection open per process and sends every broadcast on it.
# A connection the Go server closed raises on the next request, and that
# request reconnects and goes again, with the adapter's own attempts and
# delays.
require "anycable/broadcast_adapters/http"

module KeptAliveBroadcasts
  RECONNECT_ON = [Timeout::Error, EOFError, IOError, Errno::EPIPE,
                  *AnyCable::BroadcastAdapters::Http::RECOVERABLE_EXCEPTIONS].freeze

  private

  def build_http
    attempts = 0
    begin
      yield(@http ||= start_http)
    rescue *RECONNECT_ON => e
      drop_http
      attempts += 1
      if attempts > self.class::MAX_ATTEMPTS
        logger.error("Broadcast request failed: #{e.message}")
        return
      end

      sleep((self.class::DELAY**attempts).to_int * attempts)
      retry
    end
  end

  def start_http
    Net::HTTP.new(uri.host, uri.port).tap do |http|
      http.open_timeout = self.class::OPEN_TIMEOUT
      http.read_timeout = self.class::READ_TIMEOUT
      http.use_ssl = url.match?(/^https/)
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.start
    end
  end

  def drop_http
    @http&.finish
  rescue IOError
    nil # never started, or already closed
  ensure
    @http = nil
  end
end

AnyCable::BroadcastAdapters::Http.prepend(KeptAliveBroadcasts)

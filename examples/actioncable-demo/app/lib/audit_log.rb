# frozen_string_literal: true

require "base64"
require "fileutils"

# A durable, append-only audit log of every document change — the demo's
# stand-in for whatever Wealthbox records to. yrb-lite's `on_change` hook
# calls `record` *before* the change is applied or broadcast, and serialized
# per document, so this log is the authoritative order of changes.
#
# Each entry is one CRDT update delta (base64). Replaying the entries in
# order onto a fresh Y.Doc reconstructs the document exactly.
#
# It also supports fault injection (delay / fail-once) so the end-to-end
# tests can drive the store's behavior and prove that no other client ever
# sees a change before it's stored.
class AuditLog
  @mutex = Mutex.new
  @control_mutex = Mutex.new
  @entries = Hash.new { |hash, key| hash[key] = [] }
  @delays = Hash.new(0.0)
  @fail_once = {}

  class << self
    # Synchronously persist a change. Writes + fsyncs before returning, so a
    # successful return means the change is durable. Raising here (e.g. disk
    # full) makes yrb-lite reject the change: it is never applied or sent.
    def record(key, update)
      simulate_latency(key)
      raise "audit store unavailable (injected for #{key})" if fail_injected?(key)

      encoded = Base64.strict_encode64(update)
      @mutex.synchronize do
        @entries[key] << encoded
        File.open(path_for(key), "a") do |file|
          file.write("#{encoded}\n")
          file.flush
          file.fsync
        end
      end
    end

    def entries(key)
      @mutex.synchronize { @entries[key].dup }
    end

    # Rebuild a document from its on-disk audit log by replaying every recorded
    # delta. Used as the `on_load` hook, so a document survives eviction or a
    # server crash. Tolerant of a torn final line (a crash mid-fsync-append):
    # an undecodable line is skipped rather than corrupting the rebuild.
    # Returns a single merged Y.js update, or nil for an empty/missing log.
    def replay(key)
      path = path_for(key)
      return nil unless File.exist?(path)

      doc = YrbLite::Doc.new
      applied = 0
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty?

        begin
          doc.apply_update(Base64.strict_decode64(line))
          applied += 1
        rescue StandardError
          next # torn/partial line from a crash mid-append — skip it
        end
      end
      applied.zero? ? nil : doc.encode_state_as_update
    end

    # -- Fault injection / test controls -----------------------------------

    def set_delay(key, seconds)
      @control_mutex.synchronize { @delays[key] = seconds.to_f }
    end

    def fail_next(key)
      @control_mutex.synchronize { @fail_once[key] = true }
    end

    def reset!(key)
      @mutex.synchronize { @entries.delete(key) }
      @control_mutex.synchronize do
        @delays.delete(key)
        @fail_once.delete(key)
      end
      path = path_for(key)
      File.delete(path) if File.exist?(path)
    end

    private

    def simulate_latency(key)
      delay = @control_mutex.synchronize { @delays[key] }
      sleep(delay) if delay.positive?
    end

    def fail_injected?(key)
      @control_mutex.synchronize { @fail_once.delete(key) }
    end

    def path_for(key)
      dir = Rails.root.join("tmp", "audit")
      FileUtils.mkdir_p(dir)
      dir.join("#{key.gsub(/[^a-zA-Z0-9_-]/, '_')}.log")
    end
  end
end

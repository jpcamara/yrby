# frozen_string_literal: true

require "base64"
require "fileutils"

# A durable, append-only audit log of every document change; the demo's
# stand-in for whatever a real app would record to. yrby's `on_change` hook
# calls `record` before the change is applied or broadcast, serialized per
# document, so the log keeps changes in the order they happened.
#
# Each entry is one CRDT update delta (base64). Replaying the entries in order
# onto a fresh Y.Doc reconstructs the document.
#
# It also supports fault injection (delay, fail-once) so the end-to-end tests
# can make the store misbehave and check that no other client sees a change
# before it's stored.
class AuditLog
  @locks = Hash.new { |h, k| h[k] = Mutex.new } # per-document, so different
  @locks_guard = Mutex.new                       # docs record concurrently
  @handles = {}                                  # cached append handles per key

  class << self
    # Synchronously persist a change. Writes + fsyncs before returning, so a
    # successful return means the change is durable. Raising here (e.g. disk
    # full) makes yrby reject the change: it is never applied or sent.
    #
    # Every server process appends to the same file (O_APPEND is atomic), so
    # the history is shared across a multi-process deployment rather than living
    # per-process.
    def record(key, update)
      Fault.simulate(key)

      encoded = Base64.strict_encode64(update)
      # Per-document lock + a cached append handle: different documents record
      # in parallel (like distinct rows in a real DB), while a single document's
      # log stays correctly ordered. Still fsync-durable before returning.
      lock_for(key).synchronize do
        file = handle_for(key)
        file.write("#{encoded}\n")
        file.flush
        file.fsync
      end
    end

    def entries(key)
      path = path_for(key)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).reject(&:empty?)
    end

    # Rebuild a document from its on-disk audit log by replaying every recorded
    # delta. Used as the `on_load` hook, so a document survives eviction or a
    # server crash. Tolerant of a torn final line (a crash mid-fsync-append):
    # an undecodable line is skipped rather than corrupting the rebuild.
    # Returns a single merged Y.js update, or nil for an empty/missing log.
    def replay(key)
      path = path_for(key)
      return nil unless File.exist?(path)

      doc = Y::Doc.new
      applied = 0
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty?

        begin
          doc.apply_update(Base64.strict_decode64(line))
          applied += 1
        rescue StandardError
          next # torn/partial line from a crash mid-append; skip it
        end
      end
      applied.zero? ? nil : doc.encode_state_as_update
    end

    def reset!(key)
      lock_for(key).synchronize do
        if (handle = @handles.delete(key))
          handle.close rescue nil
        end
        File.delete(path_for(key)) if File.exist?(path_for(key))
      end
      Fault.reset!(key)
    end

    private

    def lock_for(key)
      @locks_guard.synchronize { @locks[key] }
    end

    def handle_for(key)
      @handles[key] ||= File.open(path_for(key), "a")
    end

    def path_for(key)
      dir = Rails.root.join("tmp", "audit")
      FileUtils.mkdir_p(dir)
      dir.join("#{key.gsub(/[^a-zA-Z0-9_-]/, '_')}.log")
    end
  end
end

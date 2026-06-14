# frozen_string_literal: true

require "json"
require "fileutils"

# File-based fault injection shared by the stores, so the end-to-end tests can
# make a store slow or fail and prove record-before-distribute. It's file-based
# because the control endpoint runs in Puma while `record` runs in the AnyCable
# RPC server — different processes.
module Fault
  @mutex = Mutex.new

  class << self
    # Called inside a store's record(): apply an injected delay, then raise if a
    # one-shot failure is armed (consuming it atomically).
    def simulate(key)
      fault = read(key)
      delay = fault["delay_ms"].to_f / 1000
      sleep(delay) if delay.positive?
      raise "store unavailable (injected for #{key})" if consume_fail(key)
    end

    def set_delay(key, seconds)
      update(key) { |f| f["delay_ms"] = seconds.to_f * 1000 }
    end

    def fail_next(key)
      update(key) { |f| f["fail_once"] = true }
    end

    def reset!(key)
      path = path_for(key)
      @mutex.synchronize { File.delete(path) if File.exist?(path) }
    end

    private

    def consume_fail(key)
      @mutex.synchronize do
        fault = read(key)
        next false unless fault["fail_once"]

        fault.delete("fail_once")
        write(key, fault)
        true
      end
    end

    def update(key)
      @mutex.synchronize do
        fault = read(key)
        yield fault
        write(key, fault)
      end
    end

    def read(key)
      path = path_for(key)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      {}
    end

    def write(key, fault)
      path = path_for(key)
      fault.empty? ? (File.delete(path) if File.exist?(path)) : File.write(path, JSON.generate(fault))
    end

    def path_for(key)
      dir = Rails.root.join("tmp", "faults")
      FileUtils.mkdir_p(dir)
      dir.join("#{key.gsub(/[^a-zA-Z0-9_-]/, '_')}.json")
    end
  end
end

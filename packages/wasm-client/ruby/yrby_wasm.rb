# frozen_string_literal: true

require "js"
require "json"

module Yrby
  module Wasm
    LOCAL_ORIGIN = "yrby-wasm-local"

    # Browser Ruby facade over the experimental Yrs/WASM provider. JSON crosses
    # the runtime boundary explicitly: large document IDs never become JS floats
    # through Ruby's implicit object conversion, and nil remains a JSON null.
    class Client
      attr_reader :native, :doc

      def initialize(channel: "DocumentChannel", params: {}, presence: nil, resend_interval: nil, native: nil)
        options = { channel: channel, params: params, localState: presence }
        options[:resendInterval] = resend_interval if resend_interval
        @native = native || JS.global[:YrbyWasm].createClient(JSON.generate(options))
        @doc = Document.new(@native)
      end

      def connect = @native.connect
      def disconnect = @native.disconnect
      def destroy = @native.destroy
      def synced? = @native[:synced] == JS::True
      def pending? = @native[:hasPending] == JS::True
      def status = JSON.parse(@native.getStatus.to_s)
      def presence = JSON.parse(@native.getPresenceJSON.to_s)
      def presence=(state)
        @native.setPresenceJSON(JSON.generate(state))
      end
      def renew(params) = @native.renew(JS.global[:JSON].parse(JSON.generate(params)))

      # The returned callable unsubscribes. Callbacks are deferred until both
      # WASM runtimes are out of their transactions; their return values are ignored.
      def on_change(&block)
        unsubscribe = @native.onChange(-> { block.call; nil })
        -> { unsubscribe.call(:call); nil }
      end

      def on_status(&block)
        unsubscribe = @native.onStatus(->(json) { block.call(JSON.parse(json.to_s)); nil })
        -> { unsubscribe.call(:call); nil }
      end

      # These return JS promises, usable with .await inside vm.evalAsync. They
      # must not be awaited from a synchronous DOM event callback.
      def when_synced = @native[:whenSynced]
      def when_acknowledged = @native[:whenAcknowledged]
      def pending_update
        bytes = @native[:pendingUpdate]
        bytes == JS::Null ? nil : bytes
      end
      def restore_pending_update(bytes) = @native.restorePendingUpdate(bytes)
      def apply_remote_update(bytes) = @native.applyRemoteUpdate(bytes)
      def encode_state_vector = @native.encodeStateVector
      def encode_state_as_update(vector = nil)
        vector ? @native.encodeStateAsUpdate(vector) : @native.encodeStateAsUpdate
      end
    end

    class Document
      def initialize(native)
        @native = native
        @roots = {}
      end

      def map(name) = root(Map, :map, name)
      def text(name) = root(Text, :text, name)
      def array(name) = root(Array, :array, name)

      # Open shared roots before entering this block. Nesting is rejected by the
      # provider. Like Yjs, a transaction batches updates; it does not roll back.
      def transaction(origin: LOCAL_ORIGIN)
        @native.beginTransaction(origin)
        begin
          yield self
        ensure
          @native.endTransaction
        end
      end

      def undo_manager(*scopes, origin: LOCAL_ORIGIN, capture_timeout: 500)
        handles = JS.global[:Array].new
        scopes.flatten.each { |scope| handles.push(scope.respond_to?(:native) ? scope.native : scope.to_s) }
        UndoManager.new(@native.createUndoManager(handles, origin, capture_timeout))
      end

      private

      def root(type, method, name)
        @roots[[method, name.to_s]] ||= type.new(@native.call(method, name.to_s))
      end
    end

    class SharedType
      attr_reader :native
      def initialize(native) = @native = native
      def length = @native[:length].to_i
      alias size length
      def empty? = length.zero?
    end

    class Map < SharedType
      include Enumerable
      def [](key) = JSON.parse(@native.getJSON(key.to_s).to_s)
      def []=(key, value)
        @native.setJSON(key.to_s, JSON.generate(value))
      end
      def key?(key) = @native.has(key.to_s) == JS::True
      alias has_key? key?
      def delete(key)
        value = self[key]
        @native.delete(key.to_s)
        value
      end
      def to_h = JSON.parse(@native.readJSON.to_s)
      def keys = JSON.parse(@native.keysJSON.to_s)
      def each(&block) = block ? to_h.each(&block) : to_enum(:each)
      def fetch(key, *default, &block) = to_h.fetch(key.to_s, *default, &block)
    end

    class Text < SharedType
      # Yrs browser offsets count UTF-16 code units, as browser editors and Yjs do.
      def insert(index, value) = @native.insert(index, value.to_s)
      def delete(index, length = 1) = @native.delete(index, length)
      def to_s = @native.toString.to_s
    end

    class Array < SharedType
      include Enumerable
      def [](index) = JSON.parse(@native.getJSON(index).to_s)
      def insert(index, *values) = @native.insertJSON(index, JSON.generate(values))
      def push(*values) = insert(length, *values)
      def <<(value)
        push(value)
        self
      end
      def delete(index, length = 1) = @native.delete(index, length)
      def to_a = JSON.parse(@native.readJSON.to_s)
      def each(&block) = block ? to_a.each(&block) : to_enum(:each)
    end

    class UndoManager
      attr_reader :native
      def initialize(native) = @native = native
      def undo = @native.undo
      def redo = @native.redo
      def clear = @native.clear
      def stop_capturing = @native.stopCapturing
      def can_undo? = @native[:canUndo] == JS::True
      def can_redo? = @native[:canRedo] == JS::True
      def destroy = @native.destroy
      def on_change(&block)
        unsubscribe = @native.onChange(->(json) { block.call(JSON.parse(json.to_s)); nil })
        -> { unsubscribe.call(:call); nil }
      end
    end
  end
end

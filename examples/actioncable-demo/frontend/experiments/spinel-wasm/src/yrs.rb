# frozen_string_literal: true

# yrs, the Rust Yjs engine, through its C API (yffi). libyrs.a is linked into
# the same WebAssembly module, so these are plain calls: no JavaScript and no
# JSON between Ruby and the document. yrs_glue.c holds the calls that pass a
# struct by value or return memory Ruby has to copy.
module Yrs
  ffi_func :ymap, [:ptr, :str], :ptr
  ffi_func :ydoc_read_transaction, [:ptr], :ptr
  ffi_func :ydoc_write_transaction, [:ptr, :uint32, :str], :ptr
  ffi_func :ytransaction_commit, [:ptr], :void
  ffi_func :ytransaction_apply, [:ptr, :binstr, :uint32], :uint8
  ffi_func :ymap_iter, [:ptr, :ptr], :ptr
  ffi_func :ymap_iter_next, [:ptr], :ptr
  ffi_func :ymap_iter_destroy, [:ptr], :void
  ffi_func :ymap_entry_destroy, [:ptr], :void
  ffi_func :yundo_manager_add_scope, [:ptr, :ptr, :ptr], :void
  ffi_func :yundo_manager_add_origin, [:ptr, :uint32, :str], :void
  ffi_func :yundo_manager_stop, [:ptr], :void
  ffi_func :yundo_manager_undo, [:ptr], :uint8
  ffi_func :yundo_manager_redo, [:ptr], :uint8
  ffi_func :yundo_manager_undo_stack_len, [:ptr], :uint32

  ffi_func :yg_doc_new, [:uint32], :ptr
  ffi_func :yg_observe_updates, [:ptr], :void
  ffi_func :yg_take_update, [], :binstr
  ffi_func :yg_state_vector, [:ptr], :binstr
  ffi_func :yg_diff, [:ptr, :binstr, :uint32], :binstr
  ffi_func :yg_json, [:ptr, :ptr], :str
  ffi_func :yg_get_json, [:ptr, :ptr, :str], :str
  ffi_func :yg_get_int, [:ptr, :ptr, :str, :int], :int
  ffi_func :yg_set_int, [:ptr, :ptr, :str, :int], :void
  ffi_func :yg_set_string, [:ptr, :ptr, :str, :str], :void
  ffi_func :yg_set_bool, [:ptr, :ptr, :str, :bool], :void
  ffi_func :yg_entry_key, [:ptr], :str
  ffi_func :yg_entry_int, [:ptr, :int], :int
  ffi_func :yg_undo_manager, [:int], :ptr
end

# The studio's shared document: four maps in one yrs Doc, with an undo manager
# over the human layer. Writes happen inside #write; reads reuse its
# transaction, since yrs allows one transaction at a time.
class Document
  REMOTE = "yrby-wasm-remote"

  attr_reader :client_id

  def initialize(client_id)
    @client_id = client_id
    @doc = Yrs.yg_doc_new(client_id)
    @scene = Yrs.ymap(@doc, "scene")
    @pixels = Yrs.ymap(@doc, "pixels")
    @artist = Yrs.ymap(@doc, "artist_pixels")
    @mural = Yrs.ymap(@doc, "mural")
    @writing = false
    @changed = false
    Yrs.yg_observe_updates(@doc)
  end

  def write(origin)
    txn = Yrs.ydoc_write_transaction(@doc, origin.bytesize, origin)
    raise "Yrs is already in a transaction" if txn == nil
    @txn = txn
    @writing = true
    begin
      yield
    ensure
      @writing = false
      Yrs.ytransaction_commit(@txn)
    end
  end

  def set_int(name, key, value) = Yrs.yg_set_int(map(name), writer, key, value)
  def set_string(name, key, value) = Yrs.yg_set_string(map(name), writer, key, value)
  def set_bool(name, key, value) = Yrs.yg_set_bool(map(name), writer, key, value)

  # An integer value, or the fallback for a missing or non-integer one.
  def get_int(name, key, fallback)
    txn = reader
    value = Yrs.yg_get_int(map(name), txn, key, fallback)
    release(txn)
    value
  end

  # Yields each key with its integer value, or -1 for any other value.
  def each_int(name)
    txn = reader
    entries = Yrs.ymap_iter(map(name), txn)
    while true
      entry = Yrs.ymap_iter_next(entries)
      break if entry == nil
      yield Yrs.yg_entry_key(entry), Yrs.yg_entry_int(entry, -1)
      Yrs.ymap_entry_destroy(entry)
    end
    Yrs.ymap_iter_destroy(entries)
    release(txn)
  end

  # The map as JSON, for the mural's mixed values and for inspection.
  def json(name)
    txn = reader
    text = Yrs.yg_json(map(name), txn)
    release(txn)
    text
  end

  def state_vector
    txn = reader
    vector = Yrs.yg_state_vector(txn)
    release(txn)
    vector
  end

  # Everything this document has that a peer at `vector` lacks.
  def diff(vector)
    txn = reader
    update = Yrs.yg_diff(txn, vector, vector.bytesize)
    release(txn)
    raise "Malformed state vector" if update.empty?
    update
  end

  def apply(update)
    txn = Yrs.ydoc_write_transaction(@doc, REMOTE.bytesize, REMOTE)
    raise "Yrs is already in a transaction" if txn == nil
    code = Yrs.ytransaction_apply(txn, update, update.bytesize)
    Yrs.ytransaction_commit(txn)
    # A remote update is already on the server; drop its re-encoding.
    while !Yrs.yg_take_update.empty?
    end
    @changed = true
    raise "Yrs could not apply an update (error #{code})" unless code == 0
  end

  # Local updates committed since the last call, oldest first.
  def take_updates
    updates = []
    while true
      update = Yrs.yg_take_update
      break if update.empty?
      updates << update
    end
    @changed = true unless updates.empty?
    updates
  end

  # True once after any local or remote change.
  def changed?
    changed = @changed
    @changed = false
    changed
  end

  def track_undo(name, origin, capture_timeout)
    @undo = Yrs.yg_undo_manager(capture_timeout)
    Yrs.yundo_manager_add_scope(@undo, @doc, map(name))
    Yrs.yundo_manager_add_origin(@undo, origin.bytesize, origin)
  end

  def stop_capturing = Yrs.yundo_manager_stop(@undo)
  def undo = Yrs.yundo_manager_undo(@undo)
  def redo = Yrs.yundo_manager_redo(@undo)
  def can_undo? = Yrs.yundo_manager_undo_stack_len(@undo) > 0

  private

  def map(name)
    case name
    when "scene" then @scene
    when "pixels" then @pixels
    when "artist_pixels" then @artist
    else @mural
    end
  end

  def writer
    raise "Write inside Document#write" unless @writing
    @txn
  end

  def reader = @writing ? @txn : Yrs.ydoc_read_transaction(@doc)
  def release(txn) = (Yrs.ytransaction_commit(txn) unless @writing)
end

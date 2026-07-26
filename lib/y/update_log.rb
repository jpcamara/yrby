# frozen_string_literal: true

require "y"

module Y
  # Durable storage for collaborative documents as an append-only update log
  # with compaction. Y::DocumentUpdate — the gem's model, table from
  # `rails g yrby:tables` — includes it. To store the log elsewhere, include
  # it in any model with a binary `payload` column and an indexed key column:
  #
  #   class RoomUpdate < ApplicationRecord
  #     include Y::UpdateLog
  #     def self.key_column = :room_key   # default :document_id
  #   end
  #
  #   RoomUpdate.load(key)          # merged state, or nil
  #   RoomUpdate.append(key, bytes) # record one delta
  #
  # Appends are cheap and safe under concurrency (CRDT updates merge
  # commutatively, so row order never matters). Compaction keeps loads fast by
  # collapsing a document's rows into one snapshot row once `compact_every`
  # updates accumulate — without it, every load replays the document's full
  # history.
  module UpdateLog
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # How many rows a document may accumulate before an append triggers
      # compaction inline. Raise it (or call compact! from a job instead) if
      # the inline count query ever shows up in a profile.
      attr_writer :compact_every

      def compact_every
        @compact_every ||= 500
      end

      # The column the log is keyed by: Y::DocumentUpdate's belongs_to key.
      # Override for a table keyed some other way (a room name, a UUID).
      def key_column
        :document_id
      end

      # The merged state of a document, or nil if nothing was ever recorded.
      def load(key)
        payloads = where(key_column => key).pluck(:payload)
        return nil if payloads.empty?

        build_doc(payloads).compacted_state_update
      end

      # When the document last changed — the newest recorded row's timestamp,
      # or nil for an unknown document. A cheap staleness signal for readers
      # that project the document into another form (rendered HTML, search
      # text): compare against the projection's own timestamp and rebuild only
      # when the log is newer.
      def latest_change_at(key)
        where(key_column => key).maximum(:created_at)
      end

      def append(key, update)
        create!(key_column => key, payload: update)
        # At-or-over, not an exact multiple: concurrent appends can jump the
        # count past a multiple and would otherwise skip compaction forever.
        compact!(key) if where(key_column => key).count >= compact_every
      end

      # Collapse a document's rows into one snapshot row. Safe to run while
      # appends continue: only the rows read here are deleted, so an update
      # landing mid-compaction survives. Two racing compactions leave two
      # equivalent snapshots, which is harmless — merging is idempotent, and
      # the next compaction collapses them.
      #
      # Skipped while the document holds a pending (causally-gapped) update:
      # the snapshot excludes pending, so compacting now would delete the only
      # copy of a gap that could still heal. The sync channel never records
      # gaps, so this only engages on legacy rows — compaction resumes once
      # the gap heals or the log is repaired.
      def compact!(key)
        rows = where(key_column => key).pluck(:id, :payload, :created_at)
        return if rows.size < 2

        doc = build_doc(rows.map { |_, payload, _| payload })
        return if doc.pending?

        transaction do
          # The snapshot keeps the newest compacted row's created_at:
          # compaction isn't a content change, so latest_change_at must not
          # move — a projection stamped before it is still fresh.
          create!(key_column => key, payload: doc.compacted_state_update, created_at: rows.map(&:last).max)
          where(id: rows.map(&:first)).delete_all
        end
      end

      private

      # `compacted_state_update` (used by load and compact!) is gap-free, so
      # a gappy update recorded during a network wobble is never served to
      # peers.
      def build_doc(payloads)
        doc = Y::Doc.new
        payloads.each { |payload| doc.apply_update(payload) }
        doc
      end
    end
  end
end

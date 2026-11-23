# frozen_string_literal: true

require "minitest/autorun"
require "y"
require_relative "../app/lib/pixel_canvas"

class PixelCanvasTest < Minitest::Test
  def test_layers_preserve_human_marks_including_zero
    canvas = PixelCanvas.new(scene: { "1,2" => 13, "3,4" => 13, "5,6" => 13 },
                             artist: { "1,2" => 9, "3,4" => 9 }, human: { "1,2" => 0 })
    assert_equal 0, canvas[1, 2]
    assert_equal 9, canvas[3, 4]
    assert_equal 13, canvas[5, 6]
    assert_equal 0, canvas[63, 31]
    assert_equal "h", canvas.protected_rows[2][1]
    assert_equal 32, canvas.rows.length
    assert canvas.rows.all? { |row| row.match?(/\A[0-9a-f]{64}\z/) }
  end

  def test_malformed_map_values_do_not_enter_the_raster
    canvas = PixelCanvas.new(human: { "1,2" => "4", "3,4" => 4.0, "-1,0" => 5,
                                     "64,0" => 5, "0,32" => 5, "01,2" => 5, "1,3" => 16 })
    assert_empty canvas.human
    assert_equal "0" * 64, canvas.rows.first
  end

  def test_patch_validation_is_strict_and_rejects_the_whole_patch
    bad_points = [[64, 0, 1], [-1, 0, 1], [0, 32, 1], [0, 0, 16], [0, 0, -1],
                  [1.0, 2, 3], [1, 2, "3"], [1, 2], nil]
    bad_points.each do |point|
      assert_raises(PixelCanvas::InvalidPlan) { PixelCanvas.plan(note: "A detail", pixels: [[1, 1, 4], point]) }
    end
    assert_raises(PixelCanvas::InvalidPlan) { PixelCanvas.plan(note: "", pixels: Array.new(97) { |i| [i % 64, i / 64, 4] }) }
    assert_raises(PixelCanvas::InvalidPlan) { PixelCanvas.plan(note: "", pixels: [[1, 1, 4], [1, 1, 5]]) }
    assert_raises(PixelCanvas::InvalidPlan) { PixelCanvas.plan(note: nil, pixels: []) }
    assert_raises(PixelCanvas::InvalidPlan) { PixelCanvas.plan(note: "x" * 241, pixels: []) }
    assert_empty PixelCanvas.plan(note: "Leave it as it is.", pixels: []).pixels
    assert_equal 96, PixelCanvas.plan(note: "", pixels: Array.new(96) { |i| [i % 64, i / 64, 4] }).pixels.size
  end

  def test_display_caption_controls_become_single_spaces
    caption = " A\x00tiny\x7f\tboat.\n"
    plan = PixelCanvas.plan(note: caption, pixels: [[3, 4, 9]])
    assert_equal "A tiny boat.", plan.note
    assert_equal [[3, 4, 9]], plan.pixels
    assert_equal " A\x00tiny\x7f\tboat.\n", caption, "the input caption is not mutated"
    assert_predicate plan.note, :frozen?
  end

  def test_writable_filters_protected_pixels_and_existing_colors
    canvas = PixelCanvas.new(scene: { "2,2" => 4 }, human: { "1,1" => 0 })
    plan = PixelCanvas.plan(note: "A detail", pixels: [[1, 1, 6], [2, 2, 4], [3, 3, 9]])
    assert_equal [[3, 3, 9]], canvas.writable(plan)
  end

  def test_signature_tracks_human_content_and_direction_but_not_artist_writes
    first = PixelCanvas.new(human: { "1,1" => 0, "2,2" => 4 }, brief: "Warm sky")
    own_write = PixelCanvas.new(human: { "2,2" => 4, "1,1" => 0 }, artist: { "3,3" => 8 }, brief: "Warm sky")
    human_edit = PixelCanvas.new(human: { "1,1" => 1, "2,2" => 4 }, brief: "Warm sky")
    brief_edit = PixelCanvas.new(human: first.human, brief: "Cool sky")
    assert_equal first.signature, own_write.signature
    refute_equal first.signature, human_edit.signature
    refute_equal first.signature, brief_edit.signature
    assert_equal [{ "at" => "1,1", "from" => 0, "to" => 1 }], human_edit.changes_since(first)
    assert_equal [{ "at" => "1,1", "from" => 0, "to" => nil }, { "at" => "2,2", "from" => 4, "to" => nil }],
                 PixelCanvas.new.changes_since(first)
  end

  def test_capture_returns_immutable_plain_data_separate_from_the_document
    doc = Y::Doc.new
    doc.get_map("scene")["1,2"] = 13
    doc.get_map("pixels")["3,4"] = 0
    doc.get_map("mural")["brief"] = "x" * 300
    snapshot = PixelCanvas.capture(doc)
    doc.get_map("pixels")["3,4"] = 6
    assert_equal 0, snapshot[3, 4]
    assert_equal 240, snapshot.brief.length
    assert_predicate snapshot, :frozen?
    assert_predicate snapshot.human, :frozen?
    assert_raises(FrozenError) { snapshot.human["1,1"] = 8 }
  end
end

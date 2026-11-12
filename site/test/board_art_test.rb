require "test_helper"

class BoardArtTest < ActiveSupport::TestCase
  test "it keeps plain shapes and the attributes that draw them" do
    art = BoardArt.shapes(<<~SVG)
      Here you go:
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 100">
        <g transform="translate(10, 5)"><circle cx="50" cy="50" r="30" fill="#f4a261" stroke="#3b2a1a" stroke-width="3"/></g>
        <path d="M10 10 L90 90 Z" stroke-linejoin="round"/>
      </svg>
    SVG

    assert_equal [0, 0, 120, 100], art["box"]
    assert_equal ["g", { "transform" => "translate(10, 5)" },
                  [["circle", { "cx" => "50", "cy" => "50", "r" => "30", "fill" => "#f4a261", "stroke" => "#3b2a1a",
                                "stroke-width" => "3" }, []]]], art["shapes"].first
    assert_equal ["path", { "d" => "M10 10 L90 90 Z", "stroke-linejoin" => "round" }, []], art["shapes"].last
  end

  test "scripts, links, styles, text, and paint from elsewhere are dropped" do
    art = BoardArt.shapes(<<~SVG)
      <svg viewBox="0 0 100 100"><script>alert(1)</script><foreignObject><div>hi</div></foreignObject>
        <text>Pie</text><image href="https://evil.example/x.png"/>
        <rect x="1" y="1" width="9" height="9" fill="url(#g)" style="fill:red" onclick="alert(1)" href="javascript:x"/>
      </svg>
    SVG

    assert_equal [["rect", { "x" => "1", "y" => "1", "width" => "9", "height" => "9" }, []]], art["shapes"]
  end

  test "a reply with no usable shapes is nil" do
    assert_nil BoardArt.shapes("I can't draw that.")
    assert_nil BoardArt.shapes("<svg><text>Pie</text></svg>")
  end

  test "a bad viewBox falls back to 100 square" do
    assert_equal [0, 0, 100, 100], BoardArt.shapes('<svg viewBox="0 0 -1 x"><circle r="5"/></svg>')["box"]
  end
end

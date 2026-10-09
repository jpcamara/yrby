require "test_helper"

# The method gate (config/initializers/method_gate.rb): only GET and HEAD
# reach the app, apart from the AnyCable RPC endpoint, and a multipart body is
# refused on every path.
class MethodGateTest < ActionDispatch::IntegrationTest
  setup { Rack::Attack.cache.store.clear }

  PATHS = %w[/ /demos /demos/whiteboard/room1 /docs/getting-started /up /site.css /nothing-here].freeze

  test "the gate is the first middleware" do
    assert_equal MethodGate, Rails.application.middleware.first.klass
  end

  test "GET and HEAD go through" do
    get "/docs/getting-started"

    assert_response :success
    head "/docs/getting-started"

    assert_response :success
  end

  test "every other method gets a 405 with an Allow header" do
    PATHS.each do |path|
      %i[post put patch delete options].each do |verb|
        process verb, path

        assert_response :method_not_allowed, "#{verb.upcase} #{path}"
        assert_equal "GET, HEAD", response.headers["allow"]
        assert_equal "no-store", response.headers["cache-control"]
      end
    end
  end

  test "a _method override can't turn a POST into something else" do
    post "/demos", params: { _method: "get" }

    assert_response :method_not_allowed
  end

  test "a multipart body gets a 415 whatever the method or path" do
    headers = { "CONTENT_TYPE" => "multipart/form-data; boundary=x" }
    (PATHS + %w[/_anycable /_anycable/connect]).each do |path|
      %i[get post put].each do |verb|
        process verb, path, headers: headers

        assert_response :unsupported_media_type, "#{verb.upcase} #{path}"
      end
    end
  end

  test "other multipart types and odd casing are refused too" do
    ["Multipart/Form-Data; boundary=x", " multipart/mixed; boundary=x", "multipart/related"].each do |type|
      post "/demos", headers: { "CONTENT_TYPE" => type }

      assert_response :unsupported_media_type, type
    end
  end

  test "an outside POST to the RPC endpoint passes the gate and is still blocked by its bearer check" do
    post "/_anycable/connect"

    assert_response :not_found
    assert_equal "Not found\n", response.body
  end

  test "the embedded server's authenticated RPC still works" do
    post "/_anycable/connect", headers: { "Authorization" => Rack::Attack.rpc_bearer }

    # The RPC handler answered (an empty body gets 422). The gate would be 405
    # and the bearer block 404.
    assert_response :unprocessable_entity
  end

  test "only the RPC endpoint itself is exempt" do
    %w[/_anycablex /_anycable/connect/extra /_anycable/../demos /x/_anycable].each do |path|
      post path, headers: { "Authorization" => Rack::Attack.rpc_bearer }

      assert_response :method_not_allowed, path
    end
  end
end

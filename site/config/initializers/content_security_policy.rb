# Content Security Policy and the other response security headers.
#
# A public demo site with no authentication and no user-supplied HTML, but the
# policy still earns its place: it is what keeps an injected script from
# reaching anything, and it documents that this app loads nothing from anywhere
# else.
#
# script-src is strict 'self' with NO 'unsafe-inline' — there are no inline
# <script> blocks or on* handlers anywhere (all behavior lives in the bun
# bundles), so an injected script has no way to execute. style-src does allow
# 'unsafe-inline', pragmatically and at low risk: the server-side syntax
# highlighter (Commonmarker/syntect) stamps inline `style=` on code spans, the
# Lexxy editor sets styles at runtime, and the demos color the elements they
# build (presence chips, cell fills). Style injection can't run code.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline
    # Editors and highlighters may emit data: images even with uploads disabled.
    policy.img_src     :self, :data
    # The cable is same-origin, but browsers differ on whether 'self' covers a
    # ws:// URL, so both schemes are named.
    policy.connect_src :self, "ws:", "wss:"
    policy.object_src  :none
    policy.base_uri    :self
    # The demos are not meant to be framed; this is the modern X-Frame-Options
    # (the legacy header itself is set to DENY in config/application.rb, where
    # default_headers can still be changed before Response snapshots them).
    policy.frame_ancestors :none
  end
end

# Rails already sends nosniff and Referrer-Policy by default, and — once
# force_ssl is on — HSTS, so the plain-http Pi (FORCE_SSL=false) never sends
# Strict-Transport-Security, which is exactly right.

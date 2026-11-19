# Content Security Policy and the other response security headers.
#
# The site has no authentication and no user-supplied HTML, but the policy is
# still useful. It stops an injected script from running, and it makes clear
# that the app loads nothing from other origins.
#
# script-src is 'self' with no 'unsafe-inline'. There are no inline <script>
# blocks or on* handlers (all behavior is in the bun bundles), so an injected
# script can't execute. style-src allows 'unsafe-inline', which is low risk.
# The server-side syntax highlighter (Commonmarker with syntect) puts inline
# `style=` on code spans, the Lexxy editor sets styles at runtime, and the
# demos color the elements they build (presence chips, cell fills). Injected
# styles can't run code.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline
    # Images come only from this origin, and never from data: or blob: URLs.
    # Nothing on the site needs them: the icons and the social card are files
    # in public/, the toolbar icons are inline SVG elements, and the build
    # writes Lexxy's two stylesheet chevrons out as files (frontend/build.mjs).
    # So even a data: URL that got into a page can't render as an image.
    policy.img_src     :self
    # No demo plays audio or video, and nothing is embedded in a frame.
    policy.media_src   :none
    policy.frame_src   :none
    # The cable is same-origin, but browsers differ on whether 'self' covers a
    # ws:// URL, so both schemes are named.
    policy.connect_src :self, "ws:", "wss:"
    policy.object_src  :none
    policy.base_uri    :self
    # The site has no forms that post anywhere. The kanban and spreadsheet
    # inputs call preventDefault, and any form that did submit could only
    # reach this origin.
    policy.form_action :self
    # The demos aren't meant to be framed. This does the job of X-Frame-Options
    # for modern browsers. config/application.rb also sets X-Frame-Options to
    # DENY, because that's where default_headers can still be changed.
    policy.frame_ancestors :none
  end
end

# Rails sends nosniff and Referrer-Policy by default. It sends HSTS only when
# force_ssl is on, so a plain-http box (FORCE_SSL=false) doesn't send
# Strict-Transport-Security.

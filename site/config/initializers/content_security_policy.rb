# A public demo site with no authentication and no user-supplied HTML. The
# policy is still worth having: it is what keeps an injected script from
# reaching anything, and it documents that this app loads nothing from anywhere
# else.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    # The demos set colors on elements they build (presence chips, cell fills),
    # some of which lands as a style attribute. CSP counts that as inline style.
    policy.style_src   :self, :unsafe_inline
    policy.img_src     :self, :data
    # The cable connection is same-origin, but browsers differ on whether 'self'
    # covers a ws:// URL, so both schemes are named.
    policy.connect_src :self, "ws:", "wss:"
    policy.object_src  :none
    policy.base_uri    :self
    policy.frame_ancestors :none
  end
end

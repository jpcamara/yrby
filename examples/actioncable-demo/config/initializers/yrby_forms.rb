# frozen_string_literal: true

# The demo has no users, so presence identity is a random name and color per
# page render, like the editor pages pick theirs.
Y::Collaborative.identity = lambda do |_view|
  {
    name: %w[Ada Grace Linus Yukihiro Barbara Dennis Radia Alan].sample,
    color: %w[#f87171 #fb923c #facc15 #4ade80 #22d3ee #818cf8 #e879f9 #f472b6].sample
  }
end

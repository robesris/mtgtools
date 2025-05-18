#!/usr/bin/env ruby

require 'rmagick'
require 'fileutils'

# Create a placeholder image
image = Magick::Image.new(146, 204) do |img|
  img.background_color = '#f0f0f0'
end

# Add text
draw = Magick::Draw.new
draw.font = 'Arial'
draw.pointsize = 14
draw.gravity = Magick::CenterGravity
draw.fill = '#666666'

# Add "Card Not Found" text
draw.annotate(image, 0, 0, 0, 0, "Card Not Found")

# Save the image
FileUtils.mkdir_p('commander_cards')
image.write('commander_cards/placeholder.jpg') 